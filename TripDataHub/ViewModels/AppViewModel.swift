import Foundation
import CloudKit
import UIKit
import UserNotifications
import CryptoKit
import os

private let logger = Logger(subsystem: "com.sfune.TripDataHub", category: "AppViewModel")

protocol FriendLinkNotificationScheduling: Sendable {
    func notifyFriendLinked(_ friend: FriendConnection) async
    func notifyFriendRequestReceived(_ friend: FriendConnection) async
}

struct FriendLinkNotificationService: FriendLinkNotificationScheduling {
    func notifyFriendLinked(_ friend: FriendConnection) async {
        await schedule(
            identifier: "friend.linked.\(friend.employeeID)",
            title: "Friend Connected",
            body: "\(friend.displayName) is now linked. You can view their timeline.",
            threadIdentifier: "friend.linked"
        )
    }

    func notifyFriendRequestReceived(_ friend: FriendConnection) async {
        await schedule(
            identifier: "friend.request.\(friend.employeeID)",
            title: "Friend Request",
            body: "GEMS \(friend.displayName) added you. Open Friends to accept.",
            threadIdentifier: "friend.request"
        )
    }

    private func schedule(identifier: String, title: String, body: String, threadIdentifier: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let isAuthorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
        default:
            isAuthorized = false
        }
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }
}

enum AuthStatus: String {
    case unknown
    case loggedOut
    case loggedIn
}

private enum CloudKitIdentityFetchError: Error {
    case accountStatus(CKAccountStatus)
    case timeout
}

struct CrewAccessImportFile: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let fileName: String
    let url: URL
    let bytes: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let tripId: String
    let tripInformationDate: String?
    let displayName: String
    let usedFallbackDate: Bool
    let matchedScheduleId: String?
    let isOrphan: Bool
}

actor ExternalOpenImportCoordinator {
    struct QueueItem {
        let key: String
        let url: URL
    }

    private var queue: [QueueItem] = []
    private var queuedKeys: Set<String> = []
    private var inflightKeys: Set<String> = []
    private var recentAcceptedKeys: [String: Date] = [:]
    private var recentProcessedKeys: [String: Date] = [:]
    private let dedupTTL: TimeInterval
    static let shared = ExternalOpenImportCoordinator(dedupTTL: 30)

    init(dedupTTL: TimeInterval) {
        self.dedupTTL = dedupTTL
    }

    func enqueue(key: String, url: URL, now: Date) -> Bool {
        pruneRecentAccepted(now: now)
        pruneRecentProcessed(now: now)
        guard recentAcceptedKeys[key] == nil,
              recentProcessedKeys[key] == nil,
              !queuedKeys.contains(key),
              !inflightKeys.contains(key) else {
            return false
        }
        recentAcceptedKeys[key] = now
        queuedKeys.insert(key)
        queue.append(QueueItem(key: key, url: url))
        return true
    }

    func dequeueNext() -> QueueItem? {
        guard !queue.isEmpty else { return nil }
        let item = queue.removeFirst()
        queuedKeys.remove(item.key)
        return item
    }

    func markInFlight(_ key: String) -> Bool {
        pruneRecentProcessed(now: Date())
        guard recentProcessedKeys[key] == nil,
              !inflightKeys.contains(key) else { return false }
        inflightKeys.insert(key)
        return true
    }

    func finish(key: String, success: Bool, now: Date = Date()) {
        inflightKeys.remove(key)
        if success {
            recentProcessedKeys[key] = now
        } else {
            // Allow immediate retry for the same file after a failed import attempt.
            recentAcceptedKeys.removeValue(forKey: key)
        }
    }

    func requeueFront(_ item: QueueItem) {
        guard !queuedKeys.contains(item.key), !inflightKeys.contains(item.key) else { return }
        queuedKeys.insert(item.key)
        queue.insert(item, at: 0)
    }

    /// Clears all dedup history so the same file can be re-shared immediately
    /// after an import is confirmed or discarded.
    /// `inflightKeys` is intentionally not reset here; active jobs are released by `finish`.
    func reset() {
        recentAcceptedKeys.removeAll()
        recentProcessedKeys.removeAll()
    }

    private func pruneRecentAccepted(now: Date) {
        recentAcceptedKeys = recentAcceptedKeys.filter { now.timeIntervalSince($0.value) < dedupTTL }
    }

    private func pruneRecentProcessed(now: Date) {
        recentProcessedKeys = recentProcessedKeys.filter { now.timeIntervalSince($0.value) < dedupTTL }
    }
}

private enum AppGroupImportConfig {
    // NOTE: Must match constants in TripDataShareActionExtension/ShareViewController.swift
    static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    static let importDirectoryName = "CrewAccessSharedImports"
    static let pendingHandoffFileName = "pending_import.json"
}

struct LogTenExportOutput: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let rowCount: Int
    let exportedFingerprints: [String: String]
    let backlogRecordIDs: Set<String>
}

@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()
    static let crewAccessRetentionSelectionKey = "crewaccess_trip_data_retained_v1"
    static let defaultCrewAccessRetentionSelection = "ALL"
    static let crewAccessRetentionDefaultMigrationKey = "crewaccess_trip_data_retained_default_all_migrated_v1"

    // MARK: - Import dedup (4-layer architecture)
    // Layer 1: ExternalOpenLaunchGate (BidProScheduleApp.swift) — catches iOS triple-delivery at onOpenURL
    // Layer 2: ExternalOpenImportCoordinator — queue management, single source of truth
    // Layer 3: importInProgress (instance var below) — primary execution gate, prevents re-entrancy
    // Layer 4: UserDefaults fingerprint — cross-launch content dedup only
    private static let importMethodDedupLock = NSLock()
    private static let persistentFingerprintKey = "import_dedup_fingerprint_v1"
    private static let persistentFingerprintTSKey = "import_dedup_fingerprint_ts_v1"
    private static let persistentFingerprintTTL: TimeInterval = 30
    /// Primary execution gate. Set before any system call; cleared on confirm/discard.
    private var importInProgress = false
    private var isProfileCloudKitSyncing = false
    private var isDeletingProfileAccount = false

    @Published var isSyncing = false
    @Published var isShowingLoginSheet = false
    @Published var lastSyncAt: Date?
    @Published var schedules: [PayPeriodSchedule] = []
    @Published var bidproSchedules: [PayPeriodSchedule] = []
    @Published var crewAccessSchedules: [PayPeriodSchedule] = []
    @Published var errorMessage: String?
    @Published var authStatus: AuthStatus = .unknown
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var notificationScheduleMessage: String?
    @Published var isTripBoardServerDown = false
    @Published var didLastFetchFail = false
    @Published var friendConnections: [FriendConnection] = [] {
        didSet {
            friendConnectionsRevision &+= 1
        }
    }
    @Published private(set) var friendConnectionsRevision: Int = 0
    @Published var friendActionMessage: String?
    @Published var identityActionMessage: String?
    @Published var friendCloudKitSyncMessage: String?
    @Published var isScheduleSharingEnabled = false
    @Published private(set) var isSyncingFriendCloudKit = false
    @Published var isAdmin = false
    @Published var currentCloudKitRecordName: String?
    @Published var seniorityRecords: [PilotSeniorityRecord] = []
    @Published var seniorityImportMessage: String?
    @Published private(set) var gemsVerificationRecordCount = 0
    @Published private(set) var isUploadingGEMSVerification = false
    @Published var verifiedIdentity: VerifiedIdentityProfile?
    @Published private(set) var cloudKitIdentityMessage: String?
    @Published private(set) var verifiedAppUsers: [VerifiedAppUser] = []
    @Published private(set) var isLoadingVerifiedAppUsers = false
    @Published var verifiedAppUsersMessage: String?
    @Published var crewAccessImportMessage: String?
    @Published var hasQueuedImport: Bool = false
    @Published var crewAccessDeleteMessage: String?
    @Published var logTenExportMessage: String?
    @Published var tzOverrideMessage: String?
    @Published var lastImportDidReplaceExistingTrip: Bool = false
    @Published var lastImportSummaryMessage: String?
    @Published var pendingImport: PendingImport?
    @Published var pendingExternalOpenURL: URL?
    @Published var isDeletingCrewAccessTrips = false
    @Published var hasLoadedSeniorityRecords = false
    @Published private(set) var isRefreshingCloudKitIdentity = false
    @Published private(set) var hasSeniorityDataOnDisk = false
    @Published private(set) var isDeviceSyncing = false
    @Published private(set) var deviceSyncStatusMessage: String?
    @Published private(set) var manualOperationalEvents: [ManualOperationalEvent] = []
    @Published private(set) var manualPersonalEvents: [ManualPersonalEvent] = []

    private let syncService: TripBoardSyncServiceProtocol
    private let authService: TripBoardAuthServiceProtocol
    private let cacheService: ScheduleCacheServiceProtocol
    private let notificationService: NextReportNotificationServiceProtocol
    private let friendLinkNotificationService: FriendLinkNotificationScheduling
    private let crewAccessImportService: CrewAccessPDFImportServiceProtocol
    private let friendScheduleCloudKitService: FriendScheduleCloudKitServicing
    private let gemsVerificationCloudKitService: GEMSVerificationCloudKitServicing
    private let deviceScheduleCloudKitService: DeviceScheduleCloudKitServicing
    private let manualEventCloudKitService: ManualEventCloudKitServicing
    private let crewAccessImportCloudKitService: CrewAccessImportCloudKitServicing
    let profileCloudKitService: ProfileCloudKitServicing
    private let tzResolver: IATATimeZoneResolving
    private let keychainService: KeychainServiceProtocol
    private let manualEventStore: ManualEventStoring
    private let externalOpenCoordinator: ExternalOpenImportCoordinator
    private let flightCountdownCoordinator = FlightCountdownCoordinator()
    private var sessionCookies: [HTTPCookie] = []
    private var lastAutoFetchAt: Date?
    private var externalConsumerTask: Task<Void, Never>?
    private var lastConsumedAppGroupHandoffFileName: String?
    private var isConsumingAppGroupHandoff = false
    private var crewAccessLegImportReferenceTimes: [String: Date] = [:]
    private var logTenExportBacklog: [LogTenExportBacklogRecord] = []
    private var logTenExportedFingerprints: [String: String] = [:]
    private var deletedCrewAccessTripKeys: Set<String> = []
    private var isUploadingSharedSchedule = false
    private var needsSharedScheduleUpload = false
    private var pendingSharedScheduleUploadReason: String?
    private var isUploadingDeviceSchedule = false
    private var needsDeviceScheduleUpload = false
    private var pendingDeviceScheduleUploadReason: String?
    private var lastDeviceScheduleUploadFingerprint: String?
    private var isUploadingManualEvents = false
    private var needsManualEventUpload = false
    private var pendingManualEventUploadReason: String?
    private var lastManualEventUploadFingerprint: String?
    private var manualEventTombstones: [ManualEventTombstone] = []
    private var foregroundObserver: NSObjectProtocol?
    private var iCloudKVObserver: NSObjectProtocol?
    private var lastDeviceScheduleFetchAt: Date?
    private var lastManualEventFetchAt: Date?
    private var cachedDeviceID: String?
    private var isFetchingCrewAccessImports = false
    private var lastCrewAccessImportFetchAt: Date?

    private let notification48hKey = "notification_48h_enabled"
    private let notification24hKey = "notification_24h_enabled"
    private let notification12hKey = "notification_12h_enabled"
    private let friendConnectionsKey = "friend_connections_v1"
    private let friendConnectionsSyncKey = "friend_connections_sync_v1"
    private let friendConnectionsResetAtKey = "friend_connections_reset_at_v1"
    private let scheduleSharingEnabledKey = "schedule_sharing_enabled_v1"
    private let seniorityRecordsKey = "pilot_seniority_records_v1"
    // Legacy keys/file names are kept so upgrades from pre-CloudKit verification builds can clean up local seniority data.
    private let legacySeniorityRecordsKey = "pilot_roster_records_v1"
    private let verifiedIdentityKey = "verified_identity_profile_v1"
    private let crewAccessLegImportReferenceTimesKey = "crewaccess_leg_import_reference_times_v1"
    private let deletedCrewAccessTripKeysKey = "deleted_crewaccess_trip_keys_v1"
    private let logTenExportBacklogKey = "logten_export_backlog_v1"
    private let logTenExportedFingerprintsKey = "logten_exported_fingerprints_v1"
    private let seniorityFileName = "pilot_seniority_records_v1.json"
    private let legacySeniorityFileName = "pilot_roster_records_v1.json"
    private let localIdentityRecordNameKey = "local_identity_record_name_v1"
    private let deviceScheduleUploadFingerprintKey = "device_schedule_last_upload_fingerprint_v1"
    private let deviceScheduleFetchAtKey = "device_schedule_last_fetch_at_v1"
    private let manualEventUploadFingerprintKey = "manual_event_last_upload_fingerprint_v1"
    private let manualEventFetchAtKey = "manual_event_last_fetch_at_v1"
    private let deviceIDKey = "device_id_v1"
    private let crewAccessImportFetchAtKey = "crewaccess_import_fetch_at_v1"
    private let cloudKitContainerIdentifier = "iCloud.com.sfune.TimelineSchedule"
    private let cloudKitIdentityTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let useCloudKitIdentity = true
    // GEMS verification must use CloudKit records. Do not allow TestFlight/App Store
    // clients to self-verify without the verification database.
    private let allowVerificationWithoutSeniorityDB = false
    // Add your own CloudKit recordName(s) here to grant admin access in TestFlight.
    private let adminCloudKitRecordAllowlist: Set<String> = []
    private let adminPolicy: AdminPolicy
    private let adminPolicyFingerprint: String
    private let autoFetchMinInterval: TimeInterval = 60
    private let verificationRequiredMessage = "Verification required before fetching TripBoard data."

    init(
        syncService: TripBoardSyncServiceProtocol = TripBoardSyncService(),
        authService: TripBoardAuthServiceProtocol = TripBoardAuthService(),
        cacheService: ScheduleCacheServiceProtocol = ScheduleCacheService(),
        notificationService: NextReportNotificationServiceProtocol = NextReportNotificationService(),
        friendLinkNotificationService: FriendLinkNotificationScheduling = FriendLinkNotificationService(),
        crewAccessImportService: CrewAccessPDFImportServiceProtocol = CrewAccessPDFImportService(),
        friendScheduleCloudKitService: FriendScheduleCloudKitServicing = FriendScheduleCloudKitService(
            containerIdentifier: "iCloud.com.sfune.TimelineSchedule"
        ),
        gemsVerificationCloudKitService: GEMSVerificationCloudKitServicing = GEMSVerificationCloudKitService(
            containerIdentifier: "iCloud.com.sfune.TimelineSchedule"
        ),
        deviceScheduleCloudKitService: DeviceScheduleCloudKitServicing = DeviceScheduleCloudKitService(
            containerIdentifier: "iCloud.com.sfune.TimelineSchedule"
        ),
        manualEventCloudKitService: ManualEventCloudKitServicing = ManualEventCloudKitService(
            containerIdentifier: "iCloud.com.sfune.TimelineSchedule"
        ),
        crewAccessImportCloudKitService: CrewAccessImportCloudKitServicing = CrewAccessImportCloudKitService(
            containerIdentifier: "iCloud.com.sfune.TimelineSchedule"
        ),
        profileCloudKitService: ProfileCloudKitServicing = ProfileCloudKitService(
            containerIdentifier: "iCloud.com.sfune.TimelineSchedule"
        ),
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared,
        keychainService: KeychainServiceProtocol = KeychainService(),
        manualEventStore: ManualEventStoring = ManualEventStore()
    ) {
        self.syncService = syncService
        self.authService = authService
        self.cacheService = cacheService
        self.notificationService = notificationService
        self.friendLinkNotificationService = friendLinkNotificationService
        self.crewAccessImportService = crewAccessImportService
        self.friendScheduleCloudKitService = friendScheduleCloudKitService
        self.gemsVerificationCloudKitService = gemsVerificationCloudKitService
        self.deviceScheduleCloudKitService = deviceScheduleCloudKitService
        self.manualEventCloudKitService = manualEventCloudKitService
        self.crewAccessImportCloudKitService = crewAccessImportCloudKitService
        self.profileCloudKitService = profileCloudKitService
        self.tzResolver = tzResolver
        self.keychainService = keychainService
        self.manualEventStore = manualEventStore
        self.externalOpenCoordinator = ExternalOpenImportCoordinator.shared
        let loadedAdminPolicy = Self.loadAdminPolicy()
        self.adminPolicy = loadedAdminPolicy
        self.adminPolicyFingerprint = Self.fingerprint(for: loadedAdminPolicy)
        Self.migrateCrewAccessRetentionDefaultIfNeeded()

        let cached = cacheService.load()
        let cachedCrewAccessSchedules = cached?.crewAccessSchedules ?? []
        let cachedBidproSchedules = cached?.bidproSchedules ?? []
        self.crewAccessSchedules = cachedCrewAccessSchedules
        self.bidproSchedules = cachedBidproSchedules
        self.schedules = mergeAndSortSchedules(crew: cachedCrewAccessSchedules, bidpro: cachedBidproSchedules)
        self.lastSyncAt = cached?.lastSyncAt
        UserDefaults.standard.removeObject(forKey: "countdown_testing_legs_v1")
        self.sessionCookies = authService.loadPersistedCookies()
        self.crewAccessLegImportReferenceTimes = Self.loadCrewAccessLegImportReferenceTimes(
            from: UserDefaults.standard,
            key: crewAccessLegImportReferenceTimesKey
        )
        self.deletedCrewAccessTripKeys = Set(UserDefaults.standard.stringArray(forKey: deletedCrewAccessTripKeysKey) ?? [])
        self.logTenExportBacklog = Self.loadLogTenExportBacklog(
            from: UserDefaults.standard,
            key: logTenExportBacklogKey
        )
        self.logTenExportedFingerprints = UserDefaults.standard.dictionary(forKey: logTenExportedFingerprintsKey) as? [String: String] ?? [:]
        self.authStatus = authService.isAuthenticated(url: nil, cookies: sessionCookies) ? .loggedIn : .loggedOut
        self.friendConnections = loadFriendConnections()
        let manualEvents = manualEventStore.load()
        self.manualOperationalEvents = manualEvents.operationalEvents.sorted { $0.startUTC < $1.startUTC }
        self.manualPersonalEvents = manualEvents.personalEvents.sorted { $0.startUTC < $1.startUTC }
        self.manualEventTombstones = manualEvents.tombstones
        self.isScheduleSharingEnabled = UserDefaults.standard.bool(forKey: scheduleSharingEnabledKey)
        self.seniorityRecords = []
        self.hasSeniorityDataOnDisk = Self.seniorityDataIsUsableOnDisk(
            seniorityFileName: seniorityFileName,
            legacySeniorityFileName: legacySeniorityFileName,
            seniorityRecordsKey: seniorityRecordsKey,
            legacySeniorityRecordsKey: legacySeniorityRecordsKey
        )
        let loadedVerifiedIdentity = loadVerifiedIdentity()
        self.verifiedIdentity = loadedVerifiedIdentity
        // Re-save to drop any legacy fields from older app builds (e.g. DOB).
        if let loadedVerifiedIdentity {
            saveVerifiedIdentity(loadedVerifiedIdentity)
        }
        backfillCrewAccessLegImportReferenceTimesIfNeeded()
        pruneCrewAccessLegImportReferenceTimes()
        self.lastDeviceScheduleUploadFingerprint = UserDefaults.standard.string(forKey: deviceScheduleUploadFingerprintKey)
        self.lastDeviceScheduleFetchAt = UserDefaults.standard.object(forKey: deviceScheduleFetchAtKey) as? Date
        self.lastManualEventUploadFingerprint = UserDefaults.standard.string(forKey: manualEventUploadFingerprintKey)
        self.lastManualEventFetchAt = UserDefaults.standard.object(forKey: manualEventFetchAtKey) as? Date
        self.cachedDeviceID = UserDefaults.standard.string(forKey: deviceIDKey)
        if !useCloudKitIdentity {
            self.currentCloudKitRecordName = localIdentityRecordName()
        }
        self.updateAdminStatus()
        if let loadedVerifiedIdentity {
            seedAppReviewMockScheduleIfNeeded(for: loadedVerifiedIdentity.gemsID)
        }
        backfillMissingUTCInCachedSchedulesIfNeeded()
        if self.authStatus == .loggedIn, errorMessage == SyncServiceError.notAuthenticated.localizedDescription {
            errorMessage = nil
        }

#if DEBUG
        applyDebugLaunchOverridesIfNeeded()
#endif

        Task { [weak self] in
#if DEBUG
            // In UI tests, skip all background init tasks:
            // - refreshCloudKitIdentity() may override the seeded verifiedIdentity/recordName
            // - applyCrewAccessRetentionPolicy() reconciles against local files (empty in test)
            //   and would clear the seeded crewAccessSchedules
            let isUITest = ProcessInfo.processInfo.arguments.contains("UITEST_TIMELINE_SEED")
                || ProcessInfo.processInfo.arguments.contains("UITEST_LOGGED_OUT_VERIFIED")
            let isXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if isUITest || isXCTest { return }
#endif
            await MainActor.run {
                self?.refreshCloudKitIdentity()
            }
            // Fetch remote import files before reconcile so iPad gets iOS-imported files.
            await self?.fetchCrewAccessImportFilesIfNeeded(reason: "startup")
            await self?.applyCrewAccessRetentionPolicy()
            await self?.refreshNotificationAuthorizationStatus()
            await self?.rescheduleNotificationsIfAuthorized()
            await self?.syncProfileWithCloudKit()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.fetchCrewAccessImportFilesIfNeeded(reason: "foreground")
                await self?.fetchDeviceScheduleIfNeeded(reason: "foreground")
                await self?.fetchManualEventsIfNeeded(reason: "foreground")
                await self?.syncProfileWithCloudKit()
            }
        }

        NSUbiquitousKeyValueStore.default.synchronize()
        iCloudKVObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.mergeICloudKVFriendConnections() }
        }

#if DEBUG
        logNonFatal("Cache restore (v2): crew=\(cachedCrewAccessSchedules.count) bidpro=\(cachedBidproSchedules.count)")
#endif
        logger.info("[VM] init vm=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let iCloudKVObserver {
            NotificationCenter.default.removeObserver(iCloudKVObserver)
        }
        logger.info("[VM] deinit vm=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
    }

    func saveManualOperationalEvent(_ event: ManualOperationalEvent) throws {
        try upsertManualOperationalEvent(event)
    }

    func saveManualOperationalEventsReplacingOverlaps(_ events: [ManualOperationalEvent]) throws {
        guard !events.isEmpty else { return }
        let merged = mergeManualOperationalEventsReplacingOverlaps(
            existing: manualOperationalEvents,
            replacements: events
        )
        let snapshot = ManualEventStoreSnapshot(
            operationalEvents: merged,
            personalEvents: manualPersonalEvents,
            tombstones: manualEventTombstones
        )
        try manualEventStore.save(snapshot)
        manualOperationalEvents = snapshot.operationalEvents
        manualEventTombstones = snapshot.tombstones
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual operational event saved") }
    }

    func updateManualOperationalEvent(_ event: ManualOperationalEvent) throws {
        try upsertManualOperationalEvent(event)
    }

    private func upsertManualOperationalEvent(_ event: ManualOperationalEvent) throws {
        var snapshot = ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: manualEventTombstones.filter { $0.id != event.id }
        )
        if let index = snapshot.operationalEvents.firstIndex(where: { $0.id == event.id }) {
            snapshot.operationalEvents[index] = event
        } else {
            snapshot.operationalEvents.append(event)
        }
        snapshot.operationalEvents.sort { $0.startUTC < $1.startUTC }
        try manualEventStore.save(snapshot)
        manualOperationalEvents = snapshot.operationalEvents
        manualEventTombstones = snapshot.tombstones
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual operational event saved") }
    }

    func deleteManualOperationalEvent(id: UUID) throws {
        let deletedAt = Date()
        var snapshot = ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: replacingTombstone(id: id, deletedAt: deletedAt)
        )
        snapshot.operationalEvents.removeAll { $0.id == id }
        try manualEventStore.save(snapshot)
        manualOperationalEvents = snapshot.operationalEvents
        manualEventTombstones = snapshot.tombstones
        lastManualEventFetchAt = deletedAt
        UserDefaults.standard.set(deletedAt, forKey: manualEventFetchAtKey)
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual operational event deleted") }
    }

    func saveManualPersonalEvent(_ event: ManualPersonalEvent) throws {
        try upsertManualPersonalEvent(event)
    }

    func updateManualPersonalEvent(_ event: ManualPersonalEvent) throws {
        try upsertManualPersonalEvent(event)
    }

    private func upsertManualPersonalEvent(_ event: ManualPersonalEvent) throws {
        var snapshot = ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: manualEventTombstones.filter { $0.id != event.id }
        )
        if let index = snapshot.personalEvents.firstIndex(where: { $0.id == event.id }) {
            snapshot.personalEvents[index] = event
        } else {
            snapshot.personalEvents.append(event)
        }
        snapshot.personalEvents.sort { $0.startUTC < $1.startUTC }
        try manualEventStore.save(snapshot)
        manualPersonalEvents = snapshot.personalEvents
        manualEventTombstones = snapshot.tombstones
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual personal event saved") }
    }

    func deleteManualPersonalEvent(id: UUID) throws {
        let deletedAt = Date()
        var snapshot = ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: replacingTombstone(id: id, deletedAt: deletedAt)
        )
        snapshot.personalEvents.removeAll { $0.id == id }
        try manualEventStore.save(snapshot)
        manualPersonalEvents = snapshot.personalEvents
        manualEventTombstones = snapshot.tombstones
        lastManualEventFetchAt = deletedAt
        UserDefaults.standard.set(deletedAt, forKey: manualEventFetchAtKey)
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual personal event deleted") }
    }

    private func replacingTombstone(id: UUID, deletedAt: Date) -> [ManualEventTombstone] {
        var tombstones = manualEventTombstones.filter { $0.id != id }
        tombstones.append(ManualEventTombstone(id: id, deletedAt: deletedAt))
        return tombstones
    }

    func handleIncomingAppDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "tripdatahub" else { return }
        let route = url.host?.lowercased() ?? url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard route == "import-crewaccess" else { return }
        logger.info("[Import] deepLink received url=\(url.absoluteString, privacy: .private)")
        consumePendingAppGroupImportIfAvailable()
    }

    func consumePendingAppGroupImportIfAvailable() {
        guard !isConsumingAppGroupHandoff else { return }
        isConsumingAppGroupHandoff = true
        Task { [weak self] in
            guard let self else { return }
            defer { isConsumingAppGroupHandoff = false }

            guard let handoff = await Task.detached(priority: .utility, operation: {
                Self.readPendingAppGroupHandoff()
            }).value else {
                return
            }

            let fileExists = await Task.detached(priority: .utility, operation: {
                FileManager.default.fileExists(atPath: handoff.fileURL.path)
            }).value

            if lastConsumedAppGroupHandoffFileName == handoff.fileName {
                logger.info("[Import] appGroup handoff skipped (already consumed) file=\(handoff.fileName, privacy: .private)")
                await Task.detached(priority: .utility, operation: {
                    Self.removePendingAppGroupHandoffBestEffort()
                }).value
                return
            }

            guard fileExists else {
                crewAccessImportMessage = "Import failed: shared PDF is missing. Please share the PDF again."
                logNonFatal("AppGroup handoff missing shared file: \(handoff.fileURL.path)")
                await Task.detached(priority: .utility, operation: {
                    Self.removePendingAppGroupHandoffBestEffort()
                }).value
                return
            }

            logger.info("[Import] appGroup handoff queued file=\(handoff.fileName, privacy: .private)")
            lastConsumedAppGroupHandoffFileName = handoff.fileName
            await Task.detached(priority: .utility, operation: {
                Self.removePendingAppGroupHandoffBestEffort()
            }).value
            queueExternalOpenURL(handoff.fileURL)
        }
    }

    var authStatusText: String {
        switch authStatus {
        case .loggedIn:
            return "Logged-in"
        case .loggedOut:
            return "Logged-out, please Fetch to log-in"
        case .unknown:
            return "Unknown"
        }
    }

    var visibleErrorMessage: String? {
        guard let errorMessage else { return nil }
        if authStatus == .loggedIn && errorMessage == SyncServiceError.notAuthenticated.localizedDescription {
            return nil
        }
        return errorMessage
    }

    var pendingFriendConnections: [FriendConnection] {
        friendConnections
            .filter { $0.status == .pending && $0.requestDirection != .incoming }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    var incomingFriendRequestConnections: [FriendConnection] {
        friendConnections
            .filter { $0.isIncomingRequest }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    var acceptedFriendConnections: [FriendConnection] {
        friendConnections
            .filter { $0.status == .accepted }
            .sorted { lhs, rhs in
                let lhsDate = lhs.linkedAt ?? lhs.requestedAt
                let rhsDate = rhs.linkedAt ?? rhs.requestedAt
                return lhsDate > rhsDate
            }
    }

    var canSubmitFriendRequest: Bool {
        isIdentityVerified
    }

    var isIdentityVerified: Bool {
        if AppEnvironment.isAppStoreReviewMode { return true }
        guard let verifiedIdentity else { return false }
        guard let currentCloudKitRecordName else { return false }
        return verifiedIdentity.cloudKitRecordName == currentCloudKitRecordName
    }

    private var isAppReviewMockVerifiedIdentity: Bool {
        guard let gemsID = verifiedIdentity?.gemsID else { return false }
        let normalized = GEMSIDNormalizer.normalize(gemsID)
        return normalized == "0000001" || normalized == "0000002"
    }

    var seniorityCount: Int { gemsVerificationRecordCount }

    var canAccessAdminTab: Bool {
        isAdmin
    }

    func unresolvedIATAAirports() -> [String] {
        let codes = Set(crewAccessSchedules.flatMap { schedule in
            schedule.legs.flatMap { [$0.depAirport, $0.arrAirport] }
        })
        return codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && tzResolver.resolve($0) == nil }
            .sorted()
    }

    func currentTimeZoneOverrides() -> [String: String] {
        tzResolver.currentOverrides()
    }

    func setTimeZoneOverride(iata: String, tzID: String) {
        let code = iata.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let zone = tzID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 3 else {
            tzOverrideMessage = "IATA must be 3 letters."
            return
        }
        guard !zone.isEmpty, TimeZone(identifier: zone) != nil else {
            tzOverrideMessage = "Invalid IANA timezone."
            return
        }

        tzResolver.setOverride(iata: code, tzID: zone)
        crewAccessSchedules = refreshScheduleTimezones(crewAccessSchedules)
        bidproSchedules = refreshScheduleTimezones(bidproSchedules)
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        do {
            let persistedLastSyncAt = lastSyncAt ?? Date()
            try cacheService.save(
                ScheduleCacheSnapshotV2(
                    crewAccessSchedules: crewAccessSchedules,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: persistedLastSyncAt,
                    migratedAt: nil
                )
            )
            if lastSyncAt == nil {
                lastSyncAt = persistedLastSyncAt
            }
        } catch {
            logNonFatal("Failed to persist cache after TZ override: \(error.localizedDescription)")
        }
        tzOverrideMessage = "Saved override: \(code) -> \(zone)"
    }

    func loadSeniorityRecordsIfNeeded() async {
        guard !hasLoadedSeniorityRecords else { return }
        await loadSeniorityRecordsAsync()
    }

    func submitPseudoFriendRequest(employeeID rawEmployeeID: String) {
        Task { [weak self] in
            await self?.submitFriendRequest(employeeID: rawEmployeeID)
        }
    }

    func submitFriendRequest(employeeID rawEmployeeID: String) async {
        guard !AppEnvironment.isAppStoreReviewMode else {
            friendActionMessage = "Schedule sharing is unavailable in Demo Mode."
            return
        }
        guard isIdentityVerified else {
            friendActionMessage = "Verify your identity first (GEMS ID + DOB)."
            return
        }
        guard let myGEMSID = verifiedIdentity?.gemsID else {
            friendActionMessage = "GEMS verification is required."
            return
        }
        let employeeID = GEMSIDNormalizer.normalize(rawEmployeeID)
        guard !employeeID.isEmpty else {
            friendActionMessage = "GEMS ID is required."
            return
        }
        guard employeeID != GEMSIDNormalizer.normalize(myGEMSID) else {
            friendActionMessage = "You cannot add yourself as a friend."
            return
        }
        if linkAppReviewMockFriendIfNeeded(myGEMSID: myGEMSID, friendGEMSID: employeeID) {
            return
        }
        if let index = friendConnections.firstIndex(where: { $0.employeeID == employeeID }) {
            if friendConnections[index].status == .accepted {
                friendActionMessage = "Friend already linked: \(employeeID)"
                return
            }
        }

        let wasAcceptedBeforeRequest = friendConnections.contains {
            $0.employeeID == employeeID && $0.status == .accepted
        }

        do {
            let link = try await friendScheduleCloudKitService.requestFriend(
                myGEMSID: myGEMSID,
                friendGEMSID: employeeID,
                friendResetAt: friendConnectionsResetAt()
            )
            upsertFriendConnection(from: link)
            if link.isAccepted, !wasAcceptedBeforeRequest,
               let friend = friendConnections.first(where: { $0.employeeID == link.friendGEMSID }) {
                await notifyFriendLinked(friend)
            }
            if link.isAccepted {
                enableScheduleSharingForFriends()
                await uploadSharedScheduleIfNeeded(reason: "friend accepted")
                await refreshFriendSchedulesFromCloud()
            }
            friendActionMessage = link.isAccepted
                ? "Friend linked: \(employeeID)"
                : "Request saved. Ask GEMS \(employeeID) to add your GEMS ID too."
        } catch {
            friendActionMessage = friendRequestErrorMessage(error)
            logNonFatal("Friend CloudKit request failed: \(error.localizedDescription)")
        }
    }

    private func upsertFriendConnection(from link: FriendScheduleCloudKitLink) {
        var updatedConnections = friendConnections
        if let index = friendConnections.firstIndex(where: { $0.employeeID == link.friendGEMSID }) {
            var connection = friendConnections[index]
            connection.status = link.isAccepted ? .accepted : .pending
            connection.requestDirection = link.isAccepted ? nil : (link.requestDirection ?? .outgoing)
            connection.requestedAt = link.requestedAt ?? Date()
            if link.isAccepted {
                connection.linkedAt = link.linkedAt ?? connection.linkedAt ?? Date()
                connection.acceptedAt = connection.acceptedAt ?? connection.linkedAt
            }
            updatedConnections[index] = connection
        } else {
            updatedConnections.append(
                FriendConnection(
                    employeeID: link.friendGEMSID,
                    status: link.isAccepted ? .accepted : .pending,
                    requestDirection: link.requestDirection,
                    linkedAt: link.isAccepted ? (link.linkedAt ?? Date()) : nil
                )
            )
        }
        friendConnections = updatedConnections
        saveFriendConnections()
    }

    func cancelPendingFriendRequest(_ id: UUID) async {
        guard !AppEnvironment.isAppStoreReviewMode else {
            friendActionMessage = "Schedule sharing is unavailable in Demo Mode."
            return
        }
        guard let index = friendConnections.firstIndex(where: { $0.id == id }) else { return }
        let connection = friendConnections[index]
        guard connection.status == .pending else { return }
        guard let myGEMSID = verifiedIdentity?.gemsID else {
            friendActionMessage = "GEMS verification is required."
            return
        }

        do {
            try await friendScheduleCloudKitService.cancelFriendRequest(
                myGEMSID: myGEMSID,
                friendGEMSID: connection.employeeID
            )
            friendConnections.removeAll { $0.id == id }
            saveFriendConnections()
            updateScheduleSharingAfterFriendListChange()
            await deleteSharedScheduleDataIfSharingDisabled(gemsID: myGEMSID)
            friendActionMessage = "Request canceled: \(connection.employeeID)"
        } catch {
            friendActionMessage = friendRequestErrorMessage(error)
            logNonFatal("Friend CloudKit cancel failed: \(error.localizedDescription)")
        }
    }

    func acceptIncomingFriendRequest(_ id: UUID) async {
        guard let connection = friendConnections.first(where: { $0.id == id && $0.isIncomingRequest }) else {
            return
        }
        await submitFriendRequest(employeeID: connection.employeeID)
    }

    func removeFriend(_ id: UUID) async {
        guard !AppEnvironment.isAppStoreReviewMode else {
            friendActionMessage = "Schedule sharing is unavailable in Demo Mode."
            return
        }
        guard let index = friendConnections.firstIndex(where: { $0.id == id }) else { return }
        let connection = friendConnections[index]
        guard let myGEMSID = verifiedIdentity?.gemsID else {
            friendActionMessage = "GEMS verification is required."
            return
        }

        do {
            try await friendScheduleCloudKitService.cancelFriendRequest(
                myGEMSID: myGEMSID,
                friendGEMSID: connection.employeeID
            )
            friendConnections.removeAll { $0.id == id }
            saveFriendConnections()
            updateScheduleSharingAfterFriendListChange()
            await deleteSharedScheduleDataIfSharingDisabled(gemsID: myGEMSID)
            friendActionMessage = "Friend removed: \(connection.employeeID)"
        } catch {
            friendActionMessage = friendRequestErrorMessage(error)
            logNonFatal("Friend CloudKit remove failed: \(error.localizedDescription)")
        }
    }

    private func friendRequestErrorMessage(_ error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .permissionFailure:
                return "Friend request could not be saved due to a CloudKit permissions issue. Please contact support if this persists."
            case .networkUnavailable, .networkFailure:
                return "Friend request could not be saved because the network is unavailable. Please try again."
            case .notAuthenticated:
                return "Friend request could not be saved. Please sign into iCloud and try again."
            case .serviceUnavailable, .zoneBusy, .requestRateLimited:
                return "CloudKit is temporarily busy. Please try again in a moment."
            default:
                break
            }
        }
        return "Friend request could not be saved. Please try again."
    }

    private func deleteSharedScheduleDataIfSharingDisabled(gemsID: String) async {
        guard !isScheduleSharingEnabled else { return }
        do {
            try await friendScheduleCloudKitService.deleteSharedScheduleData(gemsID: gemsID)
            friendCloudKitSyncMessage = nil
        } catch {
            friendCloudKitSyncMessage = "Failed to remove shared schedule: \(error.localizedDescription)"
            logNonFatal("Friend CloudKit shared schedule delete failed: \(error.localizedDescription)")
        }
    }

    func setScheduleSharingEnabled(_ enabled: Bool) {
        guard !AppEnvironment.isAppStoreReviewMode else {
            isScheduleSharingEnabled = false
            UserDefaults.standard.set(false, forKey: scheduleSharingEnabledKey)
            friendCloudKitSyncMessage = "Schedule sharing is unavailable in Demo Mode."
            return
        }
        isScheduleSharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: scheduleSharingEnabledKey)
        if enabled {
            Task { [weak self] in
                await self?.syncFriendCloudKit(reason: "sharing enabled")
            }
        } else {
            friendCloudKitSyncMessage = "Schedule sharing is off."
        }
    }

    private func enableScheduleSharingForFriends() {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard !isScheduleSharingEnabled else { return }
        isScheduleSharingEnabled = true
        UserDefaults.standard.set(true, forKey: scheduleSharingEnabledKey)
    }

    private func updateScheduleSharingAfterFriendListChange() {
        guard !AppEnvironment.isAppStoreReviewMode else {
            if isScheduleSharingEnabled {
                isScheduleSharingEnabled = false
                UserDefaults.standard.set(false, forKey: scheduleSharingEnabledKey)
            }
            friendCloudKitSyncMessage = nil
            return
        }
        let hasAcceptedConnection = friendConnections.contains { $0.status == .accepted }
        let shouldShare = isScheduleSharingEnabled && hasAcceptedConnection
        guard isScheduleSharingEnabled != shouldShare else { return }
        isScheduleSharingEnabled = shouldShare
        UserDefaults.standard.set(shouldShare, forKey: scheduleSharingEnabledKey)
        if !shouldShare {
            friendCloudKitSyncMessage = nil
        }
    }

    private func notifyFriendLinked(_ friend: FriendConnection) async {
        await friendLinkNotificationService.notifyFriendLinked(friend)
    }

    private func notifyFriendRequestReceived(_ friend: FriendConnection) async {
        await friendLinkNotificationService.notifyFriendRequestReceived(friend)
    }

    func handleSchedulesChangedForSharing() {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard !isAppReviewMockVerifiedIdentity else { return }
        guard isScheduleSharingEnabled else { return }
        Task { [weak self] in
            await self?.uploadSharedScheduleIfNeeded(reason: "schedule changed")
        }
    }

    func syncFriendCloudKit(reason: String = "manual") async {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard !isAppReviewMockVerifiedIdentity else {
            if let gemsID = verifiedIdentity?.gemsID {
                seedAppReviewMockScheduleIfNeeded(for: gemsID)
            }
            if !acceptedFriendConnections.isEmpty {
                friendCloudKitSyncMessage = "App Review mock schedule sharing active."
            }
            return
        }
        guard !isSyncingFriendCloudKit else { return }
        isSyncingFriendCloudKit = true
        defer { isSyncingFriendCloudKit = false }

        await refreshFriendSchedulesFromCloud()
        await uploadSharedScheduleIfNeeded(reason: reason)
    }

    private func uploadSharedScheduleIfNeeded(reason: String) async {
        if isUploadingSharedSchedule {
            needsSharedScheduleUpload = true
            pendingSharedScheduleUploadReason = reason
            logNonFatal("Friend CloudKit schedule upload coalesced: \(reason)")
            return
        }

        isUploadingSharedSchedule = true
        var nextReason: String? = reason
        defer {
            isUploadingSharedSchedule = false
            needsSharedScheduleUpload = false
            pendingSharedScheduleUploadReason = nil
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsSharedScheduleUpload = false
            pendingSharedScheduleUploadReason = nil
            await performSharedScheduleUploadIfNeeded(reason: currentReason)
            let coalescedReason = pendingSharedScheduleUploadReason
            let shouldUploadAgain = needsSharedScheduleUpload
            needsSharedScheduleUpload = false
            pendingSharedScheduleUploadReason = nil
            nextReason = shouldUploadAgain ? (coalescedReason ?? "coalesced") : nil
        }
    }

    private func performSharedScheduleUploadIfNeeded(reason: String) async {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard !isAppReviewMockVerifiedIdentity else { return }
        guard isScheduleSharingEnabled else { return }
        guard isIdentityVerified,
              let verifiedIdentity,
              let currentCloudKitRecordName else {
            friendCloudKitSyncMessage = "Verify GEMS and iCloud before sharing schedules."
            return
        }
        let shareableSchedules = schedules.isEmpty ? crewAccessSchedules : schedules
        let crewAccessTrips = await Self.loadCrewAccessTripJSONPayloadsFromImportFiles()
        // Enrich schedules with hotel names from local JSON before uploading —
        // friends see hotel names without needing to re-import PDFs.
        let enrichedSchedules = await Task.detached(priority: .utility) {
            Self.enrichSchedulesWithHotelNames(shareableSchedules)
        }.value

        async let sharedScheduleUpload: Void = friendScheduleCloudKitService.uploadSchedule(
            gemsID: verifiedIdentity.gemsID,
            cloudKitRecordName: currentCloudKitRecordName,
            schedules: enrichedSchedules
        )
        async let webSnapshotUpload: Void = friendScheduleCloudKitService.uploadScheduleSnapshot(
            gemsID: verifiedIdentity.gemsID,
            ownerDisplayName: verifiedIdentity.name,
            crewAccessTrips: crewAccessTrips
        )

        do {
            try await sharedScheduleUpload
            friendCloudKitSyncMessage = "Shared schedule updated."
            logNonFatal("Friend CloudKit schedule uploaded: \(reason)")
        } catch {
            friendCloudKitSyncMessage = "Failed to update shared schedule: \(error.localizedDescription)"
            logNonFatal("Friend CloudKit schedule upload failed: \(error.localizedDescription)")
        }

        do {
            try await webSnapshotUpload
            logNonFatal("TripScheduleSnapshot uploaded: \(reason)")
        } catch {
            logNonFatal("TripScheduleSnapshot upload failed: \(error.localizedDescription)")
        }
    }

    func refreshFriendSchedulesFromCloud() async {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard !isAppReviewMockVerifiedIdentity else { return }
        guard isIdentityVerified,
              let verifiedIdentity else {
            return
        }

        do {
            let previouslyPending = Set(friendConnections.filter { $0.status == .pending }.map(\.employeeID))
            let previouslyIncoming = Set(friendConnections.filter { $0.isIncomingRequest }.map(\.employeeID))
            let currentConnections = currentFriendConnections(friendConnections)
            let refreshedConnections = try await friendScheduleCloudKitService.refreshConnections(
                myGEMSID: verifiedIdentity.gemsID,
                connections: currentConnections,
                friendResetAt: friendConnectionsResetAt()
            )
            let nextConnections = currentFriendConnections(refreshedConnections)
            if nextConnections != friendConnections {
                friendConnections = nextConnections
            }
            saveFriendConnections()
            let newlyAccepted = friendConnections.filter {
                $0.status == .accepted && previouslyPending.contains($0.employeeID)
            }
            if !newlyAccepted.isEmpty {
                enableScheduleSharingForFriends()
            }
            updateScheduleSharingAfterFriendListChange()
            friendCloudKitSyncMessage = "Friend schedules updated."
            for friend in newlyAccepted {
                await notifyFriendLinked(friend)
            }
            let newlyIncoming = friendConnections.filter {
                $0.isIncomingRequest && !previouslyIncoming.contains($0.employeeID)
            }
            for friend in newlyIncoming {
                await notifyFriendRequestReceived(friend)
            }
        } catch {
            friendCloudKitSyncMessage = "Failed to update friend schedules: \(error.localizedDescription)"
            logNonFatal("Friend CloudKit refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Device Schedule Sync

    func uploadDeviceScheduleIfNeeded(reason: String) async {
        // Coalescing: if an upload is already in flight, queue the request and return.
        // The in-flight upload will loop until no more pending requests remain (same pattern
        // as uploadSharedScheduleIfNeeded).
        if isUploadingDeviceSchedule {
            needsDeviceScheduleUpload = true
            pendingDeviceScheduleUploadReason = reason
            logNonFatal("Device schedule upload coalesced: \(reason)")
            return
        }

        isUploadingDeviceSchedule = true
        isDeviceSyncing = true
        var nextReason: String? = reason
        defer {
            isUploadingDeviceSchedule = false
            needsDeviceScheduleUpload = false
            pendingDeviceScheduleUploadReason = nil
            isDeviceSyncing = false
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsDeviceScheduleUpload = false
            pendingDeviceScheduleUploadReason = nil
            await performDeviceScheduleUpload(reason: currentReason)
            if needsDeviceScheduleUpload {
                nextReason = pendingDeviceScheduleUploadReason ?? "coalesced"
            }
        }
    }

    private func performDeviceScheduleUpload(reason: String) async {
        guard isIdentityVerified,
              let verifiedIdentity,
              let currentCloudKitRecordName else { return }

        let schedules = crewAccessSchedules
        // Upload even if empty: an empty snapshot signals "all trips deleted" to other devices.
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard fingerprint != lastDeviceScheduleUploadFingerprint else { return }

        let myDeviceID = getOrCreateDeviceID()
        let source: DeviceScheduleSyncSource = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone

        do {
            try await deviceScheduleCloudKitService.uploadDeviceSchedule(
                gemsID: verifiedIdentity.gemsID,
                cloudKitRecordName: currentCloudKitRecordName,
                schedules: schedules,
                deviceID: myDeviceID,
                source: source
            )
            lastDeviceScheduleUploadFingerprint = fingerprint
            UserDefaults.standard.set(fingerprint, forKey: deviceScheduleUploadFingerprintKey)
            deviceSyncStatusMessage = "Device schedule synced."
            logNonFatal("Device schedule uploaded: \(reason) tripCount=\(schedules.count)")
        } catch {
            deviceSyncStatusMessage = "Device sync upload failed."
            logNonFatal("Device schedule upload failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    func fetchDeviceScheduleIfNeeded(reason: String) async {
        guard isIdentityVerified,
              let verifiedIdentity else { return }
        isDeviceSyncing = true
        defer { isDeviceSyncing = false }

        do {
            guard let snapshot = try await deviceScheduleCloudKitService.fetchDeviceSchedule(
                gemsID: verifiedIdentity.gemsID
            ) else { return }

            // Gate 1: skip if we already accepted this exact snapshot.
            if let lastFetch = lastDeviceScheduleFetchAt, snapshot.updatedAt <= lastFetch { return }

            // Gate 2: skip snapshots uploaded by this device — they mirror local state.
            let myDeviceID = getOrCreateDeviceID()
            if snapshot.deviceID == myDeviceID { return }

            // Gate 3 (local-wins): reject remote if any local schedule is newer than the snapshot.
            // This prevents a stale remote from rolling back a local import that failed to upload.
            let localMaxUpdatedAt = crewAccessSchedules.map(\.updatedAt).max()
            if let localMax = localMaxUpdatedAt, snapshot.updatedAt <= localMax { return }

            // LogTen backlog protection: preserve import reference times across schedule replacement.
            // Intentionally not pruned so past-leg entries survive for any future LogTen export.
            let preservedReferenceTimes = crewAccessLegImportReferenceTimes

            let remoteSchedules = snapshot.schedules.filter { schedule in
                Self.crewAccessTripKeys(for: schedule, domicile: verifiedIdentity.domicile)
                    .isDisjoint(with: deletedCrewAccessTripKeys)
            }
            try cacheService.save(ScheduleCacheSnapshotV2(
                crewAccessSchedules: remoteSchedules,
                bidproSchedules: bidproSchedules,
                lastSyncAt: lastSyncAt ?? Date(),
                migratedAt: nil
            ))
            crewAccessSchedules = remoteSchedules
            crewAccessLegImportReferenceTimes = preservedReferenceTimes
            schedules = mergeAndSortSchedules(crew: remoteSchedules, bidpro: bidproSchedules)
            handleSchedulesChangedForSharing()
            lastDeviceScheduleFetchAt = snapshot.updatedAt
            UserDefaults.standard.set(snapshot.updatedAt, forKey: deviceScheduleFetchAtKey)

            await rescheduleNotificationsIfAuthorized()
            deviceSyncStatusMessage = "Schedule updated from device sync."
            logNonFatal("Device schedule fetched: \(reason) source=\(snapshot.source.rawValue) tripCount=\(remoteSchedules.count)")
        } catch {
            logNonFatal("Device schedule fetch failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    private func saveDeletedCrewAccessTripKeys() {
        UserDefaults.standard.set(Array(deletedCrewAccessTripKeys).sorted(), forKey: deletedCrewAccessTripKeysKey)
    }

    // MARK: - Manual Event Device Sync

    func uploadManualEventsIfNeeded(reason: String) async {
        if isUploadingManualEvents {
            needsManualEventUpload = true
            pendingManualEventUploadReason = reason
            logNonFatal("Manual event upload coalesced: \(reason)")
            return
        }

        isUploadingManualEvents = true
        isDeviceSyncing = true
        var nextReason: String? = reason
        defer {
            isUploadingManualEvents = false
            needsManualEventUpload = false
            pendingManualEventUploadReason = nil
            isDeviceSyncing = false
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsManualEventUpload = false
            pendingManualEventUploadReason = nil
            await performManualEventUpload(reason: currentReason)
            if needsManualEventUpload {
                nextReason = pendingManualEventUploadReason ?? "coalesced"
            }
        }
    }

    private func performManualEventUpload(reason: String) async {
        guard isIdentityVerified,
              let verifiedIdentity,
              let currentCloudKitRecordName else { return }

        let snapshot = currentManualEventSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard fingerprint != lastManualEventUploadFingerprint else { return }

        let myDeviceID = getOrCreateDeviceID()
        let source: DeviceScheduleSyncSource = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone

        do {
            try await manualEventCloudKitService.uploadManualEvents(
                gemsID: verifiedIdentity.gemsID,
                cloudKitRecordName: currentCloudKitRecordName,
                snapshot: snapshot,
                deviceID: myDeviceID,
                source: source
            )
            lastManualEventUploadFingerprint = fingerprint
            UserDefaults.standard.set(fingerprint, forKey: manualEventUploadFingerprintKey)
            deviceSyncStatusMessage = "Manual events synced."
            logNonFatal("Manual events uploaded: \(reason) operational=\(snapshot.operationalEvents.count) personal=\(snapshot.personalEvents.count) tombstones=\(snapshot.tombstones.count)")
        } catch {
            deviceSyncStatusMessage = "Manual event sync upload failed."
            logNonFatal("Manual event upload failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    func fetchManualEventsIfNeeded(reason: String) async {
        guard isIdentityVerified,
              let verifiedIdentity else { return }
        isDeviceSyncing = true
        defer { isDeviceSyncing = false }

        do {
            guard let remote = try await manualEventCloudKitService.fetchManualEvents(
                gemsID: verifiedIdentity.gemsID
            ) else { return }

            if let lastFetch = lastManualEventFetchAt, remote.updatedAt <= lastFetch { return }

            let myDeviceID = getOrCreateDeviceID()
            let localSnapshot = currentManualEventSnapshot()
            let merged = mergeManualEventSnapshots(local: localSnapshot, remote: remote.manualEvents)
            guard merged != localSnapshot else {
                lastManualEventFetchAt = remote.updatedAt
                UserDefaults.standard.set(remote.updatedAt, forKey: manualEventFetchAtKey)
                return
            }

            try manualEventStore.save(merged)
            manualOperationalEvents = merged.operationalEvents
            manualPersonalEvents = merged.personalEvents
            manualEventTombstones = merged.tombstones
            lastManualEventFetchAt = remote.updatedAt
            UserDefaults.standard.set(remote.updatedAt, forKey: manualEventFetchAtKey)
            deviceSyncStatusMessage = "Manual events updated from device sync."
            logNonFatal("Manual events fetched: \(reason) source=\(remote.source.rawValue) operational=\(merged.operationalEvents.count) personal=\(merged.personalEvents.count) tombstones=\(merged.tombstones.count)")

            if remote.deviceID != myDeviceID {
                await uploadManualEventsIfNeeded(reason: "manual event merge")
            }
        } catch {
            logNonFatal("Manual event fetch failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    private func currentManualEventSnapshot() -> ManualEventStoreSnapshot {
        ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: manualEventTombstones
        )
    }

    // MARK: - CrewAccess Import CloudKit Sync

    func fetchCrewAccessImportFilesIfNeeded(reason: String) async {
        guard isIdentityVerified, let verifiedIdentity else { return }
        guard !isFetchingCrewAccessImports else { return }
        isFetchingCrewAccessImports = true
        defer { isFetchingCrewAccessImports = false }

        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)

        do {
            let records = try await crewAccessImportCloudKitService.fetchImportFiles(gemsID: verifiedIdentity.gemsID)
            var writtenCount = 0
            for record in records {
                let url = dir.appendingPathComponent(record.fileName)
                let localModifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let deletedAt = record.deletedAt {
                    // Tombstoned remotely: remove local file only when the tombstone is
                    // newer than the local JSON. A re-import can recreate the same file
                    // name after an older tombstone; in that case local import wins.
                    if fm.fileExists(atPath: url.path),
                       localModifiedAt.map({ deletedAt >= $0 }) ?? true {
                        try? fm.removeItem(at: url)
                    }
                    continue
                }
                if Self.crewAccessTripKey(fromCloudKitRecord: record).map({ deletedCrewAccessTripKeys.contains($0) }) == true {
                    if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
                    await tombstoneCrewAccessImportFiles(fileNames: [record.fileName])
                    continue
                }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = url
                guard localModifiedAt == nil || record.updatedAt > localModifiedAt! else { continue }
                try? record.jsonData.write(to: fileURL)
                writtenCount += 1
            }
            lastCrewAccessImportFetchAt = Date()
            UserDefaults.standard.set(lastCrewAccessImportFetchAt, forKey: crewAccessImportFetchAtKey)
            logNonFatal("CrewAccess import files fetched: \(reason) total=\(records.count) written=\(writtenCount)")
        } catch {
            logNonFatal("CrewAccess import file fetch failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    private func uploadCrewAccessImportFile(at url: URL, json: CrewAccessTripJSON) async {
        let fileName = url.lastPathComponent
        guard isIdentityVerified, let verifiedIdentity else {
            logger.info("[CrewAccessImportUpload] skipped (identity not verified) file=\(fileName, privacy: .private)")
            return
        }
        guard let jsonData = try? Data(contentsOf: url) else {
            logger.info("[CrewAccessImportUpload] skipped (cannot read file) path=\(url.path, privacy: .private)")
            return
        }
        let firstDep = json.items.first?.startUtc
        logger.info("[CrewAccessImportUpload] start file=\(fileName, privacy: .private) bytes=\(jsonData.count, privacy: .public) gems=\(verifiedIdentity.gemsID, privacy: .private)")
        do {
            try await crewAccessImportCloudKitService.uploadImportFile(
                gemsID: verifiedIdentity.gemsID,
                fileName: fileName,
                jsonData: jsonData,
                tripInformationDate: json.tripInformationDate,
                firstDepartureUTC: firstDep
            )
            logger.info("[CrewAccessImportUpload] success file=\(fileName, privacy: .private)")
            logNonFatal("CrewAccess import file uploaded: \(fileName)")
        } catch {
            logger.error("[CrewAccessImportUpload] FAILED file=\(fileName, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            logNonFatal("CrewAccess import file upload failed: \(error.localizedDescription) file=\(fileName)")
        }
    }

    private func tombstoneCrewAccessImportFiles(fileNames: [String]) async {
        guard isIdentityVerified, let verifiedIdentity else { return }
        for fileName in fileNames {
            do {
                try await crewAccessImportCloudKitService.tombstoneImportFile(
                    gemsID: verifiedIdentity.gemsID,
                    fileName: fileName
                )
            } catch {
                logNonFatal("CrewAccess tombstone failed: \(error.localizedDescription) file=\(fileName)")
            }
        }
    }

    private func getOrCreateDeviceID() -> String {
        if let existing = cachedDeviceID { return existing }
        let stored = UserDefaults.standard.string(forKey: deviceIDKey)
        if let stored {
            cachedDeviceID = stored
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: deviceIDKey)
        cachedDeviceID = newID
        return newID
    }

    func refreshCloudKitIdentity() {
        if AppEnvironment.isAppStoreReviewMode {
            cloudKitIdentityMessage = nil
            currentCloudKitRecordName = nil
            updateAdminStatus()
            return
        }
        guard !isRefreshingCloudKitIdentity else { return }
        isRefreshingCloudKitIdentity = true

        if !useCloudKitIdentity {
            let recordName = localIdentityRecordName()
            currentCloudKitRecordName = recordName
            if let verifiedIdentity,
               verifiedIdentity.cloudKitRecordName != recordName {
                self.verifiedIdentity = nil
                clearVerifiedIdentity()
            }
            updateAdminStatus()
            isRefreshingCloudKitIdentity = false
            return
        }

        let containerIdentifier = cloudKitContainerIdentifier
        let timeoutNanoseconds = cloudKitIdentityTimeoutNanoseconds
        logCloudKitIdentityDiagnostic("begin container=\(containerIdentifier)")
        Task.detached(priority: .utility) { [weak self] in
            let container = CKContainer(identifier: containerIdentifier)
            let result: Result<String, Error> = await withTaskGroup(of: Result<String, Error>.self) { group in
                group.addTask {
                    do {
                        let status = try await container.accountStatus()
                        guard status == .available else {
                            return .failure(CloudKitIdentityFetchError.accountStatus(status))
                        }
                        let recordID = try await container.userRecordID()
                        return .success(recordID.recordName)
                    } catch {
                        return .failure(error)
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return .failure(CloudKitIdentityFetchError.timeout)
                }
                let first = await group.next() ?? .failure(CloudKitIdentityFetchError.timeout)
                group.cancelAll()
                return first
            }

            Task { @MainActor [weak self] in
                guard let self, self.isRefreshingCloudKitIdentity else { return }
                self.isRefreshingCloudKitIdentity = false

                switch result {
                case let .success(recordName):
                    self.logCloudKitIdentityDiagnostic("success recordName=\(recordName)")
                    self.cloudKitIdentityMessage = nil
                    self.currentCloudKitRecordName = recordName
                    if let verifiedIdentity = self.verifiedIdentity,
                       verifiedIdentity.cloudKitRecordName != recordName {
                        self.verifiedIdentity = nil
                        self.clearVerifiedIdentity()
                    }
                    self.updateAdminStatus()
                    if self.isIdentityVerified {
                        Task { await self.fetchDeviceScheduleIfNeeded(reason: "identity verified") }
                        Task { await self.fetchManualEventsIfNeeded(reason: "identity verified") }
                    }
                case let .failure(error):
                    if case CloudKitIdentityFetchError.timeout = error {
                        self.logCloudKitIdentityDiagnostic("timeout after \(timeoutNanoseconds / 1_000_000_000)s")
                        self.logNonFatal("CloudKit identity fetch timed out.")
                        self.keepCachedIdentityAfterTransientCloudKitFailure("CloudKit identity timed out. Using the last verified GEMS identity for now.")
                    } else if case let CloudKitIdentityFetchError.accountStatus(status) = error {
                        self.logCloudKitIdentityDiagnostic("accountStatus=\(Self.cloudKitAccountStatusDescription(status))")
                        self.logNonFatal("CloudKit identity unavailable: \(Self.cloudKitAccountStatusDescription(status))")
                        self.handleCloudKitAccountStatusFailure(status)
                    } else {
                        self.logCloudKitIdentityDiagnostic("failure error=\(error.localizedDescription)")
                        self.logNonFatal("Failed to fetch CloudKit identity: \(error.localizedDescription)")
                        self.keepCachedIdentityAfterTransientCloudKitFailure("CloudKit identity is temporarily unavailable. Using the last verified GEMS identity for now.")
                    }
                }
            }
        }
    }

    private func handleCloudKitAccountStatusFailure(_ status: CKAccountStatus) {
        switch status {
        case .available:
            keepCachedIdentityAfterTransientCloudKitFailure("CloudKit identity is temporarily unavailable. Using the last verified GEMS identity for now.")
        case .noAccount:
            cloudKitIdentityMessage = "Sign into iCloud to share schedules across devices."
            if currentCloudKitRecordName == nil {
                currentCloudKitRecordName = verifiedIdentity?.cloudKitRecordName ?? localIdentityRecordName()
            }
            updateAdminStatus()
        case .restricted:
            cloudKitIdentityMessage = "iCloud access is restricted on this device."
            currentCloudKitRecordName = nil
            updateAdminStatus()
        case .couldNotDetermine:
            keepCachedIdentityAfterTransientCloudKitFailure("CloudKit account status could not be confirmed. Using the last verified GEMS identity for now.")
        case .temporarilyUnavailable:
            keepCachedIdentityAfterTransientCloudKitFailure("CloudKit is temporarily unavailable. Using the last verified GEMS identity for now.")
        @unknown default:
            keepCachedIdentityAfterTransientCloudKitFailure("CloudKit account status is unknown. Using the last verified GEMS identity for now.")
        }
    }

    private func keepCachedIdentityAfterTransientCloudKitFailure(_ message: String) {
        cloudKitIdentityMessage = message
        if currentCloudKitRecordName == nil,
           let verifiedIdentity {
            currentCloudKitRecordName = verifiedIdentity.cloudKitRecordName
        }
        updateAdminStatus()
    }

    private func logCloudKitIdentityDiagnostic(_ message: String) {
        let environment: String
#if targetEnvironment(simulator)
        environment = "simulator"
#else
        environment = "device"
#endif
        let ubiquityTokenState = FileManager.default.ubiquityIdentityToken == nil ? "missing" : "present"
        logNonFatal("[CloudKitIdentity] \(message) environment=\(environment) ubiquityToken=\(ubiquityTokenState)")
    }

    private nonisolated static func cloudKitAccountStatusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "available"
        case .couldNotDetermine:
            return "couldNotDetermine"
        case .noAccount:
            return "noAccount"
        case .restricted:
            return "restricted"
        case .temporarilyUnavailable:
            return "temporarilyUnavailable"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    @discardableResult
    // Developer-only compatibility hook for tests and pre-UI automation. The production
    // Admin tab no longer exposes CSV upload because source seniority CSVs contain DOB.
    // Use scripts/upload_gems_verification.js for monthly CloudKit verification updates.
    func importSeniorityCSVData(_ data: Data) async -> Bool {
        guard !isUploadingGEMSVerification else {
            seniorityImportMessage = "GEMS verification upload is already running."
            return false
        }
        isUploadingGEMSVerification = true
        defer { isUploadingGEMSVerification = false }

        guard let text = String(data: data, encoding: .utf8) else {
            seniorityImportMessage = "Failed to decode CSV as UTF-8."
            return false
        }

        let parsedRecords = parseGEMSVerificationCSV(text)
        guard !parsedRecords.isEmpty else {
            seniorityImportMessage = "No valid GEMS/DOB verification records found."
            return false
        }

        do {
            seniorityImportMessage = "Uploading \(parsedRecords.count) GEMS verification records..."
            let uploadedCount = try await gemsVerificationCloudKitService.uploadVerificationRecords(
                parsedRecords,
                progress: { [weak self] uploaded, total in
                    self?.seniorityImportMessage = "Uploaded \(uploaded) / \(total) GEMS verification records..."
                }
            )
            seniorityRecords = []
            gemsVerificationRecordCount = uploadedCount
            hasLoadedSeniorityRecords = true
            hasSeniorityDataOnDisk = false
            seniorityImportMessage = "Uploaded \(uploadedCount) GEMS verification records to CloudKit."
            return true
        } catch {
            seniorityImportMessage = "Failed to upload GEMS verification records: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func importCrewAccessPDFData(_ data: Data, sourceFileName: String?) async -> Bool {
        guard !importInProgress else { return false }
        importInProgress = true

        let fingerprint = importPayloadFingerprint(data: data, sourceFileName: sourceFileName)

        guard pendingImport == nil else {
            logger.info("[Import] importCrewAccessPDFData skipped (pendingImport already set) file=\(sourceFileName ?? "unknown", privacy: .private)")
            importInProgress = false
            return false
        }

        guard Self.claimPersistentFingerprint(fingerprint) else {
            logger.info("[Import] importCrewAccessPDFData skipped (cross-launch dedup) file=\(sourceFileName ?? "unknown", privacy: .private)")
            importInProgress = false
            return false
        }
        logger.info("[Import] importCrewAccessPDFData called file=\(sourceFileName ?? "unknown", privacy: .private) bytes=\(data.count, privacy: .public)")
        // PDF parsing is CPU-heavy (PDFKit text extraction + regex passes).
        // Run it off the main actor so the UI stays responsive on large trips.
        let service = crewAccessImportService
        let draft = await Task.detached(priority: .utility) {
            service.analyzeTrip(pdfData: data, sourceFileName: sourceFileName)
        }.value
        pendingImport = PendingImport(
            id: UUID(),
            source: .crewAccessPDF,
            sourceFileName: draft.sourceFileName,
            tripId: draft.tripId,
            tripDate: draft.tripDate,
            parsedSchedule: draft.parsedSchedule,
            jsonPayload: draft.jsonPayload,
            warnings: draft.warnings,
            errors: draft.errors,
            createdAt: Date(),
            rawExtractStats: draft.rawExtractStats
        )
        let pendingImportID = pendingImport?.id.uuidString ?? "nil"
        logger.info("[Import] pendingImport set id=\(pendingImportID, privacy: .public) tripId=\(draft.tripId, privacy: .private) errors=\(draft.errors.count, privacy: .public) warnings=\(draft.warnings.count, privacy: .public)")

        if draft.errors.isEmpty {
            crewAccessImportMessage = "Parsed CrewAccess PDF. Review and confirm import."
        } else {
            crewAccessImportMessage = "CrewAccess preview has errors. Fix and retry."
        }
        return true
    }

    func queueExternalOpenURL(_ url: URL) {
        let key = ExternalOpenLaunchGate.stableKey(for: url)
        Task { [weak self] in
            guard let self else { return }
            let accepted = await self.externalOpenCoordinator.enqueue(key: key, url: url, now: Date())
            if accepted {
                self.pendingExternalOpenURL = url
                logger.info("[Import] queueExternalOpenURL accepted key=\(key, privacy: .private)")
                self.startExternalConsumerIfNeeded()
            } else {
                logger.info("[Import] queueExternalOpenURL skipped (duplicate) key=\(key, privacy: .private)")
            }
        }
    }

    private func startExternalConsumerIfNeeded() {
        guard externalConsumerTask == nil else {
            logger.info("[Import] consumeExternalOpenURL skipped (already running)")
            return
        }
        externalConsumerTask = Task { [weak self] in
            defer {
                // Always clear the task reference so startExternalConsumerIfNeeded
                // can create a new one, even if this Task exits via cancellation.
                self?.externalConsumerTask = nil
            }
            guard let self else { return }
            await self.externalConsumerLoop()
        }
        logger.info("[Import] externalConsumer start")
    }

    private func externalConsumerLoop() async {
        while true {
            guard let nextItem = await externalOpenCoordinator.dequeueNext() else {
                pendingExternalOpenURL = nil
                logger.info("[Import] externalConsumer stop")
                break
            }
            let url = nextItem.url
            let key = nextItem.key

            let markedInFlight = await externalOpenCoordinator.markInFlight(key)
            if !markedInFlight {
                logger.info("[Import] consumeExternalOpenURL skipped (already running)")
                continue
            }

            var isSuccess = false
            logger.info("[Import] consumeExternalOpenURL begin key=\(key, privacy: .private)")

            if pendingImport != nil {
                logger.info("[Import] consumeExternalOpenURL skipped (pending import exists)")
                crewAccessImportMessage = "Another import is waiting for review. Confirm or dismiss the current import first."
                hasQueuedImport = true
                await externalOpenCoordinator.finish(key: key, success: false)
                await externalOpenCoordinator.requeueFront(nextItem)
                pendingExternalOpenURL = nil
                logger.info("[Import] consumeExternalOpenURL done key=\(key, privacy: .private) ok=\(isSuccess, privacy: .public)")
                break
            }

            guard url.isFileURL else {
                crewAccessImportMessage = "Import failed: shared item is not a file URL."
                await externalOpenCoordinator.finish(key: key, success: false)
                pendingExternalOpenURL = nil
                logger.info("[Import] consumeExternalOpenURL done key=\(key, privacy: .private) ok=\(isSuccess, privacy: .public)")
                continue
            }

            do {
                let data = try await Task.detached(priority: .utility) {
                    try await Self.readExternalPDFDataWithFallback(from: url, timeoutSeconds: 3)
                }.value
                logger.info("[Import] coordinated read success bytes=\(data.count, privacy: .public)")
                let sniff = Self.sniffPDFSignature(in: data)
                logger.info("[Import] sniffPDF=\(sniff.isPDF, privacy: .public) header=\(sniff.header, privacy: .public)")
                guard sniff.isPDF else {
                    crewAccessImportMessage = "Selected file is not a PDF. Re-export using Zscaler Print and retry."
                    await externalOpenCoordinator.finish(key: key, success: false)
                    pendingExternalOpenURL = nil
                    logger.info("[Import] consumeExternalOpenURL done key=\(key, privacy: .private) ok=false (not PDF)")
                    continue
                }
                let importAccepted = await importCrewAccessPDFData(data, sourceFileName: url.lastPathComponent)
                if pendingImport != nil {
                    cleanupImportedExternalFileBestEffort(at: url)
                    isSuccess = true
                } else if !importAccepted {
                    cleanupImportedExternalFileBestEffort(at: url)
                }
            } catch {
                crewAccessImportMessage = "Failed to read PDF: \(error.localizedDescription)"
                logNonFatal("External open import failed: \(error.localizedDescription)")
            }
            await externalOpenCoordinator.finish(key: key, success: isSuccess)
            pendingExternalOpenURL = nil
            logger.info("[Import] consumeExternalOpenURL done key=\(key, privacy: .private) ok=\(isSuccess, privacy: .public)")
        }
    }

    func confirmPendingImport() async {
        guard let pendingImport else {
            crewAccessImportMessage = "No pending CrewAccess import to confirm."
            return
        }
        guard pendingImport.canConfirm,
              let schedule = pendingImport.parsedSchedule,
              let json = pendingImport.jsonPayload else {
            crewAccessImportMessage = "Cannot confirm import while errors exist."
            // importInProgress stays true; user must discard to reset.
            return
        }

        do {
            // Compute overlap IDs before any writes so we can roll back cleanly.
            // Deletion happens AFTER the new import is committed (see below).
            let overlapCandidates = importReplacementCandidates(incomingScheduleID: schedule.id, incomingJSON: json)
                .filter { $0.reason == .timeOverlap }
            let overlapIDs = Set(
                overlapCandidates
                    .map(\.id)
            )
            let overlapPairings = Set(
                overlapCandidates
                    .flatMap(\.pairings)
            )

            let replacing = crewAccessSchedules.contains(where: { $0.id == schedule.id })
            let jsonWriteContext = try persistCrewAccessJSON(json)
            do {
                try mergeImportedCrewAccessSchedule(schedule)
                removeStaleCrewAccessJSONFilesBestEffort(jsonWriteContext.staleSameBidPeriodTripURLs)
                await applyCrewAccessRetentionPolicy()
            } catch {
                do {
                    try rollbackCrewAccessJSONWrite(with: jsonWriteContext)
                } catch {
                    logNonFatal("Failed to rollback CrewAccess JSON after merge/cache error: \(error.localizedDescription)")
                }
                throw error
            }

            // New import committed successfully — safe to tombstone overlapping trips.
            if !overlapIDs.isEmpty || !overlapPairings.isEmpty {
                // Merge/reconcile can remove or reshape the original overlap schedule IDs before
                // this cleanup runs. Re-resolve from the post-merge schedule list by the captured
                // IDs and pairings so we tombstone only the previously detected time-overlap files.
                // The newly imported schedule is not included because same-Trip-ID candidates are
                // filtered out above; these pairings come only from time-overlap candidates.
                let resolvedOverlapIDs = Set(
                    crewAccessSchedules
                        .filter { existing in
                            let existingPairings = Set(existing.legs.map(\.pairing))
                            return overlapIDs.contains(existing.id)
                                || !existingPairings.isDisjoint(with: overlapPairings)
                        }
                        .map(\.id)
                )
                if !resolvedOverlapIDs.isEmpty {
                    await deleteCrewAccessTrips(ids: resolvedOverlapIDs)
                }
                let overlapTripIDs = overlapPairings.map(Self.normalizedCrewAccessTripID)
                if !overlapTripIDs.isEmpty {
                    _ = await Task.detached(priority: .utility) {
                        Self.deleteCrewAccessImportFilesBestEffort(
                            scheduleIDs: Array(resolvedOverlapIDs),
                            tripIDs: overlapTripIDs,
                            tripKeys: []
                        )
                    }.value
                }
            }

            lastImportDidReplaceExistingTrip = replacing
            if replacing {
                lastImportSummaryMessage = "Updated existing CrewAccess trip \(schedule.id)."
            } else {
                lastImportSummaryMessage = "Imported new CrewAccess trip \(schedule.id)."
            }
            self.pendingImport = nil
            hasQueuedImport = false
            await resetExternalOpenDedup()
            importInProgress = false
            startExternalConsumerIfNeeded()
            crewAccessImportMessage = "CrewAccess import complete: \(json.tripId) (\(schedule.legCount) legs)."
            errorMessage = nil
            await rescheduleNotificationsIfAuthorized()
            let uploadURL = jsonWriteContext.finalURL
            let staleFileNames = jsonWriteContext.staleSameBidPeriodTripURLs.map(\.lastPathComponent)
            Task { [weak self] in
                await self?.uploadDeviceScheduleIfNeeded(reason: "import confirmed")
                await self?.uploadCrewAccessImportFile(at: uploadURL, json: json)
                if !staleFileNames.isEmpty {
                    await self?.tombstoneCrewAccessImportFiles(fileNames: staleFileNames)
                }
            }
        } catch {
            crewAccessImportMessage = "Import failed: unable to write CrewAccess JSON. No changes were applied."
            logNonFatal("CrewAccess confirm transaction failed: \(error.localizedDescription)")
            importInProgress = false
        }
    }

    func discardPendingImport() async {
        pendingImport = nil
        hasQueuedImport = false
        crewAccessImportMessage = "CrewAccess import preview discarded."
        await resetExternalOpenDedup()
        importInProgress = false
        startExternalConsumerIfNeeded()
    }

    private struct CrewAccessTripHeader: Decodable {
        let tripId: String?
        let tripInformationDate: String?
    }

    // MARK: - Import replacement / supersede types

    enum TripReplacementReason {
        case sameTripID
        case timeOverlap
    }

    struct TripImportReplacementCandidate: Identifiable {
        let id: String          // existing schedule.id
        let tripId: String      // pairing(s) for display
        let pairings: Set<String>
        let reason: TripReplacementReason
    }

    /// Existing schedules that the pending import would replace or supersede.
    /// Updated automatically when `pendingImport` or `crewAccessSchedules` changes.
    var pendingImportReplacementCandidates: [TripImportReplacementCandidate] {
        guard let pending = pendingImport,
              let schedule = pending.parsedSchedule,
              let json = pending.jsonPayload
        else { return [] }
        return importReplacementCandidates(incomingScheduleID: schedule.id, incomingJSON: json)
    }

    private func importReplacementCandidates(
        incomingScheduleID: String,
        incomingJSON: CrewAccessTripJSON
    ) -> [TripImportReplacementCandidate] {
        let incomingPairing = incomingJSON.tripId
        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        let newStart = incomingJSON.items
            .compactMap { LegConnectionTextBuilder.parseUTC($0.startUtc) }.min()
        let newEnd = incomingJSON.items
            .compactMap { LegConnectionTextBuilder.parseUTC($0.endUtc) }.max()
        let reportWindowStart = newStart.map { $0.addingTimeInterval(-90 * 60) }
        var incomingDayKeys = Self.baseLocalDayKeys(startUTC: newStart, endUTC: newEnd, domicile: domicile)
        incomingDayKeys.formUnion(Self.tripInformationDayKeys(incomingJSON.tripInformationDate))

        var candidates: [TripImportReplacementCandidate] = []
        for existing in crewAccessSchedules {
            let existingPairings = Set(existing.legs.map(\.pairing))
            if existing.id == incomingScheduleID {
                // Same schedule (normal re-import of same Trip ID). Show orange warning.
                candidates.append(TripImportReplacementCandidate(
                    id: existing.id,
                    tripId: existingPairings.sorted().joined(separator: ", "),
                    pairings: existingPairings,
                    reason: .sameTripID
                ))
                continue
            }
            if existingPairings.contains(incomingPairing),
               let incomingKey = Self.crewAccessTripKey(
                tripID: incomingPairing,
                startUTC: newStart,
                endUTC: newEnd,
                domicile: domicile
               ),
               Self.crewAccessTripKeys(for: existing, domicile: domicile).contains(incomingKey) {
                // Same Trip ID inside the same Bid Period. Different BPs can reuse Trip IDs.
                candidates.append(TripImportReplacementCandidate(
                    id: existing.id,
                    tripId: existingPairings.sorted().joined(separator: ", "),
                    pairings: existingPairings,
                    reason: .sameTripID
                ))
                continue
            }
            if let ws = reportWindowStart, let we = newEnd {
                let exStart = existing.legs.compactMap { LegConnectionTextBuilder.parseUTC($0.depUTC) }.min()
                let exEnd   = existing.legs.compactMap { LegConnectionTextBuilder.parseUTC($0.arrUTC) }.max()
                if let s = exStart, let e = exEnd, ws < e && we > s {
                    candidates.append(TripImportReplacementCandidate(
                        id: existing.id,
                        tripId: existingPairings.sorted().joined(separator: ", "),
                        pairings: existingPairings,
                        reason: .timeOverlap
                    ))
                    continue
                }
            }
            let existingDayKeys = Self.baseLocalDayKeys(
                startUTC: existing.legs.compactMap { LegConnectionTextBuilder.parseUTC($0.depUTC) }.min(),
                endUTC: existing.legs.compactMap { LegConnectionTextBuilder.parseUTC($0.arrUTC) }.max(),
                domicile: domicile
            )
            if !incomingDayKeys.isEmpty,
               !existingDayKeys.isEmpty,
               !incomingDayKeys.isDisjoint(with: existingDayKeys) {
                candidates.append(TripImportReplacementCandidate(
                    id: existing.id,
                    tripId: existingPairings.sorted().joined(separator: ", "),
                    pairings: existingPairings,
                    reason: .timeOverlap
                ))
            }
        }
        return candidates
    }

    private nonisolated static func baseLocalDayKeys(startUTC: Date?, endUTC: Date?, domicile: String) -> Set<String> {
        guard let startUTC, let endUTC else { return [] }
        let zone = DomicileSupport.timeZone(for: domicile)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var keys = Set<String>()
        var cursor = calendar.startOfDay(for: min(startUTC, endUTC))
        let endDay = calendar.startOfDay(for: max(startUTC, endUTC))
        var guardCount = 0
        while cursor <= endDay, guardCount < 90 {
            let components = calendar.dateComponents([.year, .month, .day], from: cursor)
            if let year = components.year, let month = components.month, let day = components.day {
                keys.insert(String(format: "%04d-%02d-%02d", year, month, day))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return keys
    }

    private nonisolated static func tripInformationDayKeys(_ raw: String?) -> Set<String> {
        let normalized = normalizeTripInformationDateForDisplay(raw, fallbackDate: nil)
        guard !normalized.usedFallback, normalized.dateString != "UnknownDate" else { return [] }
        return [normalized.dateString]
    }

    private struct CrewAccessScheduleReference: Hashable {
        let id: String
        let label: String
        let pairings: Set<String>
        let tripKeys: Set<String>
    }

    private struct CrewAccessFileDeletionResult {
        let deleted: Bool
        let tripId: String?
        let tripInformationDate: String?
        let matchedScheduleIDs: [String]
    }

    func listCrewAccessImportFiles() async -> [CrewAccessImportFile] {
        let scheduleReferences = crewAccessSchedules.map {
            CrewAccessScheduleReference(
                id: $0.id,
                label: $0.label,
                pairings: Set($0.legs.map(\.pairing)),
                tripKeys: Self.crewAccessTripKeys(
                    for: $0,
                    domicile: verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
                )
            )
        }
        return await Task.detached(priority: .utility) { () -> [CrewAccessImportFile] in
            let fm = FileManager.default
            guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
            let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { return [] }

            do {
                let urls = try fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                return urls.compactMap { url in
                    guard let values = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey]
                    ) else {
                        return nil
                    }
                    guard values.isRegularFile == true, url.pathExtension.lowercased() == "json" else { return nil }
                    let createdAt = values.creationDate
                    let modifiedAt = values.contentModificationDate
                    let header = Self.readCrewAccessTripHeader(from: url)
                    let fileName = url.lastPathComponent
                    let inferredTripId = Self.inferTripIdFromFileName(fileName)
                    let tripId = (header?.tripId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        ? (header?.tripId ?? inferredTripId)
                        : inferredTripId
                    let displayDateResult = Self.normalizeTripInformationDateForDisplay(
                        header?.tripInformationDate,
                        fallbackDate: modifiedAt
                    )
                    let displayName = "\(displayDateResult.dateString)_\(tripId)"
                    let matchedScheduleId = Self.matchScheduleID(
                        tripId: tripId,
                        tripInformationDate: header?.tripInformationDate,
                        scheduleReferences: scheduleReferences
                    )
                    return CrewAccessImportFile(
                        fileName: fileName,
                        url: url,
                        bytes: Int64(values.fileSize ?? 0),
                        createdAt: createdAt,
                        modifiedAt: modifiedAt,
                        tripId: tripId,
                        tripInformationDate: header?.tripInformationDate,
                        displayName: displayName,
                        usedFallbackDate: displayDateResult.usedFallback,
                        matchedScheduleId: matchedScheduleId,
                        isOrphan: matchedScheduleId == nil
                    )
                }.sorted { lhs, rhs in
                    if lhs.fileName == rhs.fileName {
                        let lhsDate = lhs.modifiedAt ?? lhs.createdAt ?? .distantPast
                        let rhsDate = rhs.modifiedAt ?? rhs.createdAt ?? .distantPast
                        return lhsDate < rhsDate
                    }
                    return lhs.fileName < rhs.fileName
                }
            } catch {
                return [CrewAccessImportFile]()
            }
        }.value
    }

    func applyCrewAccessRetentionPolicy() async {
        let deletedFileCount: Int
        if let retainedOrders = retainedCrewAccessBidPeriodOrders() {
            deletedFileCount = await Task.detached(priority: .utility) {
                Self.deleteCrewAccessImportFilesOutsideRetainedBidPeriods(retainedOrders: retainedOrders)
            }.value
            if deletedFileCount > 0 {
                logger.info("[CrewAccessRetention] keptPeriods=\(retainedOrders.map(String.init).sorted().joined(separator: ","), privacy: .public) deletedFiles=\(deletedFileCount, privacy: .public)")
            }
        } else {
            deletedFileCount = 0
        }

        await reconcileCrewAccessSchedulesWithImportFiles()
    }

    func reconcileCrewAccessSchedulesWithImportFiles() async {
        let deletedKeys = deletedCrewAccessTripKeys
        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        let rebuiltSchedules = await Task.detached(priority: .utility) {
            Self.loadCrewAccessSchedulesFromImportFiles().filter { schedule in
                Self.crewAccessTripKeys(for: schedule, domicile: domicile).isDisjoint(with: deletedKeys)
            }
        }.value

        guard rebuiltSchedules != crewAccessSchedules else { return }

        let rebuiltPairings = Set(rebuiltSchedules.flatMap { $0.legs.map(\.pairing) })
        let removedSchedules = crewAccessSchedules.compactMap { schedule -> PayPeriodSchedule? in
            let removedLegs = schedule.legs.filter { !rebuiltPairings.contains($0.pairing) }
            guard !removedLegs.isEmpty else { return nil }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: Set(removedLegs.map(\.pairing)).count,
                legCount: removedLegs.count,
                openTimeCount: schedule.openTimeCount,
                updatedAt: schedule.updatedAt,
                legs: removedLegs,
                openTimeTrips: []
            )
        }
        preservePastLogTenRecords(from: removedSchedules)

        crewAccessSchedules = rebuiltSchedules
        pruneCrewAccessLegImportReferenceTimes()
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        handleSchedulesChangedForSharing()
        let persistedLastSyncAt = lastSyncAt ?? Date()
        do {
            try cacheService.save(
                ScheduleCacheSnapshotV2(
                    crewAccessSchedules: crewAccessSchedules,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: persistedLastSyncAt,
                    migratedAt: nil
                )
            )
            if lastSyncAt == nil {
                lastSyncAt = persistedLastSyncAt
            }
        } catch {
            logNonFatal("Failed to save schedule cache after CrewAccess file reconciliation: \(error.localizedDescription)")
        }
        await rescheduleNotificationsIfAuthorized()
    }

    func deleteCrewAccessImportFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard !isDeletingCrewAccessTrips else { return }

        isDeletingCrewAccessTrips = true
        crewAccessDeleteMessage = nil
        defer { isDeletingCrewAccessTrips = false }

        logger.info("[CrewAccessFileDelete] start files=\(urls.count, privacy: .public)")
        let scheduleReferences = crewAccessSchedules.map {
            CrewAccessScheduleReference(
                id: $0.id,
                label: $0.label,
                pairings: Set($0.legs.map(\.pairing)),
                tripKeys: Self.crewAccessTripKeys(
                    for: $0,
                    domicile: verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
                )
            )
        }

        let deletionResults = await Task.detached(priority: .utility) {
            Self.deleteCrewAccessImportFilesAndCollectMatches(
                targetURLs: urls,
                scheduleReferences: scheduleReferences
            )
        }.value

        let scheduleIDsToRemove = Set(deletionResults.flatMap(\.matchedScheduleIDs))
        let beforePairings = Set(crewAccessSchedules.flatMap { $0.legs.map(\.pairing) })
        let schedulesBeforeDeletion = crewAccessSchedules
        if !scheduleIDsToRemove.isEmpty {
            crewAccessSchedules = crewAccessSchedules.compactMap { schedule in
                scheduleIDsToRemove.contains(schedule.id) ? nil : schedule
            }
        }
        let removedForLogTen = schedulesBeforeDeletion.compactMap { schedule -> PayPeriodSchedule? in
            let removedLegs = scheduleIDsToRemove.contains(schedule.id) ? schedule.legs : []
            guard !removedLegs.isEmpty else { return nil }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: Set(removedLegs.map(\.pairing)).count,
                legCount: removedLegs.count,
                openTimeCount: schedule.openTimeCount,
                updatedAt: schedule.updatedAt,
                legs: removedLegs,
                openTimeTrips: []
            )
        }
        preservePastLogTenRecords(from: removedForLogTen)
        let afterPairings = Set(crewAccessSchedules.flatMap { $0.legs.map(\.pairing) })
        let removedTripsCount = beforePairings.subtracting(afterPairings)
            .count
        pruneCrewAccessLegImportReferenceTimes()
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        handleSchedulesChangedForSharing()
        logger.info("[CrewAccessFileDelete] removedTrips=\(removedTripsCount, privacy: .public)")

        var cacheSaved = false
        do {
            let persistedLastSyncAt = lastSyncAt ?? Date()
            try cacheService.save(
                ScheduleCacheSnapshotV2(
                    crewAccessSchedules: crewAccessSchedules,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: persistedLastSyncAt,
                    migratedAt: nil
                )
            )
            if lastSyncAt == nil {
                lastSyncAt = persistedLastSyncAt
            }
            cacheSaved = true
            logger.info("[CrewAccessFileDelete] cacheSaved=true")
        } catch {
            logNonFatal("Failed to save schedule cache after CrewAccess file delete: \(error.localizedDescription)")
            logger.error("[CrewAccessFileDelete] cacheSaved=false error=\(error.localizedDescription, privacy: .public)")
        }
        await rescheduleNotificationsIfAuthorized()

        let deletedFileCount = deletionResults.filter(\.deleted).count
        let failedFileCount = deletionResults.count - deletedFileCount
        if removedTripsCount > 0 {
            crewAccessDeleteMessage = "Deleted \(deletedFileCount) file(s). Removed \(removedTripsCount) trip(s) from Timeline."
        } else {
            crewAccessDeleteMessage = "Deleted \(deletedFileCount) file(s). No matching trip was found in Timeline."
        }
        if failedFileCount > 0 {
            crewAccessDeleteMessage = (crewAccessDeleteMessage ?? "") + " Some files could not be removed."
        }
        if !cacheSaved {
            crewAccessDeleteMessage = (crewAccessDeleteMessage ?? "") + " Cache save failed."
        }

        // Tombstone deleted files in CloudKit so other devices remove them.
        let deletedFileNames = zip(urls, deletionResults)
            .filter { $0.1.deleted }
            .map { $0.0.lastPathComponent }
        if !deletedFileNames.isEmpty {
            Task { [weak self] in
                await self?.tombstoneCrewAccessImportFiles(fileNames: deletedFileNames)
            }
        }
    }

    func deleteCrewAccessImportFiles(fileIDs: [CrewAccessImportFile.ID]) async {
        guard !fileIDs.isEmpty else { return }
        let currentFiles = await listCrewAccessImportFiles()
        let urls = currentFiles
            .filter { fileIDs.contains($0.id) }
            .map(\.url)
        await deleteCrewAccessImportFiles(urls: urls)
    }

    func deleteCrewAccessTrips(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        guard !isDeletingCrewAccessTrips else { return }

        isDeletingCrewAccessTrips = true
        crewAccessDeleteMessage = nil
        defer { isDeletingCrewAccessTrips = false }
        logger.info("[CrewAccessDelete] start ids=\(ids.sorted().joined(separator: ","), privacy: .private)")

        let toDelete = crewAccessSchedules.filter { ids.contains($0.id) }
        guard !toDelete.isEmpty else {
            crewAccessDeleteMessage = "No matching CrewAccess trips were found."
            return
        }

        preservePastLogTenRecords(from: toDelete)
        crewAccessSchedules.removeAll { ids.contains($0.id) }
        pruneCrewAccessLegImportReferenceTimes()
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        handleSchedulesChangedForSharing()
        logger.info("[CrewAccessDelete] removedSchedules=\(toDelete.count, privacy: .public)")

        do {
            let persistedLastSyncAt = lastSyncAt ?? Date()
            try cacheService.save(
                ScheduleCacheSnapshotV2(
                    crewAccessSchedules: crewAccessSchedules,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: persistedLastSyncAt,
                    migratedAt: nil
                )
            )
            if lastSyncAt == nil {
                lastSyncAt = persistedLastSyncAt
            }
            logger.info("[CrewAccessDelete] cacheSaved=true")
        } catch {
            logNonFatal("Failed to save schedule cache after CrewAccess delete: \(error.localizedDescription)")
            logger.error("[CrewAccessDelete] cacheSaved=false error=\(error.localizedDescription, privacy: .public)")
        }

        let scheduleIDsToDelete = toDelete.map(\.id)
        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        let tripKeysToDelete = Array(Set(toDelete.flatMap { Self.crewAccessTripKeys(for: $0, domicile: domicile) }))
        if !tripKeysToDelete.isEmpty {
            deletedCrewAccessTripKeys.formUnion(tripKeysToDelete)
            saveDeletedCrewAccessTripKeys()
        }
        let fileDeleteResult = await Task.detached(priority: .utility) {
            Self.deleteCrewAccessImportFilesBestEffort(
                scheduleIDs: scheduleIDsToDelete,
                tripIDs: Array(Set(toDelete.flatMap { $0.legs.map(\.pairing) })),
                tripKeys: tripKeysToDelete
            )
        }.value
        logger.info("[CrewAccessDelete] detached file delete complete deleted=\(fileDeleteResult.deleted, privacy: .public) failures=\(fileDeleteResult.failures, privacy: .public)")
        if fileDeleteResult.failures == 0 {
            crewAccessDeleteMessage = "Deleted \(toDelete.count) trip(s)."
        } else {
            crewAccessDeleteMessage = "Deleted \(toDelete.count) trip(s). Some JSON files could not be removed."
        }
        let deletionTime = Date()
        lastDeviceScheduleFetchAt = deletionTime
        UserDefaults.standard.set(deletionTime, forKey: deviceScheduleFetchAtKey)
        if !fileDeleteResult.deletedFileNames.isEmpty {
            await tombstoneCrewAccessImportFiles(fileNames: fileDeleteResult.deletedFileNames)
        }
        await rescheduleNotificationsIfAuthorized()
        Task { [weak self] in await self?.uploadDeviceScheduleIfNeeded(reason: "trip deleted") }
    }

    func displaySchedules(filter: TimelineSourceFilter) -> [PayPeriodSchedule] {
        switch filter {
        case .crewAccess:
            return crewAccessSchedules
        case .tripBoard:
            return bidproSchedules
        }
    }

    func nextFlightCountdownOutput(nowUTC: Date = Date()) -> CountdownEngineOutput? {
        let countdownLegs = schedules.countdownLegs(tzResolver: tzResolver)
        return FlightCountdownEngine.buildCountdownOutput(from: countdownLegs, nowUTC: nowUTC)
    }

    func refreshFlightCountdownPresentation(nowUTC: Date = Date()) {
        let output = nextFlightCountdownOutput(nowUTC: nowUTC)
        Task { [weak self] in
            await self?.flightCountdownCoordinator.refresh(output: output, nowUTC: nowUTC)
        }
    }

    func exportCrewAccessFlightsLogTenCSV(nowUTC: Date = Date()) -> LogTenExportOutput? {
        logTenExportMessage = nil
        let candidates = logTenExportCandidates()
        let unexported = candidates.filter { candidate in
            logTenExportedFingerprints[candidate.key] != candidate.fingerprint
        }

        logger.info("[LogTenExport] start candidates=\(candidates.count, privacy: .public) unexported=\(unexported.count, privacy: .public)")

        guard !unexported.isEmpty else {
            logTenExportMessage = "No new CrewAccess flights to export."
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HH:mm"

        var csvRows: [(sortDate: Date, line: String)] = []
        var completedPastFingerprints: [String: String] = [:]
        var completedBacklogRecordIDs = Set<String>()
        for candidate in unexported {
            guard let stdDate = parseUTC(candidate.stdUTC) else { continue }
            let staDate = candidate.staUTC.flatMap { parseUTC($0) }
            let atdDate = candidate.atdUTC.flatMap { parseUTC($0) }
            let ataDate = candidate.ataUTC.flatMap { parseUTC($0) }
            let isPast = stdDate < nowUTC
            let dateSource = isPast ? (atdDate ?? stdDate) : stdDate
            let dateText = dateFormatter.string(from: dateSource)
            let stdText = timeFormatter.string(from: stdDate)
            let staText = staDate.map { timeFormatter.string(from: $0) } ?? ""
            let atdText = atdDate.map { timeFormatter.string(from: $0) } ?? ""
            let ataText = ataDate.map { timeFormatter.string(from: $0) } ?? ""
            let line = [
                Self.csvEscaped(dateText),
                Self.csvEscaped(candidate.flight),
                Self.csvEscaped(candidate.depAirport),
                Self.csvEscaped(candidate.arrAirport),
                Self.csvEscaped(stdText),
                Self.csvEscaped(staText),
                Self.csvEscaped(atdText),
                Self.csvEscaped(ataText)
            ].joined(separator: ",")
            csvRows.append((sortDate: dateSource, line: line))
            if isPast {
                completedPastFingerprints[candidate.key] = candidate.fingerprint
                if let backlogRecordID = candidate.backlogRecordID {
                    completedBacklogRecordIDs.insert(backlogRecordID)
                }
            }
        }

        csvRows.sort { $0.sortDate < $1.sortDate }

        guard !csvRows.isEmpty else {
            logTenExportMessage = "No exportable CrewAccess flights found."
            return nil
        }

        let csvHeader = "DATE,Flight Number,FROM,TO,STD,STA,ATD,ATA"
        var csvText = csvHeader + "\n"
        csvText += csvRows.map(\.line).joined(separator: "\n")
        csvText += "\n"

        guard let data = csvText.data(using: .utf8) else {
            logTenExportMessage = "Failed to encode LogTen CSV."
            return nil
        }

        let fileNameFormatter = DateFormatter()
        fileNameFormatter.calendar = Calendar(identifier: .gregorian)
        fileNameFormatter.locale = Locale(identifier: "en_US_POSIX")
        fileNameFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        fileNameFormatter.dateFormat = "yyyyMMdd_HHmm"
        let fileName = "TripDataHub_LogTen_\(fileNameFormatter.string(from: Date())).csv"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: outputURL, options: .atomic)
            logger.info("[LogTenExport] finished rows=\(csvRows.count, privacy: .public) bytes=\(data.count, privacy: .public)")
            logTenExportMessage = "LogTen CSV ready — \(csvRows.count) flights."
            return LogTenExportOutput(
                url: outputURL,
                rowCount: csvRows.count,
                exportedFingerprints: completedPastFingerprints,
                backlogRecordIDs: completedBacklogRecordIDs
            )
        } catch {
            logTenExportMessage = "Failed to write LogTen CSV: \(error.localizedDescription)"
            return nil
        }
    }

    func markLogTenExportCompleted(_ output: LogTenExportOutput) {
        for (key, fingerprint) in output.exportedFingerprints {
            logTenExportedFingerprints[key] = fingerprint
        }
        logTenExportBacklog.removeAll { output.backlogRecordIDs.contains($0.id) }
        saveLogTenExportState()
        logTenExportMessage = "Exported \(output.rowCount) flight(s). Past exported records were removed from the pending LogTen queue."
    }

    func importSeniorityCSVFromDocuments(named preferredFileName: String = "ups_sen.csv") async {
        let fm = FileManager.default
        guard let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            seniorityImportMessage = "Documents directory is unavailable."
            return
        }

        let preferredURL = documentsURL.appendingPathComponent(preferredFileName)
        if fm.fileExists(atPath: preferredURL.path) {
            do {
                let data = try Data(contentsOf: preferredURL)
                if await importSeniorityCSVData(data) {
                    seniorityImportMessage = "Uploaded GEMS verification records from Documents/\(preferredFileName)."
                }
            } catch {
                seniorityImportMessage = "Failed to read Documents/\(preferredFileName): \(error.localizedDescription)"
            }
            return
        }

        do {
            let urls = try fm.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if let firstCSV = urls.first(where: { $0.pathExtension.lowercased() == "csv" }) {
                let data = try Data(contentsOf: firstCSV)
                if await importSeniorityCSVData(data) {
                    seniorityImportMessage = "Uploaded GEMS verification records from Documents/\(firstCSV.lastPathComponent)."
                }
            } else {
                seniorityImportMessage = "No CSV found in Documents. Copy ups_sen.csv into the app Documents folder."
            }
        } catch {
            seniorityImportMessage = "Failed to scan Documents: \(error.localizedDescription)"
        }
    }

    private func mergeImportedCrewAccessSchedule(_ imported: PayPeriodSchedule) throws {
        var updatedCrewAccess = crewAccessSchedules
        let importConfirmedAt = Date()
        for leg in imported.legs {
            let key = Self.logTenLegDedupKey(for: leg)
            guard !key.hasPrefix("|") else { continue }
            crewAccessLegImportReferenceTimes[key] = importConfirmedAt
        }

        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        let importedTripKeys = Self.crewAccessTripKeys(for: imported, domicile: domicile)
        if !importedTripKeys.isEmpty {
            deletedCrewAccessTripKeys.subtract(importedTripKeys)
            saveDeletedCrewAccessTripKeys()
        }
        updatedCrewAccess = updatedCrewAccess.compactMap { schedule in
            let remainingLegs = schedule.legs.filter { leg in
                guard let key = Self.crewAccessTripKey(for: leg, domicile: domicile) else {
                    return true
                }
                return !importedTripKeys.contains(key)
            }
            guard !remainingLegs.isEmpty else { return nil }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: Set(remainingLegs.map(\.pairing)).count,
                legCount: remainingLegs.count,
                openTimeCount: schedule.openTimeCount,
                updatedAt: schedule.updatedAt,
                legs: remainingLegs,
                openTimeTrips: schedule.openTimeTrips
            )
        }

        let isReplacement = updatedCrewAccess.contains(where: { $0.id == imported.id })
        if let index = updatedCrewAccess.firstIndex(where: { $0.id == imported.id }) {
            let existing = updatedCrewAccess[index]
            // Deduplicate by flight-identity key (depUTC|flight|depAirport|arrAirport) before
            // merging so that re-importing the same PDF doesn't duplicate legs. Each import
            // generates fresh UUIDs, so UUID equality cannot detect the duplicate.
            var seenLegKeys = Set<String>()
            let mergedLegs = (imported.legs + existing.legs)
                .filter { seenLegKeys.insert(Self.logTenLegDedupKey(for: $0)).inserted }
                .sorted { lhs, rhs in
                    let lhsUTC = lhs.depUTC ?? ""
                    let rhsUTC = rhs.depUTC ?? ""
                    if lhsUTC == rhsUTC { return lhs.leg < rhs.leg }
                    return lhsUTC < rhsUTC
                }
            let mergedTripCount = Set(mergedLegs.map(\.pairing)).count
            updatedCrewAccess[index] = PayPeriodSchedule(
                id: existing.id,
                label: existing.label,
                tripCount: mergedTripCount,
                legCount: mergedLegs.count,
                openTimeCount: existing.openTimeCount,
                updatedAt: Date(),
                legs: mergedLegs,
                openTimeTrips: existing.openTimeTrips
            )
        } else {
            updatedCrewAccess.append(imported)
        }

        let updatedAll = mergeAndSortSchedules(crew: updatedCrewAccess, bidpro: bidproSchedules)
        let persistedLastSyncAt = lastSyncAt ?? Date()
        try cacheService.save(
            ScheduleCacheSnapshotV2(
                crewAccessSchedules: updatedCrewAccess,
                bidproSchedules: bidproSchedules,
                lastSyncAt: persistedLastSyncAt,
                migratedAt: nil
            )
        )
        crewAccessSchedules = updatedCrewAccess
        pruneCrewAccessLegImportReferenceTimes()
        schedules = updatedAll
        if lastSyncAt == nil {
            lastSyncAt = persistedLastSyncAt
        }
#if DEBUG
        logNonFatal("CrewAccess merge completed. replacement=\(isReplacement) scheduleId=\(imported.id)")
#endif
    }

    private func refreshScheduleTimezones(_ schedules: [PayPeriodSchedule]) -> [PayPeriodSchedule] {
        schedules.map { schedule in
            let updatedLegs = schedule.legs.map { leg in
                let depLocal = localDisplayFromUTCString(leg.depUTC, airport: leg.depAirport) ?? leg.depLocal
                let arrLocal = localDisplayFromUTCString(leg.arrUTC, airport: leg.arrAirport) ?? leg.arrLocal
                return TripLeg(
                    id: leg.id,
                    payPeriod: leg.payPeriod,
                    pairing: leg.pairing,
                    leg: leg.leg,
                    flight: leg.flight,
                    depAirport: leg.depAirport,
                    depLocal: depLocal,
                    arrAirport: leg.arrAirport,
                    arrLocal: arrLocal,
                    depUTC: leg.depUTC,
                    arrUTC: leg.arrUTC,
                    status: leg.status,
                    block: leg.block,
                    layoverStation: leg.layoverStation,
                    layoverHotelName: leg.layoverHotelName,
                    layoverDuration: leg.layoverDuration,
                    stdUTC: leg.stdUTC,
                    staUTC: leg.staUTC,
                    atdUTC: leg.atdUTC,
                    ataUTC: leg.ataUTC
                )
            }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: Set(updatedLegs.map(\.pairing)).count,
                legCount: updatedLegs.count,
                openTimeCount: schedule.openTimeCount,
                updatedAt: schedule.updatedAt,
                legs: updatedLegs,
                openTimeTrips: schedule.openTimeTrips
            )
        }
    }

    private func backfillMissingUTCInCachedSchedulesIfNeeded() {
        let crewResult = backfillMissingUTC(in: crewAccessSchedules)
        let bidproResult = backfillMissingUTC(in: bidproSchedules)
        let changedCount = crewResult.recoveredLegs + bidproResult.recoveredLegs
        guard changedCount > 0 else { return }

        crewAccessSchedules = crewResult.schedules
        bidproSchedules = bidproResult.schedules
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)

        do {
            let persistedLastSyncAt = lastSyncAt ?? Date()
            try cacheService.save(
                ScheduleCacheSnapshotV2(
                    crewAccessSchedules: crewAccessSchedules,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: persistedLastSyncAt,
                    migratedAt: nil
                )
            )
            if lastSyncAt == nil {
                lastSyncAt = persistedLastSyncAt
            }
            logNonFatal("UTC backfill recovered \(changedCount) leg(s) from cached schedules.")
        } catch {
            logNonFatal("Failed to persist cache after UTC backfill: \(error.localizedDescription)")
        }
    }

    private func backfillMissingUTC(in schedules: [PayPeriodSchedule]) -> (schedules: [PayPeriodSchedule], recoveredLegs: Int) {
        var recovered = 0
        let out = schedules.map { schedule in
            let isCrewAccessSchedule = schedule.id.uppercased().hasPrefix("CA")
            let updatedLegs = schedule.legs.map { leg in
                let depUTC = normalizedUTCValue(leg.depUTC)
                    ?? backfilledUTCString(fromDisplay: leg.depLocal, airport: leg.depAirport, preferUTCDisplay: isCrewAccessSchedule)
                let arrUTC = normalizedUTCValue(leg.arrUTC)
                    ?? backfilledUTCString(fromDisplay: leg.arrLocal, airport: leg.arrAirport, preferUTCDisplay: isCrewAccessSchedule)
                if normalizedUTCValue(leg.depUTC) == nil && depUTC != nil { recovered += 1 }
                if normalizedUTCValue(leg.arrUTC) == nil && arrUTC != nil { recovered += 1 }
                return TripLeg(
                    id: leg.id,
                    payPeriod: leg.payPeriod,
                    pairing: leg.pairing,
                    leg: leg.leg,
                    flight: leg.flight,
                    depAirport: leg.depAirport,
                    depLocal: leg.depLocal,
                    arrAirport: leg.arrAirport,
                    arrLocal: leg.arrLocal,
                    depUTC: depUTC,
                    arrUTC: arrUTC,
                    status: leg.status,
                    block: leg.block,
                    layoverStation: leg.layoverStation,
                    layoverHotelName: leg.layoverHotelName,
                    layoverDuration: leg.layoverDuration,
                    stdUTC: leg.stdUTC ?? depUTC,
                    staUTC: leg.staUTC ?? arrUTC,
                    atdUTC: leg.atdUTC,
                    ataUTC: leg.ataUTC
                )
            }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: schedule.tripCount,
                legCount: schedule.legCount,
                openTimeCount: schedule.openTimeCount,
                updatedAt: schedule.updatedAt,
                legs: updatedLegs,
                openTimeTrips: schedule.openTimeTrips
            )
        }
        return (out, recovered)
    }

    private func backfilledUTCString(fromDisplay display: String, airport: String, preferUTCDisplay: Bool) -> String? {
        if preferUTCDisplay {
            return utcStringFromUTCDisplay(display) ?? utcStringFromLocalDisplay(display, airport: airport)
        }
        return utcStringFromLocalDisplay(display, airport: airport) ?? utcStringFromUTCDisplay(display)
    }

    private func localDisplayFromUTCString(_ rawUTC: String?, airport: String) -> String? {
        guard let rawUTC = rawUTC?.trimmingCharacters(in: .whitespacesAndNewlines), !rawUTC.isEmpty else {
            return nil
        }
        let date = parseUTC(rawUTC)
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let tzID = tzResolver.resolve(airport), let tz = TimeZone(identifier: tzID) {
            formatter.timeZone = tz
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        }
        return formatter.string(from: date)
    }

    private func utcStringFromLocalDisplay(_ localText: String, airport: String) -> String? {
        let text = localText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let tzID = tzResolver.resolve(airport), let tz = TimeZone(identifier: tzID) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: text) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        return iso.string(from: date)
    }

    private func utcStringFromUTCDisplay(_ utcText: String) -> String? {
        let text = utcText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: text) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        return iso.string(from: date)
    }

    private func normalizedUTCValue(_ rawUTC: String?) -> String? {
        guard let raw = rawUTC?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard parseUTC(raw) != nil else { return nil }
        return raw
    }

    private func parseUTC(_ raw: String) -> Date? {
        LegConnectionTextBuilder.parseUTC(raw)
    }

    private struct LogTenExportCandidate {
        let key: String
        let backlogRecordID: String?
        let flight: String
        let depAirport: String
        let arrAirport: String
        let stdUTC: String
        let staUTC: String?
        let atdUTC: String?
        let ataUTC: String?

        var fingerprint: String {
            [
                flight,
                depAirport,
                arrAirport,
                stdUTC,
                staUTC ?? "",
                atdUTC ?? "",
                ataUTC ?? ""
            ].joined(separator: "|")
        }
    }

    private struct LogTenExportBacklogRecord: Codable, Hashable {
        let id: String
        let key: String
        let flight: String
        let depAirport: String
        let arrAirport: String
        let stdUTC: String
        let staUTC: String?
        let atdUTC: String?
        let ataUTC: String?
        let capturedAt: Date
    }

    private enum ExternalOpenError: Error {
        case fileReadFailed
    }

    private enum ExternalOpenReadTimeoutError: Error {
        case timedOut
    }

    /// Resets all import dedup state so the user can re-share the same PDF immediately
    /// after confirming or discarding. Awaits coordinator.reset() for guaranteed ordering.
    private func resetExternalOpenDedup() async {
        ExternalOpenLaunchGate.reset()
        await externalOpenCoordinator.reset()
        Self.clearPersistentImportFingerprint()
    }

    private func importPayloadFingerprint(data: Data, sourceFileName: String?) -> String {
        // Key ONLY on content (SHA-256 + byte count). Exclude sourceFileName because iOS can deliver
        // the same PDF via different paths with different lastPathComponents (e.g. "Unknown-1.pdf"
        // vs "Unknown-1 2.pdf" for Inbox copies), which would produce distinct fingerprints and
        // defeat the dedup guard even though the file bytes are identical.
        let digest = SHA256.hash(data: data)
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hashString)"
    }

    private nonisolated static func logTenLegDedupKey(for leg: TripLeg) -> String {
        "\(leg.depUTC ?? "")|\(leg.flight)|\(leg.depAirport)|\(leg.arrAirport)"
    }

    private func logTenExportCandidates() -> [LogTenExportCandidate] {
        var byKey: [String: LogTenExportCandidate] = [:]

        for record in logTenExportBacklog {
            byKey[record.key] = LogTenExportCandidate(
                key: record.key,
                backlogRecordID: record.id,
                flight: record.flight,
                depAirport: record.depAirport,
                arrAirport: record.arrAirport,
                stdUTC: record.stdUTC,
                staUTC: record.staUTC,
                atdUTC: record.atdUTC,
                ataUTC: record.ataUTC
            )
        }

        for schedule in crewAccessSchedules {
            for leg in schedule.legs {
                guard let candidate = logTenExportCandidate(from: leg, backlogRecordID: nil) else { continue }
                byKey[candidate.key] = candidate
            }
        }

        return Array(byKey.values)
    }

    private func logTenExportCandidate(from leg: TripLeg, backlogRecordID: String?) -> LogTenExportCandidate? {
        let stdUTC = normalizedUTCValue(leg.stdUTC) ?? normalizedUTCValue(leg.depUTC)
        guard let stdUTC else { return nil }
        let staUTC = normalizedUTCValue(leg.staUTC) ?? normalizedUTCValue(leg.arrUTC)
        let key = Self.logTenLegDedupKey(for: leg)
        guard !key.hasPrefix("|") else { return nil }
        return LogTenExportCandidate(
            key: key,
            backlogRecordID: backlogRecordID,
            flight: leg.flight,
            depAirport: leg.depAirport,
            arrAirport: leg.arrAirport,
            stdUTC: stdUTC,
            staUTC: staUTC,
            atdUTC: normalizedUTCValue(leg.atdUTC),
            ataUTC: normalizedUTCValue(leg.ataUTC)
        )
    }

    private func preservePastLogTenRecords(from schedules: [PayPeriodSchedule], nowUTC: Date = Date()) {
        let records = schedules.flatMap(\.legs).compactMap { leg -> LogTenExportBacklogRecord? in
            guard let candidate = logTenExportCandidate(from: leg, backlogRecordID: nil),
                  let stdDate = parseUTC(candidate.stdUTC),
                  stdDate < nowUTC else {
                return nil
            }
            return LogTenExportBacklogRecord(
                id: candidate.key,
                key: candidate.key,
                flight: candidate.flight,
                depAirport: candidate.depAirport,
                arrAirport: candidate.arrAirport,
                stdUTC: candidate.stdUTC,
                staUTC: candidate.staUTC,
                atdUTC: candidate.atdUTC,
                ataUTC: candidate.ataUTC,
                capturedAt: nowUTC
            )
        }
        guard !records.isEmpty else { return }
        var byKey: [String: LogTenExportBacklogRecord] = [:]
        for existing in logTenExportBacklog {
            byKey[existing.key] = existing
        }
        for record in records {
            byKey[record.key] = record
        }
        logTenExportBacklog = byKey.values.sorted { $0.stdUTC < $1.stdUTC }
        saveLogTenExportState()
    }

    private nonisolated static func loadLogTenExportBacklog(
        from defaults: UserDefaults,
        key: String
    ) -> [LogTenExportBacklogRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([LogTenExportBacklogRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func saveLogTenExportState() {
        if let data = try? JSONEncoder().encode(logTenExportBacklog) {
            UserDefaults.standard.set(data, forKey: logTenExportBacklogKey)
        }
        UserDefaults.standard.set(logTenExportedFingerprints, forKey: logTenExportedFingerprintsKey)
    }

    private func pruneCrewAccessLegImportReferenceTimes() {
        let activeKeys = Set(crewAccessSchedules.flatMap { schedule in
            schedule.legs.map(Self.logTenLegDedupKey(for:))
        })
        crewAccessLegImportReferenceTimes = crewAccessLegImportReferenceTimes.filter { activeKeys.contains($0.key) }
        Self.saveCrewAccessLegImportReferenceTimes(
            crewAccessLegImportReferenceTimes,
            to: UserDefaults.standard,
            key: crewAccessLegImportReferenceTimesKey
        )
    }

    private func backfillCrewAccessLegImportReferenceTimesIfNeeded() {
        var didBackfill = false
        for schedule in crewAccessSchedules {
            for leg in schedule.legs {
                let key = Self.logTenLegDedupKey(for: leg)
                guard !key.hasPrefix("|") else { continue }
                if crewAccessLegImportReferenceTimes[key] == nil {
                    crewAccessLegImportReferenceTimes[key] = schedule.updatedAt
                    didBackfill = true
                }
            }
        }
        if didBackfill {
            Self.saveCrewAccessLegImportReferenceTimes(
                crewAccessLegImportReferenceTimes,
                to: UserDefaults.standard,
                key: crewAccessLegImportReferenceTimesKey
            )
        }
    }

    private nonisolated static func loadCrewAccessLegImportReferenceTimes(
        from defaults: UserDefaults,
        key: String
    ) -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var out: [String: Date] = [:]
        for (mapKey, value) in raw {
            if let epoch = value as? Double {
                out[mapKey] = Date(timeIntervalSince1970: epoch)
            } else if let date = value as? Date {
                out[mapKey] = date
            }
        }
        return out
    }

    private nonisolated static func saveCrewAccessLegImportReferenceTimes(
        _ map: [String: Date],
        to defaults: UserDefaults,
        key: String
    ) {
        let payload = map.mapValues(\.timeIntervalSince1970)
        defaults.set(payload, forKey: key)
    }

    private nonisolated static func csvEscaped(_ value: String, alwaysQuote: Bool = false) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        let shouldQuote = alwaysQuote || escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n")
        return shouldQuote ? "\"\(escaped)\"" : escaped
    }

    /// Claims a cross-launch fingerprint in UserDefaults. Returns false if the same content
    /// was already imported in this launch or a recent previous launch (TTL 30s).
    /// `importInProgress` handles same-launch re-entrancy; this handles app-restart edge cases.
    ///
    /// NSLock safety: although callers run on @MainActor, this is a synchronous (non-async)
    /// method with no suspension points inside the lock, so there is no risk of deadlock
    /// or actor re-entrancy while the lock is held.
    private static func claimPersistentFingerprint(_ fingerprint: String) -> Bool {
        importMethodDedupLock.lock()
        defer { importMethodDedupLock.unlock() }
        let now = Date()
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: persistentFingerprintKey),
           stored == fingerprint,
           let ts = defaults.object(forKey: persistentFingerprintTSKey) as? Date,
           now.timeIntervalSince(ts) < persistentFingerprintTTL {
            return false
        }
        defaults.set(fingerprint, forKey: persistentFingerprintKey)
        defaults.set(now, forKey: persistentFingerprintTSKey)
        return true
    }

    private static func clearPersistentImportFingerprint() {
        importMethodDedupLock.lock()
        defer { importMethodDedupLock.unlock() }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: persistentFingerprintKey)
        defaults.removeObject(forKey: persistentFingerprintTSKey)
    }

    private nonisolated static func readExternalPDFDataDirect(from originalURL: URL) throws -> Data {
        let data = try Data(contentsOf: originalURL, options: [.mappedIfSafe])
        logger.info("[Import] consume read method=direct success bytes=\(data.count, privacy: .public)")
        return data
    }

    private nonisolated static func readExternalPDFDataCoordinated(from originalURL: URL) throws -> Data {
        let didStartScopedAccess = originalURL.startAccessingSecurityScopedResource()
        defer {
            if didStartScopedAccess {
                originalURL.stopAccessingSecurityScopedResource()
            }
        }

        var coordinatorError: NSError?
        var readData: Data?
        var readError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: originalURL, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                let data = try Data(contentsOf: coordinatedURL)
                readData = data
                logger.info("[Import] coordinated read success bytes=\(data.count, privacy: .public)")
            } catch {
                readError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let readError {
            throw readError
        }
        guard let readData else {
            throw ExternalOpenError.fileReadFailed
        }
        return readData
    }

    private nonisolated static func readExternalPDFDataWithFallback(
        from originalURL: URL,
        timeoutSeconds: UInt64
    ) async throws -> Data {
        do {
            return try readExternalPDFDataDirect(from: originalURL)
        } catch {
            do {
                let data = try await readExternalPDFDataCoordinatedWithTimeout(
                    from: originalURL,
                    timeoutSeconds: timeoutSeconds
                )
                logger.info("[Import] consume read method=coordinator success bytes=\(data.count, privacy: .public)")
                return data
            } catch ExternalOpenReadTimeoutError.timedOut {
                logger.info("[Import] consume read method=coordinator timeout")
                throw ExternalOpenReadTimeoutError.timedOut
            } catch {
                throw error
            }
        }
    }

    private nonisolated static func readExternalPDFDataCoordinatedWithTimeout(
        from originalURL: URL,
        timeoutSeconds: UInt64
    ) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try Self.readExternalPDFDataCoordinated(from: originalURL)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw ExternalOpenReadTimeoutError.timedOut
            }
            let first = try await group.next() ?? Data()
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func sniffPDFSignature(in data: Data) -> (isPDF: Bool, header: String) {
        let prefix = data.prefix(8)
        let ascii = String(decoding: prefix, as: UTF8.self)
        let sanitizedASCII = ascii.unicodeScalars
            .map { scalar in
                let value = scalar.value
                let isPrintableASCII = scalar.isASCII && value >= 32 && value <= 126
                return isPrintableASCII ? String(scalar) : "."
            }
            .joined()
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let header = "\(sanitizedASCII) [\(hex)]"
        let isPDF = data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) // %PDF-
        return (isPDF, header)
    }

    private func cleanupImportedExternalFileBestEffort(at url: URL) {
        let normalizedPath = url.standardizedFileURL.path
        let inboxPathToken = "/Documents/Inbox/"
        if normalizedPath.contains(inboxPathToken) {
            logger.info("[Import] cleanupInbox start path=\(normalizedPath, privacy: .private)")
            do {
                try FileManager.default.removeItem(at: url)
                logger.info("[Import] cleanupInbox deleted path=\(normalizedPath, privacy: .private)")
            } catch {
                logger.error("[Import] cleanupInbox failed path=\(normalizedPath, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if let appGroupDir = Self.appGroupImportDirectoryURL()?.standardizedFileURL.path,
           normalizedPath.hasPrefix(appGroupDir + "/") || normalizedPath == appGroupDir {
            logger.info("[Import] cleanupAppGroup start path=\(normalizedPath, privacy: .private)")
            do {
                try FileManager.default.removeItem(at: url)
                logger.info("[Import] cleanupAppGroup deleted path=\(normalizedPath, privacy: .private)")
            } catch {
                logger.error("[Import] cleanupAppGroup failed path=\(normalizedPath, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            }
            return
        }

        logger.info("[Import] cleanupExternalFile skip (not managed path) url=\(url.absoluteString, privacy: .private)")
    }

    private struct AppGroupPendingImportHandoff: Codable {
        let fileName: String
        let createdAtISO8601: String?
    }

    private struct AppGroupPendingImportReference {
        let fileName: String
        let fileURL: URL
    }

    private nonisolated static func appGroupImportDirectoryURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupImportConfig.appGroupIdentifier) else {
            return nil
        }
        return container.appendingPathComponent(AppGroupImportConfig.importDirectoryName, isDirectory: true)
    }

    private nonisolated static func readPendingAppGroupHandoff() -> AppGroupPendingImportReference? {
        guard let directoryURL = appGroupImportDirectoryURL() else { return nil }
        let handoffURL = directoryURL.appendingPathComponent(AppGroupImportConfig.pendingHandoffFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: handoffURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: handoffURL)
            let handoff = try JSONDecoder().decode(AppGroupPendingImportHandoff.self, from: data)
            let fileURL = directoryURL.appendingPathComponent(handoff.fileName, isDirectory: false)
            return AppGroupPendingImportReference(fileName: handoff.fileName, fileURL: fileURL)
        } catch {
            logger.error("[Import] appGroup handoff decode failed error=\(error.localizedDescription, privacy: .public)")
            removePendingAppGroupHandoffBestEffort()
            return nil
        }
    }

    private nonisolated static func removePendingAppGroupHandoffBestEffort() {
        guard let directoryURL = appGroupImportDirectoryURL() else { return }
        let handoffURL = directoryURL.appendingPathComponent(AppGroupImportConfig.pendingHandoffFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: handoffURL.path) else { return }
        try? FileManager.default.removeItem(at: handoffURL)
    }

    private nonisolated static func readCrewAccessTripHeader(from url: URL) -> CrewAccessTripHeader? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrewAccessTripHeader.self, from: data)
    }

    private nonisolated static func migrateCrewAccessRetentionDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "crewaccess_trip_data_retained_default_all_migrated_v1"
        let selectionKey = "crewaccess_trip_data_retained_v1"
        let defaultSelection = "ALL"
        if defaults.bool(forKey: migrationKey) {
            return
        }
        defaults.set(defaultSelection, forKey: selectionKey)
        defaults.set(true, forKey: migrationKey)
    }

    private func retainedCrewAccessBidPeriodOrders() -> Set<Int>? {
        guard let previousCount = crewAccessRetentionPreviousBidPeriods() else {
            return nil
        }
        return retainedBidPeriodOrders(
            currentDateUTC: Date(),
            previousCount: previousCount,
            domicile: verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        )
    }

    private func crewAccessRetentionPreviousBidPeriods() -> Int? {
        let raw = UserDefaults.standard.string(forKey: Self.crewAccessRetentionSelectionKey)
            ?? Self.defaultCrewAccessRetentionSelection
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ALL" {
            return nil
        }
        return min(max(Int(raw) ?? 1, 1), 7)
    }

    private func crewAccessBidPeriodOrder(for schedule: PayPeriodSchedule) -> Int? {
        parseCrewAccessBidPeriodOrder(schedule.id)
            ?? parseCrewAccessBidPeriodOrder(schedule.label)
            ?? schedule.legs.compactMap { leg in
                if let depUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
                   let period = bidPeriod(
                    for: depUTC,
                    domicile: verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
                   ) {
                    return bidPeriodOrder(for: period.id)
                }
                let normalized = Self.normalizeTripInformationDateForDisplay(leg.depLocal, fallbackDate: nil).dateString
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                guard let date = formatter.date(from: normalized),
                      let period = bidPeriod(
                        for: date,
                        domicile: verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
                      ) else {
                    return nil
                }
                return bidPeriodOrder(for: period.id)
            }.first
    }

    private func parseCrewAccessBidPeriodOrder(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = cleaned.range(of: #"(?:CA|BP)(\d{2})-(\d{2})"#, options: .regularExpression)
        guard let range else { return nil }
        let match = String(cleaned[range])
            .replacingOccurrences(of: "CA", with: "")
            .replacingOccurrences(of: "BP", with: "")
        let parts = match.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let period = Int(parts[1]) else {
            return nil
        }
        return year * 100 + period
    }

    private nonisolated static func crewAccessBidPeriodOrder(tripInformationDate: String?, fallbackDate: Date?) -> Int? {
        let normalized = normalizeTripInformationDateForDisplay(tripInformationDate, fallbackDate: fallbackDate).dateString
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: normalized),
              let period = bidPeriod(for: date) else {
            return nil
        }
        return bidPeriodOrder(for: period.id)
    }

    private nonisolated static func normalizedCrewAccessTripID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private nonisolated static func crewAccessTripKey(
        tripID: String,
        startUTC: Date?,
        endUTC: Date?,
        domicile: String
    ) -> String? {
        let normalizedTripID = normalizedCrewAccessTripID(tripID)
        guard !normalizedTripID.isEmpty else { return nil }
        let referenceDate = startUTC ?? endUTC
        guard let referenceDate,
              let period = bidPeriod(for: referenceDate, domicile: domicile),
              let order = bidPeriodOrder(for: period.id) else {
            return nil
        }
        return "\(order):\(normalizedTripID)"
    }

    private nonisolated static func crewAccessTripKey(
        tripID: String,
        tripInformationDate: String?,
        fallbackDate: Date?
    ) -> String? {
        let normalizedTripID = normalizedCrewAccessTripID(tripID)
        guard !normalizedTripID.isEmpty,
              let order = crewAccessBidPeriodOrder(
                tripInformationDate: tripInformationDate,
                fallbackDate: fallbackDate
              ) else {
            return nil
        }
        return "\(order):\(normalizedTripID)"
    }

    private nonisolated static func crewAccessTripKey(fromCloudKitRecord record: CrewAccessImportCloudKitRecord) -> String? {
        guard let payload = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: record.jsonData) else {
            return nil
        }
        let payloadTripInformationDate = payload.tripInformationDate.trimmingCharacters(in: .whitespacesAndNewlines)
        return crewAccessTripKey(
            tripID: payload.tripId,
            tripInformationDate: payloadTripInformationDate.isEmpty ? record.tripInformationDate : payloadTripInformationDate,
            fallbackDate: record.firstDepartureUTC.flatMap { LegConnectionTextBuilder.parseUTC($0) }
        )
    }

    private nonisolated static func crewAccessTripKey(for leg: TripLeg, domicile: String) -> String? {
        crewAccessTripKey(
            tripID: leg.pairing,
            startUTC: LegConnectionTextBuilder.parseUTC(leg.depUTC),
            endUTC: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
            domicile: domicile
        )
    }

    private nonisolated static func crewAccessTripKeys(
        for schedule: PayPeriodSchedule,
        domicile: String
    ) -> Set<String> {
        Set(schedule.legs.compactMap { crewAccessTripKey(for: $0, domicile: domicile) })
    }

    private nonisolated static func deleteCrewAccessImportFilesOutsideRetainedBidPeriods(retainedOrders: Set<Int>) -> Int {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return 0
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var deletedCount = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "json" else {
                continue
            }
            let header = readCrewAccessTripHeader(from: url)
            guard let order = crewAccessBidPeriodOrder(
                tripInformationDate: header?.tripInformationDate,
                fallbackDate: values.contentModificationDate
            ) else {
                continue
            }
            guard !retainedOrders.contains(order) else {
                continue
            }
            do {
                try fm.removeItem(at: url)
                deletedCount += 1
            } catch {
                logger.error("[CrewAccessRetention] failedFileDelete=\(url.path, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return deletedCount
    }

    private nonisolated static func loadCrewAccessSchedulesFromImportFiles() -> [PayPeriodSchedule] {
        let payloads = loadCrewAccessTripJSONPayloadsFromImportFilesSync()
        return payloads.compactMap { payload, modifiedAt in
            buildCrewAccessSchedule(from: payload, modifiedAt: modifiedAt)
        }.sorted { lhs, rhs in
            let lhsKey = lhs.legs.compactMap(\.depUTC).sorted().first ?? lhs.label
            let rhsKey = rhs.legs.compactMap(\.depUTC).sorted().first ?? rhs.label
            if lhsKey == rhsKey {
                return lhs.label < rhs.label
            }
            return lhsKey < rhsKey
        }
    }

    private nonisolated static func loadCrewAccessTripJSONPayloadsFromImportFiles() async -> [CrewAccessTripJSON] {
        await Task.detached(priority: .utility) {
            loadCrewAccessTripJSONPayloadsFromImportFilesSync().map(\.payload)
        }.value
    }

    private nonisolated static func loadCrewAccessTripJSONPayloadsFromImportFilesSync() -> [(payload: CrewAccessTripJSON, modifiedAt: Date)] {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: data)
            else {
                return nil
            }
            return (payload, values.contentModificationDate ?? Date())
        }.sorted { lhs, rhs in
            let lhsKey = lhs.payload.items.map(\.startUtc).sorted().first ?? lhs.payload.tripInformationDate
            let rhsKey = rhs.payload.items.map(\.startUtc).sorted().first ?? rhs.payload.tripInformationDate
            if lhsKey == rhsKey {
                return lhs.payload.tripId < rhs.payload.tripId
            }
            return lhsKey < rhsKey
        }
    }

    // MARK: - Hotel name enrichment for CloudKit upload

    /// Enriches schedules with hotel names from local CrewAccess JSON files before
    /// uploading to CloudKit. The local model is NOT mutated — only the upload payload
    /// gets hotel names filled in, so friends see hotel names without requiring re-import.
    private nonisolated static func enrichSchedulesWithHotelNames(
        _ schedules: [PayPeriodSchedule]
    ) -> [PayPeriodSchedule] {
        let hotelMap = hotelMapFromCrewAccessImports()
        guard !hotelMap.isEmpty else { return schedules }
        return schedules.map { schedule in
            let enrichedLegs = schedule.legs.map { leg -> TripLeg in
                guard leg.layoverHotelName == nil else { return leg }
                let station = leg.layoverStation ?? leg.arrAirport
                guard let name = hotelMap[leg.pairing]?[station], !name.isEmpty else { return leg }
                return leg.withHotelName(name)
            }
            guard enrichedLegs != schedule.legs else { return schedule }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: schedule.tripCount,
                legCount: schedule.legCount,
                openTimeCount: schedule.openTimeCount,
                updatedAt: schedule.updatedAt,
                legs: enrichedLegs,
                openTimeTrips: schedule.openTimeTrips
            )
        }
    }

    /// Builds a [tripID: [station: hotelName]] map from local CrewAccess JSON files.
    /// Handles both modern ("AAA: Hotel Name ...") and legacy ("Hotel details ...") formats.
    private nonisolated static func hotelMapFromCrewAccessImports() -> [String: [String: String]] {
        let payloads = loadCrewAccessTripJSONPayloadsFromImportFilesSync()
        var result: [String: [String: String]] = [:]
        for (payload, _) in payloads {
            // Normalize tripId the same way buildCrewAccessSchedule does,
            // so it matches leg.pairing exactly.
            let tripID = payload.tripId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !tripID.isEmpty else { continue }

            var stationToHotel: [String: String] = [:]

            // Modern format: "AAA: Hotel Name ..."
            let modernDetails = payload.hotelDetails.filter { !$0.hasPrefix("Hotel details ") }
            for detail in modernDetails {
                let (station, hotelName) = parseHotelDetailForEnrichment(detail)
                if !station.isEmpty && !hotelName.isEmpty {
                    stationToHotel[station] = hotelName
                }
            }

            // Legacy format: "Hotel details ... Hotel: Name Hotel Transport: ..."
            // Station is unknown from the string itself; infer from sequence gaps >= 3h.
            let legacyDetails = payload.hotelDetails.filter { $0.hasPrefix("Hotel details ") }
            if !legacyDetails.isEmpty {
                let sortedItems = payload.items.sorted { $0.sequence < $1.sequence }
                var legacyIndex = 0
                let isoParser = ISO8601DateFormatter()
                for idx in sortedItems.indices.dropLast() {
                    guard legacyIndex < legacyDetails.count else { break }
                    let current = sortedItems[idx]
                    let next = sortedItems[idx + 1]
                    guard let endDate = isoParser.date(from: current.endUtc),
                          let nextStart = isoParser.date(from: next.startUtc),
                          nextStart.timeIntervalSince(endDate) >= 180 * 60 else { continue }
                    let station = current.arrAirport.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !station.isEmpty, stationToHotel[station] == nil else {
                        legacyIndex += 1
                        continue
                    }
                    let (_, hotelName) = parseLegacyHotelDetailForEnrichment(legacyDetails[legacyIndex])
                    if !hotelName.isEmpty { stationToHotel[station] = hotelName }
                    legacyIndex += 1
                }
            }

            if !stationToHotel.isEmpty {
                result[tripID] = stationToHotel
            }
        }
        return result
    }

    /// Parses a modern hotel detail string: "AAA: Hotel Name ..."
    private nonisolated static func parseHotelDetailForEnrichment(
        _ detail: String
    ) -> (station: String, hotelName: String) {
        guard !detail.hasPrefix("Hotel details ") else { return ("", "") }
        guard let colonRange = detail.range(of: ": ") else { return ("", "") }
        let station = String(detail[..<colonRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        // Station must be a 3-letter uppercase IATA code
        guard station.count == 3, station.allSatisfy({ $0.isLetter }) else {
            return ("", "")
        }
        var rest = String(detail[colonRange.upperBound...])
        // Strip trailing "(HH:MM)" pickup time
        if let parenRange = rest.range(of: " (", options: .backwards) {
            rest = String(rest[..<parenRange.lowerBound])
        }
        // Stop at phone number (+... or three-or-more-dash pattern)
        let words = rest.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        let hotelName = hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (station, hotelName)
    }

    /// Parses a legacy hotel detail string: "Hotel details ... Hotel: Name Hotel Transport: ..."
    /// Returns ("", hotelName) — station is unknown and must be inferred by the caller.
    private nonisolated static func parseLegacyHotelDetailForEnrichment(
        _ detail: String
    ) -> (station: String, hotelName: String) {
        guard let hotelRange = detail.range(of: "Hotel: ") else { return ("", "") }
        var rest = String(detail[hotelRange.upperBound...])
        if let transportRange = rest.range(of: " Hotel Transport:") {
            rest = String(rest[..<transportRange.lowerBound])
        }
        let cleaned = rest
            .replacingOccurrences(of: " UPS Only", with: "")
            .replacingOccurrences(of: "UPS Only ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let digitCount = word.filter(\.isNumber).count
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || digitCount >= 3 || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return ("", hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    private nonisolated static func buildCrewAccessSchedule(from payload: CrewAccessTripJSON, modifiedAt: Date) -> PayPeriodSchedule? {
        let normalizedDate = normalizeTripInformationDateForDisplay(payload.tripInformationDate, fallbackDate: modifiedAt).dateString
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let tripDate = formatter.date(from: normalizedDate) else {
            return nil
        }

        let tripID = payload.tripId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let year = Calendar(identifier: .gregorian).component(.year, from: tripDate) % 100
        let month = Calendar(identifier: .gregorian).component(.month, from: tripDate)
        let label = String(format: "CA%02d-%02d-%@", year, month, tripID)

        let legs = payload.items.map { item in
            TripLeg(
                payPeriod: label,
                pairing: tripID,
                leg: item.sequence,
                flight: item.flight,
                depAirport: item.depAirport,
                depLocal: item.startLocalDisplay,
                arrAirport: item.arrAirport,
                arrLocal: item.endLocalDisplay,
                depUTC: item.startUtc,
                arrUTC: item.endUtc,
                status: item.deadhead ? "DH" : "-",
                block: item.block,
                stdUTC: item.stdUtc ?? item.startUtc,
                staUTC: item.staUtc ?? item.endUtc,
                atdUTC: item.atdUtc,
                ataUTC: item.ataUtc
            )
        }.sorted { lhs, rhs in
            if lhs.leg == rhs.leg {
                return (lhs.depUTC ?? lhs.depLocal) < (rhs.depUTC ?? rhs.depLocal)
            }
            return lhs.leg < rhs.leg
        }

        guard !legs.isEmpty else { return nil }

        return PayPeriodSchedule(
            id: label,
            label: label,
            tripCount: Set(legs.map(\.pairing)).count,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: modifiedAt,
            legs: legs,
            openTimeTrips: []
        )
    }

    private nonisolated static func inferTripIdFromFileName(_ fileName: String) -> String {
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        if let match = base.range(of: #"^\d{4}-\d{2}-\d{2}_.+"#, options: .regularExpression),
           match.lowerBound == base.startIndex,
           let underscore = base.firstIndex(of: "_") {
            let suffix = String(base[base.index(after: underscore)...])
            return suffix.isEmpty ? base : suffix
        }
        if let underscore = base.firstIndex(of: "_") {
            let prefix = String(base[..<underscore])
            return prefix.isEmpty ? base : prefix
        }
        return base
    }

    private nonisolated static func normalizeTripInformationDateForDisplay(
        _ raw: String?,
        fallbackDate: Date?
    ) -> (dateString: String, usedFallback: Bool) {
        if let raw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = trimmed.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                return (String(trimmed[match]), false)
            }

            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: trimmed) {
                return (Self.crewAccessDateString(from: date), false)
            }

            let ymdFormatter = DateFormatter()
            ymdFormatter.locale = Locale(identifier: "en_US_POSIX")
            ymdFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            ymdFormatter.dateFormat = "yyyyMMdd"
            if let date = ymdFormatter.date(from: trimmed) {
                return (Self.crewAccessDateString(from: date), false)
            }

            let crewFormatter = DateFormatter()
            crewFormatter.locale = Locale(identifier: "en_US_POSIX")
            crewFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            crewFormatter.dateFormat = "ddMMMyyyy"
            if let date = crewFormatter.date(from: trimmed.uppercased()) {
                return (Self.crewAccessDateString(from: date), false)
            }

            let mdyFormatter = DateFormatter()
            mdyFormatter.locale = Locale(identifier: "en_US_POSIX")
            mdyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            mdyFormatter.dateFormat = "MM/dd/yyyy"
            if let date = mdyFormatter.date(from: trimmed) {
                return (Self.crewAccessDateString(from: date), false)
            }
        }

        if let fallbackDate {
            return (Self.crewAccessDateString(from: fallbackDate), true)
        }
        return ("UnknownDate", true)
    }

    private nonisolated static func crewAccessDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private nonisolated static func matchScheduleID(
        tripId: String,
        tripInformationDate: String?,
        scheduleReferences: [CrewAccessScheduleReference]
    ) -> String? {
        if let key = crewAccessTripKey(
            tripID: tripId,
            tripInformationDate: tripInformationDate,
            fallbackDate: nil
        ),
           let matched = scheduleReferences.first(where: { $0.tripKeys.contains(key) }) {
            return matched.id
        }
        return scheduleReferences.first { ref in
            ref.id == tripId || ref.label.contains(tripId) || ref.pairings.contains(tripId)
        }?.id
    }

    private nonisolated static func deleteCrewAccessImportFilesAndCollectMatches(
        targetURLs: [URL],
        scheduleReferences: [CrewAccessScheduleReference]
    ) -> [CrewAccessFileDeletionResult] {
        let fm = FileManager.default
        return targetURLs.map { url in
            let fileName = url.lastPathComponent
            let header: CrewAccessTripHeader?
            let decodeErrorMessage: String?
            do {
                let data = try Data(contentsOf: url)
                header = try JSONDecoder().decode(CrewAccessTripHeader.self, from: data)
                decodeErrorMessage = nil
            } catch {
                header = nil
                decodeErrorMessage = error.localizedDescription
            }
            let tripIdRaw = header?.tripId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tripId = tripIdRaw.isEmpty ? nil : tripIdRaw
            let tripDate = header?.tripInformationDate
            if let tripId {
                logger.info("[CrewAccessFileDelete] decoded tripId=\(tripId, privacy: .private) infoDate=\(tripDate ?? "nil", privacy: .public)")
            } else {
                logger.info("[CrewAccessFileDelete] decodeFailed file=\(fileName, privacy: .private) error=\(decodeErrorMessage ?? "missing tripId/tripInformationDate", privacy: .public)")
            }

            let matchedIDs: [String]
            if let tripId,
               let key = crewAccessTripKey(
                tripID: tripId,
                tripInformationDate: tripDate,
                fallbackDate: nil
               ) {
                matchedIDs = scheduleReferences
                    .filter { $0.tripKeys.contains(key) }
                    .map(\.id)
            } else {
                matchedIDs = []
            }

            do {
                try fm.removeItem(at: url)
                logger.info("[CrewAccessFileDelete] deletedFile=\(url.path, privacy: .private)")
                return CrewAccessFileDeletionResult(
                    deleted: true,
                    tripId: tripId,
                    tripInformationDate: tripDate,
                    matchedScheduleIDs: matchedIDs
                )
            } catch {
                logger.error("[CrewAccessFileDelete] failedFileDelete=\(url.path, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
                return CrewAccessFileDeletionResult(
                    deleted: false,
                    tripId: tripId,
                    tripInformationDate: tripDate,
                    matchedScheduleIDs: matchedIDs
                )
            }
        }
    }

    private nonisolated static func deleteCrewAccessImportFilesBestEffort(
        scheduleIDs: [String],
        tripIDs: [String] = [],
        tripKeys: [String]
    ) -> (deleted: Int, failures: Int, deletedFileNames: [String]) {
        struct ImportFileHeader {
            let url: URL
            let name: String
            let tripID: String?
            let tripKey: String?
        }

        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return (0, 0, [])
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else {
            return (0, 0, [])
        }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return (0, 0, [])
        }

        let tripKeySet = Set(tripKeys)
        let tripIDSet = Set(tripIDs.map(normalizedCrewAccessTripID))
        let files = urls.compactMap { url -> ImportFileHeader? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            let headerTripKey: String?
            if let data = try? Data(contentsOf: url),
               let header = try? JSONDecoder().decode(CrewAccessTripHeader.self, from: data),
               let payloadTripID = header.tripId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !payloadTripID.isEmpty {
                headerTripKey = crewAccessTripKey(
                    tripID: payloadTripID,
                    tripInformationDate: header.tripInformationDate,
                    fallbackDate: nil
                )
                return ImportFileHeader(url: url, name: url.lastPathComponent, tripID: payloadTripID, tripKey: headerTripKey)
            } else {
                headerTripKey = nil
            }
            return ImportFileHeader(url: url, name: url.lastPathComponent, tripID: nil, tripKey: headerTripKey)
        }

        var deletedCount = 0
        var failedCount = 0
        var deletedFileNames: [String] = []
        for file in files {
            let name = file.name
            let matchesScheduleID = scheduleIDs.contains { scheduleID in
                let safeID = scheduleID.replacingOccurrences(of: "/", with: "-")
                return name.hasPrefix("\(safeID)_") || name.contains(scheduleID) || name.contains(safeID)
            }
            let matchesPayloadTripID = file.tripID.map { tripID in
                let normalizedTripID = normalizedCrewAccessTripID(tripID)
                return tripIDSet.contains(normalizedTripID) || scheduleIDs.contains { scheduleID in
                    scheduleID == tripID || scheduleID.contains(tripID)
                }
            } ?? false
            let matchesPayloadTripKey = file.tripKey.map { tripKeySet.contains($0) } ?? false
            let shouldDelete = matchesScheduleID || matchesPayloadTripID || matchesPayloadTripKey
            guard shouldDelete else { continue }

            do {
                try fm.removeItem(at: file.url)
                deletedCount += 1
                deletedFileNames.append(name)
                logger.info("[CrewAccessDelete] deletedFile=\(file.url.path, privacy: .private)")
            } catch {
                failedCount += 1
                logger.error("[CrewAccessDelete] failedFileDelete=\(file.url.path, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return (deletedCount, failedCount, deletedFileNames)
    }

    private struct CrewAccessJSONWriteContext {
        let finalURL: URL
        let backupURL: URL?
        let createdNewFile: Bool
        let staleSameBidPeriodTripURLs: [URL]
    }

    private func persistCrewAccessJSON(_ payload: CrewAccessTripJSON) throws -> CrewAccessJSONWriteContext {
        let data = try JSONEncoder().encode(payload)
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "CrewAccessImport",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Documents directory is unavailable."]
            )
        }

        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let safeTripID = payload.tripId.replacingOccurrences(of: "/", with: "-")
        let normalizedDate = Self.normalizeTripInformationDateForDisplay(
            payload.tripInformationDate,
            fallbackDate: Date()
        ).dateString
        let fileName = "\(normalizedDate)_\(safeTripID).json"
        let finalURL = dir.appendingPathComponent(fileName)

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: finalURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw NSError(
                domain: "CrewAccessImport",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "JSON output path is a directory: \(finalURL.path)"]
            )
        }

        // Defer stale deletion until after both JSON write and schedule cache save succeed.
        let incomingTripKey = Self.crewAccessTripKey(
            tripID: payload.tripId,
            tripInformationDate: payload.tripInformationDate,
            fallbackDate: Date()
        )
        var staleSameBidPeriodTripURLs: [URL] = []
        if let existingFiles = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in existingFiles {
                guard fileURL.path != finalURL.path,
                      fileURL.pathExtension.lowercased() == "json",
                      let incomingTripKey,
                      let data = try? Data(contentsOf: fileURL),
                      let header = try? JSONDecoder().decode(CrewAccessTripHeader.self, from: data),
                      let existingTripID = header.tripId,
                      Self.crewAccessTripKey(
                        tripID: existingTripID,
                        tripInformationDate: header.tripInformationDate,
                        fallbackDate: nil
                      ) == incomingTripKey else {
                    continue
                }
                staleSameBidPeriodTripURLs.append(fileURL)
            }
        }

        let backupURL = dir.appendingPathComponent(".\(fileName).bak-\(UUID().uuidString)")
        let hadExistingFile = fm.fileExists(atPath: finalURL.path)
        if hadExistingFile {
            try fm.copyItem(at: finalURL, to: backupURL)
        }

        let tempURL = dir.appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            if hadExistingFile {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: finalURL)
            }
            return CrewAccessJSONWriteContext(
                finalURL: finalURL,
                backupURL: hadExistingFile ? backupURL : nil,
                createdNewFile: !hadExistingFile,
                staleSameBidPeriodTripURLs: staleSameBidPeriodTripURLs
            )
        } catch {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
            if hadExistingFile, fm.fileExists(atPath: backupURL.path) {
                try? fm.removeItem(at: backupURL)
            }
            throw error
        }
    }

    private func rollbackCrewAccessJSONWrite(with context: CrewAccessJSONWriteContext) throws {
        let fm = FileManager.default

        if let backupURL = context.backupURL {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: context.finalURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw NSError(
                    domain: "CrewAccessImport",
                    code: 1003,
                    userInfo: [NSLocalizedDescriptionKey: "Rollback blocked because JSON output path is a directory."]
                )
            }

            if fm.fileExists(atPath: context.finalURL.path) {
                _ = try fm.replaceItemAt(context.finalURL, withItemAt: backupURL)
            } else {
                try fm.moveItem(at: backupURL, to: context.finalURL)
            }
            return
        }

        if context.createdNewFile, fm.fileExists(atPath: context.finalURL.path) {
            try fm.removeItem(at: context.finalURL)
        }
    }

    private func removeStaleCrewAccessJSONFilesBestEffort(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                logger.info("[Import] Removed stale trip file: \(url.lastPathComponent, privacy: .private)")
            } catch {
                logger.error("[Import] Failed to remove stale trip file \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func resetSeniorityDatabase() {
        let seniorityFileName = self.seniorityFileName
        let legacySeniorityFileName = self.legacySeniorityFileName
        let seniorityRecordsKey = self.seniorityRecordsKey
        let legacySeniorityRecordsKey = self.legacySeniorityRecordsKey

        Task { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                try Self.clearSeniorityDataStorage(
                    seniorityFileName: seniorityFileName,
                    legacySeniorityFileName: legacySeniorityFileName,
                    seniorityRecordsKey: seniorityRecordsKey,
                    legacySeniorityRecordsKey: legacySeniorityRecordsKey
                )
            }.result

            switch result {
            case .success:
                self.seniorityRecords = []
                self.hasLoadedSeniorityRecords = true
                self.hasSeniorityDataOnDisk = false
                self.seniorityImportMessage = "Seniority DB reset. Import Seniority CSV again."
            case let .failure(error):
                self.hasSeniorityDataOnDisk = Self.seniorityDataIsUsableOnDisk(
                    seniorityFileName: seniorityFileName,
                    legacySeniorityFileName: legacySeniorityFileName,
                    seniorityRecordsKey: seniorityRecordsKey,
                    legacySeniorityRecordsKey: legacySeniorityRecordsKey
                )
                self.seniorityImportMessage = "Failed to reset Seniority DB: \(error.localizedDescription)"
            }
        }
    }

    func verifyIdentity(gemsID rawGemsID: String, dateOfBirth rawDateOfBirth: String) async {
        let identityRecordName = currentCloudKitRecordName ?? localIdentityRecordName()
        if currentCloudKitRecordName == nil {
            currentCloudKitRecordName = identityRecordName
        }

        let gemsID = GEMSIDNormalizer.normalize(rawGemsID)
        let dobInput = rawDateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gemsID.isEmpty, !dobInput.isEmpty else {
            identityActionMessage = "GEMS ID and DOB are required."
            return
        }
        guard let normalizedDOB = normalizeDOB(dobInput) else {
            identityActionMessage = "DOB format must be MM/DD/YYYY."
            return
        }

        let verificationResult: GEMSVerificationResult?
        if let mockResult = appReviewMockVerificationResult(gemsID: gemsID, normalizedDOB: normalizedDOB) {
            verificationResult = mockResult
        } else {
            do {
                verificationResult = try await gemsVerificationCloudKitService.verify(
                    gemsID: gemsID,
                    dateOfBirth: normalizedDOB
                )
            } catch {
                identityActionMessage = "Verification database is unavailable: \(error.localizedDescription)"
                return
            }
        }

        let isAdminBootstrap = verificationResult == nil && isAdminEligible(gemsID: gemsID, dob: normalizedDOB)
        guard verificationResult != nil || isAdminBootstrap || allowVerificationWithoutSeniorityDB else {
            identityActionMessage = "Verification failed. Check GEMS ID / DOB."
            return
        }
        let domicile = verificationResult?.domicile ?? DomicileSupport.defaultDomicile

        let verified = VerifiedIdentityProfile(
            cloudKitRecordName: identityRecordName,
            name: "GEMS \(gemsID)",
            gemsID: gemsID,
            domicile: domicile,
            equipment: "-",
            seat: "-",
            dateOfHire: "-",
            isAdminEligible: isAdminBootstrap || isAdminEligible(gemsID: gemsID, dob: normalizedDOB),
            adminPolicyFingerprint: adminPolicyFingerprint,
            verifiedAt: Date()
        )
        verifiedIdentity = verified
        saveVerifiedIdentity(verified)
        seedAppReviewMockScheduleIfNeeded(for: gemsID)
        do {
            try await gemsVerificationCloudKitService.recordVerifiedUser(gemsID: gemsID)
        } catch {
            logNonFatal("Failed to record verified app user: \(error.localizedDescription)")
        }
        updateAdminStatus()
        identityActionMessage = isAdminBootstrap
            ? "Verified as bootstrap admin. Upload GEMS verification records to CloudKit."
            : "Verified as GEMS \(gemsID) / \(domicile)."
        Task { [weak self] in
            await self?.syncFriendCloudKit(reason: "identity verified")
        }
        Task { [weak self] in
            await self?.fetchDeviceScheduleIfNeeded(reason: "identity verified")
            await self?.fetchManualEventsIfNeeded(reason: "identity verified")
            await self?.uploadManualEventsIfNeeded(reason: "identity verified")
        }
    }

    private func appReviewMockVerificationResult(gemsID: String, normalizedDOB: String) -> GEMSVerificationResult? {
        guard normalizedDOB == "01/01/1990" else { return nil }
        switch GEMSIDNormalizer.normalize(gemsID) {
        case "0000001", "0000002":
            return GEMSVerificationResult(gemsID: gemsID, domicile: DomicileSupport.defaultDomicile)
        default:
            return nil
        }
    }

    private func linkAppReviewMockFriendIfNeeded(myGEMSID: String, friendGEMSID: String) -> Bool {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let friend = GEMSIDNormalizer.normalize(friendGEMSID)
        guard my == "0000001", friend == "0000002" else { return false }

        let linkedAt = Date()
        upsertAppReviewMockPilotTwoFriend(linkedAt: linkedAt)
        friendCloudKitSyncMessage = "App Review mock friend linked locally."
        friendActionMessage = "Friend linked: \(friend)"
        return true
    }

    private func upsertAppReviewMockPilotTwoFriend(linkedAt: Date) {
        enableScheduleSharingForFriends()
        let friend = "0000002"
        let existing = friendConnections.first { $0.employeeID == friend }
        let mockFriend = FriendConnection(
            id: existing?.id ?? UUID(),
            employeeID: friend,
            nickname: existing?.nickname ?? "App Review Pilot Two",
            status: .accepted,
            requestedAt: existing?.requestedAt ?? linkedAt,
            linkedAt: existing?.linkedAt ?? linkedAt,
            acceptedAt: existing?.acceptedAt ?? linkedAt,
            sharedSchedules: [Self.appReviewPilotTwoSchedule(updatedAt: linkedAt)]
        )
        if let index = friendConnections.firstIndex(where: { $0.employeeID == friend }) {
            friendConnections[index] = mockFriend
        } else {
            friendConnections.append(mockFriend)
        }
        saveFriendConnections()
        updateScheduleSharingAfterFriendListChange()
        friendCloudKitSyncMessage = "App Review mock schedule sharing active."
    }

    private func seedAppReviewMockScheduleIfNeeded(for gemsID: String) {
        let normalized = GEMSIDNormalizer.normalize(gemsID)
        let schedule: PayPeriodSchedule
        switch normalized {
        case "0000001":
            schedule = Self.appReviewPilotOneSchedule(updatedAt: Date())
        case "0000002":
            schedule = Self.appReviewPilotTwoSchedule(updatedAt: Date())
        default:
            return
        }

        var updatedCrewAccess = crewAccessSchedules.filter { existing in
            existing.id != schedule.id
                && !existing.legs.contains { $0.pairing == schedule.legs.first?.pairing }
        }
        updatedCrewAccess.append(schedule)
        updatedCrewAccess.sort { $0.label < $1.label }
        crewAccessSchedules = updatedCrewAccess
        schedules = mergeAndSortSchedules(crew: updatedCrewAccess, bidpro: bidproSchedules)
        let persistedLastSyncAt = lastSyncAt ?? Date()
        do {
            try cacheService.save(ScheduleCacheSnapshotV2(
                crewAccessSchedules: updatedCrewAccess,
                bidproSchedules: bidproSchedules,
                lastSyncAt: persistedLastSyncAt,
                migratedAt: nil
            ))
            if lastSyncAt == nil {
                lastSyncAt = persistedLastSyncAt
            }
        } catch {
            logNonFatal("Failed to persist App Review mock schedule: \(error.localizedDescription)")
        }
        lastImportSummaryMessage = "Loaded App Review sample trip \(schedule.legs.first?.pairing ?? schedule.id)."
        if normalized == "0000001",
           friendConnections.contains(where: { $0.employeeID == "0000002" }) {
            upsertAppReviewMockPilotTwoFriend(linkedAt: Date())
        }
    }

    private static func appReviewPilotOneSchedule(updatedAt: Date) -> PayPeriodSchedule {
        let payPeriod = "PP26-07"
        let pairing = "A00001"
        let legs = [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "001",
                depAirport: "ANC",
                depLocal: "2026-06-14 05:00",
                arrAirport: "CVG",
                arrLocal: "2026-06-14 15:00",
                depUTC: "2026-06-14T13:00:00Z",
                arrUTC: "2026-06-14T19:00:00Z",
                status: "-",
                block: "06:00",
                layoverStation: "CVG",
                layoverHotelName: "Holiday Inn",
                layoverDuration: "14:30",
                stdUTC: "2026-06-14T13:00:00Z",
                staUTC: "2026-06-14T19:00:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 2,
                flight: "002",
                depAirport: "CVG",
                depLocal: "2026-06-15 06:00",
                arrAirport: "HND",
                arrLocal: "2026-06-16 07:00",
                depUTC: "2026-06-15T10:00:00Z",
                arrUTC: "2026-06-15T22:00:00Z",
                status: "-",
                block: "12:00",
                layoverStation: "HND",
                layoverHotelName: "Tokyu Haneda",
                layoverDuration: "24:30",
                stdUTC: "2026-06-15T10:00:00Z",
                staUTC: "2026-06-15T22:00:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 3,
                flight: "5X003",
                depAirport: "HND",
                depLocal: "2026-06-17 09:30",
                arrAirport: "ANC",
                arrLocal: "2026-06-17 01:30",
                depUTC: "2026-06-17T00:30:00Z",
                arrUTC: "2026-06-17T09:30:00Z",
                status: "DH",
                block: "09:00",
                stdUTC: "2026-06-17T00:30:00Z",
                staUTC: "2026-06-17T09:30:00Z"
            )
        ]
        return PayPeriodSchedule(
            id: "\(payPeriod)-\(pairing)",
            label: "\(payPeriod)-\(pairing)",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: updatedAt,
            legs: legs,
            openTimeTrips: []
        )
    }

    private static func appReviewPilotTwoSchedule(updatedAt: Date) -> PayPeriodSchedule {
        let payPeriod = "PP26-07"
        let pairing = "B00001"
        let legs = [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "4",
                depAirport: "ANC",
                depLocal: "2026-06-14 10:00",
                arrAirport: "HKG",
                arrLocal: "2026-06-15 12:00",
                depUTC: "2026-06-14T18:00:00Z",
                arrUTC: "2026-06-15T04:00:00Z",
                status: "-",
                block: "10:00",
                stdUTC: "2026-06-14T18:00:00Z",
                staUTC: "2026-06-15T04:00:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 2,
                flight: "5",
                depAirport: "HKG",
                depLocal: "2026-06-16 04:00",
                arrAirport: "HND",
                arrLocal: "2026-06-16 08:30",
                depUTC: "2026-06-15T20:00:00Z",
                arrUTC: "2026-06-15T23:30:00Z",
                status: "-",
                block: "04:30",
                stdUTC: "2026-06-15T20:00:00Z",
                staUTC: "2026-06-15T23:30:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 3,
                flight: "5X003",
                depAirport: "HND",
                depLocal: "2026-06-17 09:30",
                arrAirport: "ANC",
                arrLocal: "2026-06-17 01:30",
                depUTC: "2026-06-17T00:30:00Z",
                arrUTC: "2026-06-17T09:30:00Z",
                status: "DH",
                block: "09:00",
                stdUTC: "2026-06-17T00:30:00Z",
                staUTC: "2026-06-17T09:30:00Z"
            )
        ]
        return PayPeriodSchedule(
            id: "\(payPeriod)-\(pairing)",
            label: "\(payPeriod)-\(pairing)",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: updatedAt,
            legs: legs,
            openTimeTrips: []
        )
    }

    func refreshVerifiedAppUsers() async {
        guard isAdmin else {
            verifiedAppUsersMessage = "Admin verification is required."
            return
        }
        guard !isLoadingVerifiedAppUsers else { return }
        isLoadingVerifiedAppUsers = true
        defer { isLoadingVerifiedAppUsers = false }

        do {
            verifiedAppUsers = try await gemsVerificationCloudKitService.fetchVerifiedUsers()
            verifiedAppUsersMessage = verifiedAppUsers.isEmpty
                ? "No verified app users found."
                : "Loaded \(verifiedAppUsers.count) verified app users."
        } catch {
            verifiedAppUsersMessage = "Failed to load verified app users: \(error.localizedDescription)"
            logNonFatal("Failed to load verified app users: \(error.localizedDescription)")
        }
    }

    func deleteLocalProfileAccount() {
        let deletingGEMSID = verifiedIdentity?.gemsID
        isDeletingProfileAccount = true
        setFriendConnectionsResetAt(Date())
        Self.clearLocalProfileStorageForDelete()
        friendConnections = []
        saveFriendConnections()
        isScheduleSharingEnabled = false
        UserDefaults.standard.set(false, forKey: scheduleSharingEnabledKey)
        friendCloudKitSyncMessage = nil
        verifiedIdentity = nil
        identityActionMessage = nil
        clearVerifiedIdentity()
        Task { [weak self] in
            guard let self else { return }
            if let deletingGEMSID {
                await deleteFriendSharingDataForAccountDelete(gemsID: deletingGEMSID)
            }
            await writeProfileTombstoneToCloudKit()
            isDeletingProfileAccount = false
        }
    }

    private func deleteFriendSharingDataForAccountDelete(gemsID: String) async {
        do {
            try await friendScheduleCloudKitService.deleteFriendSharingData(gemsID: gemsID)
        } catch {
            logNonFatal("Friend CloudKit account-delete cleanup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile CloudKit sync

    nonisolated static func clearLocalProfileStorageForDelete(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ProfileStorageKeys.avatarImageData)
        defaults.set("", forKey: ProfileStorageKeys.displayName)
        defaults.set("", forKey: ProfileStorageKeys.gemsID)
        defaults.set(ProfileFleet.fleet757.rawValue, forKey: ProfileStorageKeys.fleet)
        defaults.set(OperationalSettings.defaultCrewBase.rawValue, forKey: OperationalSettings.crewBaseKey)
        defaults.set(PilotQualification.captain.rawValue, forKey: "pilot_qualification")
        defaults.removeObject(forKey: ProfileStorageKeys.lastSeenAt)
        // Reset local updatedAt to epoch so this device's stale data cannot win
        // a future last-write-wins conflict against the CloudKit tombstone.
        defaults.set(0.0, forKey: ProfileStorageKeys.updatedAt)
    }

    /// Syncs profile between local UserDefaults and CloudKit private database.
    /// last-write-wins on `updatedAt`. Non-blocking; errors are logged, not surfaced.
    func syncProfileWithCloudKit() async {
        guard !isProfileCloudKitSyncing, !isDeletingProfileAccount else { return }
        isProfileCloudKitSyncing = true
        defer { isProfileCloudKitSyncing = false }

        do {
            if let remote = try await profileCloudKitService.fetchProfile() {
                let local = ProfileSnapshot.loadFromLocalStorage()
                if remote.updatedAt > local.updatedAt {
                    remote.saveToLocalStorage()
                } else if local.updatedAt > remote.updatedAt {
                    try await profileCloudKitService.saveProfile(local)
                }
                // Equal updatedAt → no-op (avoid churn)
            } else {
                let local = ProfileSnapshot.loadFromLocalStorage()
                guard local.hasContent else { return }
                // No remote record yet — upload local profile.
                try await profileCloudKitService.saveProfile(local)
            }
        } catch {
            logNonFatal("Profile CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    /// Uploads current local profile to CloudKit. Called on ProfileTabView dismiss.
    func uploadProfileToCloudKit() async {
        let snapshot = ProfileSnapshot.loadFromLocalStorage()
        guard snapshot.hasContent else { return }
        do {
            try await profileCloudKitService.saveProfile(snapshot)
        } catch {
            logNonFatal("Profile CloudKit upload failed: \(error.localizedDescription)")
        }
    }

    /// Updates `updatedAt` in UserDefaults only — no CloudKit call.
    /// Use on per-field onChange. The actual upload fires on view dismiss.
    func markProfileUpdated() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ProfileStorageKeys.updatedAt)
    }

    /// Writes an empty profile tombstone to CloudKit so other devices detect the
    /// deletion via last-write-wins (`tombstone.updatedAt > their local.updatedAt`).
    /// Does NOT call CKDatabase.delete — the record stays, content is cleared.
    private func writeProfileTombstoneToCloudKit() async {
        let tombstone = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil,
            updatedAt: Date(),   // must be newer than any device's local updatedAt
            lastSeenAt: nil
        )
        do {
            try await profileCloudKitService.saveProfile(tombstone)
        } catch {
            // Non-fatal: local delete already succeeded.
            logNonFatal("Profile CloudKit tombstone write failed: \(error.localizedDescription)")
        }
    }

    func syncTapped() async {
        guard !AppEnvironment.isAppStoreReviewMode else {
            errorMessage = AppEnvironment.tripBoardUnavailableMessage
            isShowingLoginSheet = false
            isSyncing = false
            return
        }
        guard isIdentityVerified else {
            errorMessage = verificationRequiredMessage
            return
        }
        guard !isSyncing else { return }
        errorMessage = nil

        // Fast path: if already known to be logged out, show login sheet immediately
        // without re-checking WKWebView cookies (avoids stale cookie ambiguity in tests).
        guard authStatus != .loggedOut else {
            isShowingLoginSheet = true
            return
        }

        await refreshSessionCookiesFromWebKit()

        let hasCookies = !sessionCookies.isEmpty
        guard hasCookies else {
            authStatus = .loggedOut
            isShowingLoginSheet = true
            return
        }

        await performSync(openLoginOnAuthFailure: true)
    }

    func autoFetchOnAppActiveIfEnabled(_ enabled: Bool) async {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard enabled else { return }
        guard isIdentityVerified else { return }
        guard !isSyncing else { return }
        let now = Date()
        if let lastAutoFetchAt, now.timeIntervalSince(lastAutoFetchAt) < autoFetchMinInterval {
            return
        }
        lastAutoFetchAt = now

        await refreshSessionCookiesFromWebKit()
        guard !sessionCookies.isEmpty else { return }
        guard authService.isAuthenticated(url: nil, cookies: sessionCookies) else { return }
        await performSync(openLoginOnAuthFailure: false)
    }

    func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await notificationService.authorizationStatus()
    }

    func updateNotificationPreferencesFromSettings(triggeredByEnablingToggle: Bool) async {
        notificationScheduleMessage = nil
        await refreshNotificationAuthorizationStatus()

        let prefs = notificationPreferences
        if !prefs.anyEnabled {
            _ = await notificationService.reschedule(
                schedules: schedules,
                notify48h: false,
                notify24h: false,
                notify12h: false
            )
            return
        }

        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await rescheduleNotificationsIfAuthorized()
        case .notDetermined:
            guard triggeredByEnablingToggle else {
                return
            }
            let granted = (try? await notificationService.requestAuthorization()) ?? false
            notificationAuthorizationStatus = await notificationService.authorizationStatus()
            if granted {
                await rescheduleNotificationsIfAuthorized()
            }
        default:
            break
        }
    }

    func handleLoginSucceeded(cookies: [HTTPCookie], url: URL?) {
        do {
            guard authService.isAuthenticated(url: url, cookies: cookies) else {
                authStatus = .loggedOut
                errorMessage = "Login session was not accepted. Please try Sync again."
                return
            }
            try authService.persistCookies(cookies)
            sessionCookies = cookies
            authStatus = .loggedIn
            errorMessage = nil
            isShowingLoginSheet = false

            // Run sync immediately after an explicit successful login.
            Task { [weak self] in
                guard let self, self.isIdentityVerified else { return }
                await self.performSync(openLoginOnAuthFailure: false)
            }
        } catch {
            errorMessage = "Failed to save login session: \(error.localizedDescription)"
        }
    }

    func handleLoginCanceled() {
        isShowingLoginSheet = false
        if authStatus != .loggedIn {
            authStatus = authService.isAuthenticated(url: nil, cookies: sessionCookies) ? .loggedIn : .loggedOut
        }
    }

    private func performSync(openLoginOnAuthFailure: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let result = try await syncWithTimeout(cookies: sessionCookies, timeoutSeconds: 60)
            bidproSchedules = mergeBidproSchedulesKeepingRecentPeriods(
                fetched: result,
                existing: bidproSchedules,
                keepPeriods: 2
            )
            schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
            lastSyncAt = Date()
            authStatus = .loggedIn
            isTripBoardServerDown = false
            didLastFetchFail = false
            do {
                try cacheService.save(
                    ScheduleCacheSnapshotV2(
                        crewAccessSchedules: crewAccessSchedules,
                        bidproSchedules: bidproSchedules,
                        lastSyncAt: lastSyncAt,
                        migratedAt: nil
                    )
                )
            } catch {
                logNonFatal("Failed to save schedule cache: \(error.localizedDescription)")
            }
            await rescheduleNotificationsIfAuthorized()
        } catch {
            if error is CancellationError {
                return
            }
            if case SyncServiceError.notAuthenticated = error {
                authStatus = .loggedOut
                sessionCookies = []
                isTripBoardServerDown = false
                do {
                    try authService.clearPersistedCookies()
                } catch {
                    logNonFatal("Failed to clear persisted cookies: \(error.localizedDescription)")
                }
                await authService.clearWebKitCookies()
                if openLoginOnAuthFailure {
                    errorMessage = nil
                    isShowingLoginSheet = true
                } else {
                    errorMessage = "Login session was not accepted. Please try Sync again."
                    isShowingLoginSheet = false
                }
            } else {
                didLastFetchFail = true
                isTripBoardServerDown = isServerDownError(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncWithTimeout(cookies: [HTTPCookie], timeoutSeconds: UInt64) async throws -> [PayPeriodSchedule] {
        try await withThrowingTaskGroup(of: [PayPeriodSchedule].self) { group in
            group.addTask { [syncService] in
                try await syncService.sync(cookies: cookies)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw SyncServiceError.timeout
            }

            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    private func refreshSessionCookiesFromWebKit() async {
        let latest = await authService.currentWebKitCookies()
        guard !latest.isEmpty else { return }

        sessionCookies = latest
        authStatus = authService.isAuthenticated(url: nil, cookies: latest) ? .loggedIn : .loggedOut
        do {
            try authService.persistCookies(latest)
        } catch {
            logNonFatal("Failed to persist WebKit cookies: \(error.localizedDescription)")
        }
    }

    private var notificationPreferences: (notify48h: Bool, notify24h: Bool, notify12h: Bool, anyEnabled: Bool) {
        let defaults = UserDefaults.standard
        let n48 = defaults.object(forKey: notification48hKey) as? Bool ?? false
        let n24 = defaults.object(forKey: notification24hKey) as? Bool ?? false
        let n12 = defaults.object(forKey: notification12hKey) as? Bool ?? false
        return (n48, n24, n12, n48 || n24 || n12)
    }

    private func rescheduleNotificationsIfAuthorized() async {
        let status = await notificationService.authorizationStatus()
        notificationAuthorizationStatus = status
        guard isNotificationAuthorized(status) else { return }

        let prefs = notificationPreferences
        let result = await notificationService.reschedule(
            schedules: crewAccessSchedules,
            notify48h: prefs.notify48h,
            notify24h: prefs.notify24h,
            notify12h: prefs.notify12h
        )
        if result.failed > 0 {
            notificationScheduleMessage = "Some reminders could not be scheduled (\(result.failed)/\(result.requested))."
        } else {
            notificationScheduleMessage = nil
        }
    }

    private func isNotificationAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        if status == .authorized || status == .provisional {
            return true
        }
#if os(iOS)
        if status == .ephemeral {
            return true
        }
#endif
        return false
    }

    private func logNonFatal(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    private func isServerDownError(_ error: Error) -> Bool {
        guard let syncError = error as? SyncServiceError else { return false }
        switch syncError {
        case .timeout, .network:
            return true
        case let .requestFailed(statusCode):
            return statusCode >= 500
        default:
            return false
        }
    }

    private func loadFriendConnections() -> [FriendConnection] {
        // Keychain を先に読む。なければ UserDefaults から移行する。
        var local: [FriendConnection] = []
        var isFromKeychain = false
        if let keychainData = try? keychainService.load(account: friendConnectionsKey),
           let decoded = try? JSONDecoder().decode([FriendConnection].self, from: keychainData) {
            local = decoded
            isFromKeychain = true
        } else if let udData = UserDefaults.standard.data(forKey: friendConnectionsKey),
                  let decoded = try? JSONDecoder().decode([FriendConnection].self, from: udData) {
            local = decoded
            isFromKeychain = false
        }

        // Merge with iCloud KV lightweight status so accepted connections
        // flow from iPhone to iPad (and vice-versa) without needing CloudKit.
        let kvEntries = iCloudKVFriendConnectionEntries()
        let combined = local + kvEntries.map { friendConnection(from: $0) }
        let normalized = currentFriendConnections(normalizeFriendConnections(combined))
        if normalized != local || !isFromKeychain,
           let migratedData = try? JSONEncoder().encode(normalized) {
            try? keychainService.save(data: migratedData, account: friendConnectionsKey)
            if !isFromKeychain {
                // UserDefaults → Keychain への一回限りの移行
                UserDefaults.standard.removeObject(forKey: friendConnectionsKey)
            }
        }
        return normalized
    }

    private func iCloudKVFriendConnectionEntries() -> [FriendConnectionSyncEntry] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: friendConnectionsSyncKey) else { return [] }
        return (try? JSONDecoder().decode([FriendConnectionSyncEntry].self, from: data)) ?? []
    }

    private func friendConnectionsResetAt() -> Date? {
        let localTimestamp = UserDefaults.standard.double(forKey: friendConnectionsResetAtKey)
        let cloudTimestamp = NSUbiquitousKeyValueStore.default.double(forKey: friendConnectionsResetAtKey)
        let timestamp = max(localTimestamp, cloudTimestamp)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func setFriendConnectionsResetAt(_ date: Date) {
        let timestamp = date.timeIntervalSince1970
        UserDefaults.standard.set(timestamp, forKey: friendConnectionsResetAtKey)
        NSUbiquitousKeyValueStore.default.set(timestamp, forKey: friendConnectionsResetAtKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private func friendConnection(from entry: FriendConnectionSyncEntry) -> FriendConnection {
        let schedules: [PayPeriodSchedule]
        if let data = entry.sharedSchedulesData,
           let decoded = try? JSONDecoder().decode([PayPeriodSchedule].self, from: data) {
            schedules = decoded
        } else {
            schedules = []
        }
        return FriendConnection(
            id: entry.id,
            employeeID: entry.employeeID,
            nickname: entry.nickname,
            avatarImageData: entry.avatarImageData,
            status: entry.restoredStatus,
            requestDirection: entry.restoredStatus == .accepted ? nil : entry.requestDirection,
            requestedAt: entry.requestedAt,
            linkedAt: entry.linkedAt ?? entry.acceptedAt,
            acceptedAt: entry.acceptedAt,
            sharedSchedules: schedules
        )
    }

    private func mergeICloudKVFriendConnections() async {
        let kvEntries = iCloudKVFriendConnectionEntries()
        guard !kvEntries.isEmpty else { return }
        let previouslyPending = Set(friendConnections.filter { $0.status == .pending }.map(\.employeeID))
        let kvConnections = kvEntries.map { friendConnection(from: $0) }
        let merged = currentFriendConnections(normalizeFriendConnections(friendConnections + kvConnections))
        if merged != friendConnections {
            friendConnections = merged
            saveFriendConnections()
            let newlyAccepted = friendConnections.filter {
                $0.status == .accepted && previouslyPending.contains($0.employeeID)
            }
            for friend in newlyAccepted {
                await notifyFriendLinked(friend)
            }
        }
    }

    private struct FriendConnectionSyncEntry: Codable {
        var id: UUID
        var employeeID: String
        var nickname: String?
        var avatarImageData: Data?
        var status: FriendConnectionStatus
        var requestDirection: FriendRequestDirection?
        var requestedAt: Date
        var linkedAt: Date?
        var acceptedAt: Date?
        var sharedSchedulesData: Data?

        var restoredStatus: FriendConnectionStatus {
            acceptedAt == nil ? status : .accepted
        }
    }

    private func normalizeFriendConnections(_ connections: [FriendConnection]) -> [FriendConnection] {
        var normalized: [FriendConnection] = []
        for connection in connections {
            let employeeID = GEMSIDNormalizer.normalize(connection.employeeID)
            let trimmedNickname = connection.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let migrated = FriendConnection(
                id: connection.id,
                employeeID: employeeID,
                nickname: trimmedNickname.isEmpty ? nil : trimmedNickname,
                avatarImageData: connection.avatarImageData,
                status: (connection.status == .accepted || connection.acceptedAt != nil) ? .accepted : .pending,
                requestDirection: connection.status == .accepted ? nil : (connection.requestDirection ?? .outgoing),
                requestedAt: connection.requestedAt,
                linkedAt: connection.linkedAt,
                acceptedAt: connection.acceptedAt,
                sharedSchedules: connection.sharedSchedules,
                sharedTimelineCards: connection.sharedTimelineCards
            )
            if let index = normalized.firstIndex(where: { $0.employeeID == employeeID }) {
                normalized[index] = mergedFriendConnection(normalized[index], migrated)
            } else {
                normalized.append(migrated)
            }
        }
        return normalized
    }

    private func currentFriendConnections(_ connections: [FriendConnection]) -> [FriendConnection] {
        guard let resetAt = friendConnectionsResetAt() else { return connections }
        return connections.filter { connection in
            if connection.status == .accepted || connection.acceptedAt != nil {
                let acceptedAt = connection.acceptedAt ?? connection.linkedAt ?? connection.requestedAt
                return acceptedAt >= resetAt
            }
            if connection.requestDirection == .incoming {
                return true
            }
            return connection.requestedAt >= resetAt
        }
    }

    private func mergedFriendConnection(_ lhs: FriendConnection, _ rhs: FriendConnection) -> FriendConnection {
        let accepted = lhs.status == .accepted || rhs.status == .accepted
        let acceptedAt = lhs.acceptedAt ?? rhs.acceptedAt
        return FriendConnection(
            id: lhs.id,
            employeeID: lhs.employeeID,
            nickname: lhs.nickname ?? rhs.nickname,
            avatarImageData: lhs.avatarImageData ?? rhs.avatarImageData,
            status: (accepted || acceptedAt != nil) ? .accepted : .pending,
            requestDirection: (accepted || acceptedAt != nil) ? nil : (lhs.requestDirection == .incoming || rhs.requestDirection == .incoming ? .incoming : .outgoing),
            requestedAt: min(lhs.requestedAt, rhs.requestedAt),
            linkedAt: lhs.linkedAt ?? rhs.linkedAt,
            acceptedAt: acceptedAt,
            sharedSchedules: lhs.sharedSchedules.isEmpty ? rhs.sharedSchedules : lhs.sharedSchedules,
            sharedTimelineCards: lhs.sharedTimelineCards.isEmpty ? rhs.sharedTimelineCards : lhs.sharedTimelineCards
        )
    }

    func setFriendNickname(id: UUID, nickname: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = friendConnections.firstIndex(where: { $0.id == id }) else { return }
        friendConnections[index].nickname = trimmed.isEmpty ? nil : trimmed
        saveFriendConnections()
    }

    private func saveFriendConnections() {
        let connectionsToSave = currentFriendConnections(friendConnections)
        if connectionsToSave != friendConnections {
            friendConnections = connectionsToSave
        }
        do {
            let data = try JSONEncoder().encode(connectionsToSave)
            try keychainService.save(data: data, account: friendConnectionsKey)
        } catch {
            logNonFatal("Failed to save friend connections: \(error.localizedDescription)")
        }
        // Write status + cached schedule data to iCloud KV so other devices
        // (e.g. iPad) can show friend timelines even when CloudKit records are stale.
        // CRITICAL: never overwrite existing KV schedule data with empty data.
        // If our local sharedSchedules for a friend is empty, preserve whatever
        // schedule data is already in KV (likely written by another device that
        // has the friend's cache). This prevents the iPad-clobbers-iPhone-data
        // race condition where the device without cache wipes out the cached
        // data that another device wrote.
        let existingEntries = iCloudKVFriendConnectionEntries()
        let existingByID = Dictionary(uniqueKeysWithValues: existingEntries.map {
            (GEMSIDNormalizer.normalize($0.employeeID), $0)
        })
        var kvBudget = 800_000
        let encoder = JSONEncoder()
        let entries = connectionsToSave.map { conn -> FriendConnectionSyncEntry in
            let normalizedID = GEMSIDNormalizer.normalize(conn.employeeID)
            let acceptedAt = conn.acceptedAt
                ?? (conn.status == .accepted ? (conn.linkedAt ?? conn.requestedAt) : nil)
                ?? existingByID[normalizedID]?.acceptedAt
            var schedData: Data? = nil
            if conn.status == .accepted, !conn.sharedSchedules.isEmpty,
               let encoded = try? encoder.encode(conn.sharedSchedules),
               encoded.count <= kvBudget {
                schedData = encoded
                kvBudget -= encoded.count
            } else if conn.status == .accepted,
                      let existing = existingByID[normalizedID]?.sharedSchedulesData,
                      existing.count <= kvBudget {
                // Local schedule is empty/missing — keep existing KV data so we
                // don't blow away cached schedules another device just wrote.
                schedData = existing
                kvBudget -= existing.count
            }
            return FriendConnectionSyncEntry(
                id: conn.id, employeeID: conn.employeeID,
                nickname: conn.nickname,
                avatarImageData: conn.avatarImageData,
                status: acceptedAt == nil ? conn.status : .accepted,
                requestDirection: acceptedAt == nil ? conn.requestDirection : nil,
                requestedAt: conn.requestedAt,
                linkedAt: conn.linkedAt ?? acceptedAt,
                acceptedAt: acceptedAt,
                sharedSchedulesData: schedData
            )
        }
        if let syncData = try? encoder.encode(entries) {
            let schedSizes = entries.map { "\($0.employeeID):\($0.sharedSchedulesData?.count ?? 0)B" }.joined(separator: ", ")
            logger.info("[KVSync] saveFriendConnections: writing \(syncData.count, privacy: .public)B total — schedules: [\(schedSizes, privacy: .private)]")
            NSUbiquitousKeyValueStore.default.set(syncData, forKey: friendConnectionsSyncKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    private func loadSeniorityRecordsAsync() async {
        struct SeniorityLoadResult {
            let records: [PilotSeniorityRecord]
            let hasUsableDataOnDisk: Bool
            let warningMessage: String?
        }

        let result: SeniorityLoadResult = await Task.detached(
            priority: .utility
        ) { [seniorityFileName, legacySeniorityFileName, seniorityRecordsKey, legacySeniorityRecordsKey] in
            let fm = FileManager.default
            do {
                let appSupport = try fm.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let fileURL = appSupport.appendingPathComponent(seniorityFileName)
                let legacyFileURL = appSupport.appendingPathComponent(legacySeniorityFileName)
                if fm.fileExists(atPath: fileURL.path) {
                    let data = try Data(contentsOf: fileURL)
                    try? Self.applyCompleteFileProtection(to: fileURL)
                    let decoded = try JSONDecoder().decode([PilotSeniorityRecord].self, from: data)
                    return SeniorityLoadResult(
                        records: decoded,
                        hasUsableDataOnDisk: !decoded.isEmpty,
                        warningMessage: decoded.isEmpty
                            ? "Seniority DB is empty. Re-import the seniority CSV."
                            : nil
                    )
                }

                // One-time migration from old file name.
                if fm.fileExists(atPath: legacyFileURL.path) {
                    let oldData = try Data(contentsOf: legacyFileURL)
                    let migrated = try JSONDecoder().decode([PilotSeniorityRecord].self, from: oldData)
                    try Self.writeProtectedData(oldData, to: fileURL)
                    try? fm.removeItem(at: legacyFileURL)
                    return SeniorityLoadResult(
                        records: migrated,
                        hasUsableDataOnDisk: !migrated.isEmpty,
                        warningMessage: migrated.isEmpty
                            ? "Seniority DB is empty. Re-import the seniority CSV."
                            : nil
                    )
                }

                // One-time migration from old UserDefaults storage.
                if let oldData = UserDefaults.standard.data(forKey: seniorityRecordsKey)
                    ?? UserDefaults.standard.data(forKey: legacySeniorityRecordsKey) {
                    let migrated = try JSONDecoder().decode([PilotSeniorityRecord].self, from: oldData)
                    try Self.writeProtectedData(oldData, to: fileURL)
                    UserDefaults.standard.removeObject(forKey: seniorityRecordsKey)
                    UserDefaults.standard.removeObject(forKey: legacySeniorityRecordsKey)
                    return SeniorityLoadResult(
                        records: migrated,
                        hasUsableDataOnDisk: !migrated.isEmpty,
                        warningMessage: migrated.isEmpty
                            ? "Seniority DB is empty. Re-import the seniority CSV."
                            : nil
                    )
                }
                return SeniorityLoadResult(records: [], hasUsableDataOnDisk: false, warningMessage: nil)
            } catch {
                return SeniorityLoadResult(
                    records: [],
                    hasUsableDataOnDisk: false,
                    warningMessage: "Seniority DB is unreadable. Please import Seniority CSV again."
                )
            }
        }.value
        seniorityRecords = result.records
        hasSeniorityDataOnDisk = result.hasUsableDataOnDisk
        if let warningMessage = result.warningMessage {
            seniorityImportMessage = warningMessage
        }
        hasLoadedSeniorityRecords = true
    }

    private func loadVerifiedIdentity() -> VerifiedIdentityProfile? {
        // Keychain を先に読む。なければ UserDefaults から移行する。
        let data: Data
        let isFromKeychain: Bool
        if let keychainData = try? keychainService.load(account: verifiedIdentityKey) {
            data = keychainData
            isFromKeychain = true
        } else if let udData = UserDefaults.standard.data(forKey: verifiedIdentityKey) {
            data = udData
            isFromKeychain = false
        } else {
            return nil
        }

        do {
            let profile = try JSONDecoder().decode(VerifiedIdentityProfile.self, from: data)
            let normalizedGEMS = GEMSIDNormalizer.normalize(profile.gemsID)
            let result: VerifiedIdentityProfile
            if normalizedGEMS != profile.gemsID {
                result = VerifiedIdentityProfile(
                    cloudKitRecordName: profile.cloudKitRecordName,
                    name: profile.name,
                    gemsID: normalizedGEMS,
                    domicile: profile.domicile,
                    equipment: profile.equipment,
                    seat: profile.seat,
                    dateOfHire: profile.dateOfHire,
                    isAdminEligible: profile.isAdminEligible,
                    adminPolicyFingerprint: profile.adminPolicyFingerprint,
                    verifiedAt: profile.verifiedAt
                )
            } else {
                result = profile
            }
            if !isFromKeychain {
                // UserDefaults → Keychain へ一回限りの移行
                saveVerifiedIdentity(result)
                UserDefaults.standard.removeObject(forKey: verifiedIdentityKey)
            } else if normalizedGEMS != profile.gemsID {
                saveVerifiedIdentity(result)
            }
            return result
        } catch {
            logNonFatal("Failed to decode verified identity: \(error.localizedDescription)")
            if isFromKeychain {
                try? keychainService.delete(account: verifiedIdentityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: verifiedIdentityKey)
            }
            return nil
        }
    }

    private func saveVerifiedIdentity(_ profile: VerifiedIdentityProfile) {
        do {
            let data = try JSONEncoder().encode(profile)
            try keychainService.save(data: data, account: verifiedIdentityKey)
        } catch {
            logNonFatal("Failed to save verified identity: \(error.localizedDescription)")
        }
    }

    private func clearVerifiedIdentity() {
        try? keychainService.delete(account: verifiedIdentityKey)
        UserDefaults.standard.removeObject(forKey: verifiedIdentityKey)
        updateAdminStatus()
    }

    private func localIdentityRecordName() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: localIdentityRecordNameKey), !existing.isEmpty {
            return existing
        }
        let generated = "LOCAL-\(UUID().uuidString)"
        defaults.set(generated, forKey: localIdentityRecordNameKey)
        return generated
    }

    private func updateAdminStatus() {
        let isRecordNameAllowed = currentCloudKitRecordName
            .map { adminCloudKitRecordAllowlist.contains($0) } ?? false
        let isVerifiedAdmin: Bool = {
            guard let verifiedIdentity else { return false }
            guard verifiedIdentity.isAdminEligible else { return false }
            return verifiedIdentity.adminPolicyFingerprint == adminPolicyFingerprint
        }()
        isAdmin = isRecordNameAllowed || isVerifiedAdmin
    }

    private func isAdminEligible(gemsID: String, dob canonicalDOB: String) -> Bool {
        let hash = GEMSVerificationCloudKitService.verificationHash(
            gemsID: gemsID,
            normalizedDOB: canonicalDOB
        )
        return adminPolicy.verificationHashes.contains(hash)
    }

    private static func seniorityDataIsUsableOnDisk(
        seniorityFileName: String,
        legacySeniorityFileName: String,
        seniorityRecordsKey: String,
        legacySeniorityRecordsKey: String
    ) -> Bool {
        func hasUsableRecords(data: Data) -> Bool {
            guard let decoded = try? JSONDecoder().decode([PilotSeniorityRecord].self, from: data) else {
                return false
            }
            return !decoded.isEmpty
        }

        let fm = FileManager.default
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let current = appSupport.appendingPathComponent(seniorityFileName)
            if fm.fileExists(atPath: current.path),
               let data = try? Data(contentsOf: current) {
                return hasUsableRecords(data: data)
            }
            let legacy = appSupport.appendingPathComponent(legacySeniorityFileName)
            if fm.fileExists(atPath: legacy.path),
               let data = try? Data(contentsOf: legacy) {
                return hasUsableRecords(data: data)
            }
        }

        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: seniorityRecordsKey), hasUsableRecords(data: data) {
            return true
        }
        if let data = defaults.data(forKey: legacySeniorityRecordsKey), hasUsableRecords(data: data) {
            return true
        }
        return false
    }

    private nonisolated static func clearSeniorityDataStorage(
        seniorityFileName: String,
        legacySeniorityFileName: String,
        seniorityRecordsKey: String,
        legacySeniorityRecordsKey: String
    ) throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fileURL = appSupport.appendingPathComponent(seniorityFileName)
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        let legacyFileURL = appSupport.appendingPathComponent(legacySeniorityFileName)
        if fm.fileExists(atPath: legacyFileURL.path) {
            try fm.removeItem(at: legacyFileURL)
        }

        UserDefaults.standard.removeObject(forKey: seniorityRecordsKey)
        UserDefaults.standard.removeObject(forKey: legacySeniorityRecordsKey)
    }

    private nonisolated static func saveSeniorityRecordsToDisk(
        records: [PilotSeniorityRecord],
        seniorityFileName: String
    ) throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fileURL = appSupport.appendingPathComponent(seniorityFileName)
        let data = try JSONEncoder().encode(records)
        try writeProtectedData(data, to: fileURL)
    }

    private nonisolated static func writeProtectedData(_ data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try applyCompleteFileProtection(to: fileURL)
    }

    private nonisolated static func applyCompleteFileProtection(to fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
    }

    private static func fingerprint(for policy: AdminPolicy) -> String {
        let hashes = policy.verificationHashes.sorted().joined(separator: ",")
        let payload = "adminVerificationHashes:\(hashes)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadAdminPolicy() -> AdminPolicy {
        guard let url = Bundle.main.url(forResource: "AdminPolicy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(AdminPolicyRaw.self, from: data)
        else {
            return AdminPolicy(verificationHashes: [])
        }

        let hashes = Set(raw.adminVerificationHashes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        return AdminPolicy(verificationHashes: hashes)
    }

    private static func normalizeDOBStatic(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/")
        guard parts.count == 3,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let yearRaw = Int(parts[2]),
              month >= 1, month <= 12,
              day >= 1, day <= 31
        else {
            return nil
        }

        let fullYear: Int
        if parts[2].count == 2 {
            let currentYearTwoDigits = Calendar.current.component(.year, from: Date()) % 100
            fullYear = yearRaw > currentYearTwoDigits ? 1900 + yearRaw : 2000 + yearRaw
        } else if parts[2].count == 4 {
            fullYear = yearRaw
        } else {
            return nil
        }

        return String(format: "%02d/%02d/%04d", month, day, fullYear)
    }

    private func parseGEMSVerificationCSV(_ text: String) -> [GEMSVerificationImportRecord] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return [] }

        let headerFields = parseCSVLine(lines[0]).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        var headerMap: [String: Int] = [:]
        for (index, field) in headerFields.enumerated() where !field.isEmpty {
            headerMap[field] = headerMap[field] ?? index
        }
        guard let gemsIndex = headerMap["GEMS"],
              let dobIndex = headerMap["DOB"]
        else {
            return []
        }
        let domicileIndex = headerMap["DOM"]
            ?? headerMap["DOMICILE"]
            ?? headerMap["BASE"]

        var records: [GEMSVerificationImportRecord] = []
        var seenGEMS: Set<String> = []
        records.reserveCapacity(max(0, lines.count - 1))
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.indices.contains(gemsIndex), fields.indices.contains(dobIndex) else {
                continue
            }
            let gems = GEMSIDNormalizer.normalize(fields[gemsIndex])
            let dob = fields[dobIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let domicile = domicileIndex.flatMap { index in
                fields.indices.contains(index)
                ? fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            } ?? DomicileSupport.defaultDomicile
            guard !gems.isEmpty, !dob.isEmpty, normalizeDOB(dob) != nil, seenGEMS.insert(gems).inserted else {
                continue
            }
            records.append(GEMSVerificationImportRecord(gemsID: gems, dateOfBirth: dob, domicile: domicile))
        }
        return records
    }

    private func parseSeniorityCSV(_ text: String) -> [PilotSeniorityRecord] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return [] }

        let headerFields = parseCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var headerMap: [String: Int] = [:]
        for (index, field) in headerFields.enumerated() where !field.isEmpty {
            headerMap[field] = headerMap[field] ?? index
        }
        guard let nameIndex = headerMap["NAME"],
              let gemsIndex = headerMap["GEMS"],
              let domIndex = headerMap["DOM"],
              let eqptIndex = headerMap["EQPT"],
              let seatIndex = headerMap["SEAT"],
              let dohIndex = headerMap["DOH"],
              let dobIndex = headerMap["DOB"]
        else {
            return []
        }
        let senIndex = headerMap["SEN#"]

        var records: [PilotSeniorityRecord] = []
        records.reserveCapacity(max(0, lines.count - 1))
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            if fields.count <= max(nameIndex, gemsIndex, domIndex, eqptIndex, seatIndex, dohIndex, dobIndex) {
                continue
            }
            let name = fields[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let gems = GEMSIDNormalizer.normalize(fields[gemsIndex])
            let dob = fields[dobIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !gems.isEmpty, !dob.isEmpty else { continue }

            let record = PilotSeniorityRecord(
                seniorityNumber: senIndex.flatMap { index in
                    fields.indices.contains(index)
                    ? fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                } ?? "",
                name: name,
                gemsID: gems,
                domicile: fields[domIndex].trimmingCharacters(in: .whitespacesAndNewlines),
                equipment: fields[eqptIndex].trimmingCharacters(in: .whitespacesAndNewlines),
                seat: fields[seatIndex].trimmingCharacters(in: .whitespacesAndNewlines),
                dateOfHire: fields[dohIndex].trimmingCharacters(in: .whitespacesAndNewlines),
                dateOfBirth: dob
            )
            records.append(record)
        }
        return records
    }

    private func normalizeDOB(_ value: String) -> String? {
        Self.normalizeDOBStatic(value)
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isInQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                let next = line.index(after: index)
                if isInQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = next
                } else {
                    isInQuotes.toggle()
                }
            } else if char == ",", !isInQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    private func scheduleDisplaySortKey(_ schedule: PayPeriodSchedule) -> String {
        if let minUTC = schedule.legs.compactMap(\.depUTC).sorted().first {
            return minUTC
        } else if let minLocal = schedule.legs.map(\.depLocal).sorted().first {
            return minLocal
        } else {
            return schedule.label
        }
    }

    private func mergeAndSortSchedules(crew: [PayPeriodSchedule], bidpro: [PayPeriodSchedule]) -> [PayPeriodSchedule] {
        (crew + bidpro).sorted { lhs, rhs in
            let lhsKey = scheduleDisplaySortKey(lhs)
            let rhsKey = scheduleDisplaySortKey(rhs)
            if lhsKey == rhsKey {
                return lhs.label < rhs.label
            }
            return lhsKey < rhsKey
        }
    }

    private func mergeBidproSchedulesKeepingRecentPeriods(
        fetched: [PayPeriodSchedule],
        existing: [PayPeriodSchedule],
        keepPeriods: Int
    ) -> [PayPeriodSchedule] {
        guard keepPeriods > 0 else { return fetched }

        var byID: [String: PayPeriodSchedule] = [:]
        for schedule in existing {
            byID[schedule.id] = schedule
        }
        for schedule in fetched {
            byID[schedule.id] = schedule
        }

        let fetchedIDs = Set(fetched.map(\.id))
        let merged = Array(byID.values)
        let distinctOrders = Array(
            Set(merged.compactMap { payPeriodOrder(from: $0.id, fallbackLabel: $0.label) })
        ).sorted(by: >)
        let keptOrders = Set(distinctOrders.prefix(keepPeriods))

        return merged.filter { schedule in
            if fetchedIDs.contains(schedule.id) { return true }
            guard let order = payPeriodOrder(from: schedule.id, fallbackLabel: schedule.label) else {
                return false
            }
            return keptOrders.contains(order)
        }
    }

    private func payPeriodOrder(from id: String, fallbackLabel: String) -> Int? {
        parsePayPeriodOrder(id) ?? parsePayPeriodOrder(fallbackLabel)
    }

    private func parsePayPeriodOrder(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = cleaned.range(of: #"PP(\d{2})-(\d{2})"#, options: .regularExpression)
        guard let range else { return nil }
        let match = String(cleaned[range])
        let parts = match.replacingOccurrences(of: "PP", with: "").split(separator: "-")
        guard parts.count == 2,
              let yy = Int(parts[0]),
              let pp = Int(parts[1]) else {
            return nil
        }
        return yy * 100 + pp
    }

}

private struct AdminPolicy {
    let verificationHashes: Set<String>
}

private struct AdminPolicyRaw: Decodable {
    let adminVerificationHashes: [String]
}

#if DEBUG
extension AppViewModel {
    static func previewMock() -> AppViewModel {
        let vm = AppViewModel()
        vm.schedules = Self.previewSchedules
        vm.authStatus = .loggedIn
        return vm
    }

    /// Clears persisted session cookies for UI tests that need a deterministic logged-out state.
    /// Without this, stale Keychain cookies cause syncTapped() to try performSync instead of
    /// immediately showing the login sheet, causing waitForExistence to time out.
    func clearSessionCookiesForUITest() {
        sessionCookies = []
    }
}
#endif
