import Foundation
import CloudKit
import UIKit
import UserNotifications
import CryptoKit

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
    @Published var friendConnections: [FriendConnection] = []
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

    private let syncService: TripBoardSyncServiceProtocol
    private let authService: TripBoardAuthServiceProtocol
    private let cacheService: ScheduleCacheServiceProtocol
    private let notificationService: NextReportNotificationServiceProtocol
    private let crewAccessImportService: CrewAccessPDFImportServiceProtocol
    private let friendScheduleCloudKitService: FriendScheduleCloudKitServicing
    private let gemsVerificationCloudKitService: GEMSVerificationCloudKitServicing
    private let deviceScheduleCloudKitService: DeviceScheduleCloudKitServicing
    private let tzResolver: IATATimeZoneResolving
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
    private var isUploadingSharedSchedule = false
    private var needsSharedScheduleUpload = false
    private var pendingSharedScheduleUploadReason: String?
    private var isUploadingDeviceSchedule = false
    private var needsDeviceScheduleUpload = false
    private var pendingDeviceScheduleUploadReason: String?
    private var lastDeviceScheduleUploadFingerprint: String?
    private var foregroundObserver: NSObjectProtocol?
    private var lastDeviceScheduleFetchAt: Date?
    private var cachedDeviceID: String?

    private let notification48hKey = "notification_48h_enabled"
    private let notification24hKey = "notification_24h_enabled"
    private let notification12hKey = "notification_12h_enabled"
    private let friendConnectionsKey = "friend_connections_v1"
    private let scheduleSharingEnabledKey = "schedule_sharing_enabled_v1"
    private let seniorityRecordsKey = "pilot_seniority_records_v1"
    // Legacy keys/file names are kept so upgrades from pre-CloudKit verification builds can clean up local seniority data.
    private let legacySeniorityRecordsKey = "pilot_roster_records_v1"
    private let verifiedIdentityKey = "verified_identity_profile_v1"
    private let crewAccessLegImportReferenceTimesKey = "crewaccess_leg_import_reference_times_v1"
    private let logTenExportBacklogKey = "logten_export_backlog_v1"
    private let logTenExportedFingerprintsKey = "logten_exported_fingerprints_v1"
    private let seniorityFileName = "pilot_seniority_records_v1.json"
    private let legacySeniorityFileName = "pilot_roster_records_v1.json"
    private let localIdentityRecordNameKey = "local_identity_record_name_v1"
    private let deviceScheduleUploadFingerprintKey = "device_schedule_last_upload_fingerprint_v1"
    private let deviceScheduleFetchAtKey = "device_schedule_last_fetch_at_v1"
    private let deviceIDKey = "device_id_v1"
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
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) {
        self.syncService = syncService
        self.authService = authService
        self.cacheService = cacheService
        self.notificationService = notificationService
        self.crewAccessImportService = crewAccessImportService
        self.friendScheduleCloudKitService = friendScheduleCloudKitService
        self.gemsVerificationCloudKitService = gemsVerificationCloudKitService
        self.deviceScheduleCloudKitService = deviceScheduleCloudKitService
        self.tzResolver = tzResolver
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
        self.logTenExportBacklog = Self.loadLogTenExportBacklog(
            from: UserDefaults.standard,
            key: logTenExportBacklogKey
        )
        self.logTenExportedFingerprints = UserDefaults.standard.dictionary(forKey: logTenExportedFingerprintsKey) as? [String: String] ?? [:]
        self.authStatus = authService.isAuthenticated(url: nil, cookies: sessionCookies) ? .loggedIn : .loggedOut
        self.friendConnections = loadFriendConnections()
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
        self.cachedDeviceID = UserDefaults.standard.string(forKey: deviceIDKey)
        if !useCloudKitIdentity {
            self.currentCloudKitRecordName = localIdentityRecordName()
        }
        self.updateAdminStatus()
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
            if isUITest { return }
#endif
            await MainActor.run {
                self?.refreshCloudKitIdentity()
            }
            await self?.refreshNotificationAuthorizationStatus()
            await self?.rescheduleNotificationsIfAuthorized()
            await self?.applyCrewAccessRetentionPolicy()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.fetchDeviceScheduleIfNeeded(reason: "foreground") }
        }

#if DEBUG
        logNonFatal("Cache restore (v2): crew=\(cachedCrewAccessSchedules.count) bidpro=\(cachedBidproSchedules.count)")
#endif
        NSLog("[VM] init vm=%@", String(describing: ObjectIdentifier(self)))
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        NSLog("[VM] deinit vm=%@", String(describing: ObjectIdentifier(self)))
    }

    func handleIncomingAppDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "tripdatahub" else { return }
        let route = url.host?.lowercased() ?? url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard route == "import-crewaccess" else { return }
        NSLog("[Import] deepLink received url=%@", url.absoluteString)
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
                NSLog("[Import] appGroup handoff skipped (already consumed) file=%@", handoff.fileName)
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

            NSLog("[Import] appGroup handoff queued file=%@", handoff.fileName)
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
            .filter { $0.status == .pending }
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
        guard let verifiedIdentity else { return false }
        guard let currentCloudKitRecordName else { return false }
        return verifiedIdentity.cloudKitRecordName == currentCloudKitRecordName
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
        if let index = friendConnections.firstIndex(where: { $0.employeeID == employeeID }) {
            if friendConnections[index].status == .accepted {
                friendActionMessage = "Friend already linked: \(employeeID)"
                return
            }
        }

        do {
            let link = try await friendScheduleCloudKitService.requestFriend(
                myGEMSID: myGEMSID,
                friendGEMSID: employeeID
            )
            enableScheduleSharingForFriends()
            upsertFriendConnection(from: link)
            await uploadSharedScheduleIfNeeded(reason: "friend request")
            await refreshFriendSchedulesFromCloud()
            friendActionMessage = link.isAccepted
                ? "Friend linked: \(employeeID)"
                : "Request saved. Ask GEMS \(employeeID) to add your GEMS ID too."
        } catch {
            friendActionMessage = friendRequestErrorMessage(error)
            logNonFatal("Friend CloudKit request failed: \(error.localizedDescription)")
        }
    }

    private func upsertFriendConnection(from link: FriendScheduleCloudKitLink) {
        if let index = friendConnections.firstIndex(where: { $0.employeeID == link.friendGEMSID }) {
            friendConnections[index].status = link.isAccepted ? .accepted : .pending
            friendConnections[index].requestedAt = link.requestedAt ?? Date()
            if link.isAccepted {
                friendConnections[index].linkedAt = link.linkedAt ?? friendConnections[index].linkedAt ?? Date()
            }
        } else {
            friendConnections.append(
                FriendConnection(
                    employeeID: link.friendGEMSID,
                    status: link.isAccepted ? .accepted : .pending,
                    linkedAt: link.isAccepted ? (link.linkedAt ?? Date()) : nil
                )
            )
        }
        saveFriendConnections()
    }

    func cancelPendingFriendRequest(_ id: UUID) async {
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
            friendActionMessage = "Request canceled: \(connection.employeeID)"
        } catch {
            friendActionMessage = friendRequestErrorMessage(error)
            logNonFatal("Friend CloudKit cancel failed: \(error.localizedDescription)")
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

    func setScheduleSharingEnabled(_ enabled: Bool) {
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
        guard !isScheduleSharingEnabled else { return }
        isScheduleSharingEnabled = true
        UserDefaults.standard.set(true, forKey: scheduleSharingEnabledKey)
    }

    private func updateScheduleSharingAfterFriendListChange() {
        let hasAcceptedConnection = friendConnections.contains { $0.status == .accepted }
        let hasPendingConnection = friendConnections.contains { $0.status == .pending }
        let shouldShare = hasAcceptedConnection || (isScheduleSharingEnabled && hasPendingConnection)
        guard isScheduleSharingEnabled != shouldShare else { return }
        isScheduleSharingEnabled = shouldShare
        UserDefaults.standard.set(shouldShare, forKey: scheduleSharingEnabledKey)
        if !shouldShare {
            friendCloudKitSyncMessage = nil
        }
    }

    func handleSchedulesChangedForSharing() {
        guard isScheduleSharingEnabled else { return }
        Task { [weak self] in
            await self?.uploadSharedScheduleIfNeeded(reason: "schedule changed")
        }
    }

    func syncFriendCloudKit(reason: String = "manual") async {
        guard !isSyncingFriendCloudKit else { return }
        isSyncingFriendCloudKit = true
        defer { isSyncingFriendCloudKit = false }

        await uploadSharedScheduleIfNeeded(reason: reason)
        await refreshFriendSchedulesFromCloud()
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
            if needsSharedScheduleUpload {
                nextReason = pendingSharedScheduleUploadReason ?? "coalesced"
            }
        }
    }

    private func performSharedScheduleUploadIfNeeded(reason: String) async {
        guard isScheduleSharingEnabled else { return }
        guard isIdentityVerified,
              let verifiedIdentity,
              let currentCloudKitRecordName else {
            friendCloudKitSyncMessage = "Verify GEMS and iCloud before sharing schedules."
            return
        }
        let shareableSchedules = crewAccessSchedules
        guard !shareableSchedules.isEmpty else {
            friendCloudKitSyncMessage = "No CrewAccess schedule to share yet."
            logNonFatal("Friend CloudKit schedule upload skipped: no CrewAccess schedules (\(reason))")
            return
        }
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
        guard isIdentityVerified,
              let verifiedIdentity else {
            return
        }

        do {
            friendConnections = try await friendScheduleCloudKitService.refreshConnections(
                myGEMSID: verifiedIdentity.gemsID,
                connections: friendConnections
            )
            saveFriendConnections()
            updateScheduleSharingAfterFriendListChange()
            friendCloudKitSyncMessage = "Friend schedules updated."
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

            let remoteSchedules = snapshot.schedules
            try cacheService.save(ScheduleCacheSnapshotV2(
                crewAccessSchedules: remoteSchedules,
                bidproSchedules: bidproSchedules,
                lastSyncAt: lastSyncAt ?? Date(),
                migratedAt: nil
            ))
            crewAccessSchedules = remoteSchedules
            crewAccessLegImportReferenceTimes = preservedReferenceTimes
            schedules = mergeAndSortSchedules(crew: remoteSchedules, bidpro: bidproSchedules)
            lastDeviceScheduleFetchAt = snapshot.updatedAt
            UserDefaults.standard.set(snapshot.updatedAt, forKey: deviceScheduleFetchAtKey)

            await rescheduleNotificationsIfAuthorized()
            deviceSyncStatusMessage = "Schedule updated from device sync."
            logNonFatal("Device schedule fetched: \(reason) source=\(snapshot.source.rawValue) tripCount=\(remoteSchedules.count)")
        } catch {
            logNonFatal("Device schedule fetch failed: \(error.localizedDescription) reason=\(reason)")
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
            cloudKitIdentityMessage = "Sign into iCloud to verify or share schedules."
            currentCloudKitRecordName = nil
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
            NSLog("[Import] importCrewAccessPDFData skipped (pendingImport already set) file=%@", sourceFileName ?? "unknown")
            importInProgress = false
            return false
        }

        guard Self.claimPersistentFingerprint(fingerprint) else {
            NSLog("[Import] importCrewAccessPDFData skipped (cross-launch dedup) file=%@", sourceFileName ?? "unknown")
            importInProgress = false
            return false
        }
        NSLog(
            "[Import] importCrewAccessPDFData called file=%@ bytes=%d",
            sourceFileName ?? "unknown",
            data.count
        )
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
        NSLog(
            "[Import] pendingImport set id=%@ tripId=%@ errors=%d warnings=%d",
            pendingImport?.id.uuidString ?? "nil",
            draft.tripId,
            draft.errors.count,
            draft.warnings.count
        )

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
                NSLog("[Import] queueExternalOpenURL accepted key=%@", key)
                self.startExternalConsumerIfNeeded()
            } else {
                NSLog("[Import] queueExternalOpenURL skipped (duplicate) key=%@", key)
            }
        }
    }

    private func startExternalConsumerIfNeeded() {
        guard externalConsumerTask == nil else {
            NSLog("[Import] consumeExternalOpenURL skipped (already running)")
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
        NSLog("[Import] externalConsumer start")
    }

    private func externalConsumerLoop() async {
        while true {
            guard let nextItem = await externalOpenCoordinator.dequeueNext() else {
                pendingExternalOpenURL = nil
                NSLog("[Import] externalConsumer stop")
                break
            }
            let url = nextItem.url
            let key = nextItem.key

            let markedInFlight = await externalOpenCoordinator.markInFlight(key)
            if !markedInFlight {
                NSLog("[Import] consumeExternalOpenURL skipped (already running)")
                continue
            }

            var isSuccess = false
            NSLog("[Import] consumeExternalOpenURL begin key=%@", key)

            if pendingImport != nil {
                NSLog("[Import] consumeExternalOpenURL skipped (pending import exists)")
                crewAccessImportMessage = "Another import is waiting for review. Confirm or dismiss the current import first."
                hasQueuedImport = true
                await externalOpenCoordinator.finish(key: key, success: false)
                await externalOpenCoordinator.requeueFront(nextItem)
                pendingExternalOpenURL = nil
                NSLog("[Import] consumeExternalOpenURL done key=%@ ok=%@", key, String(isSuccess))
                break
            }

            guard url.isFileURL else {
                crewAccessImportMessage = "Import failed: shared item is not a file URL."
                await externalOpenCoordinator.finish(key: key, success: false)
                pendingExternalOpenURL = nil
                NSLog("[Import] consumeExternalOpenURL done key=%@ ok=%@", key, String(isSuccess))
                continue
            }

            do {
                let data = try await Task.detached(priority: .utility) {
                    try await Self.readExternalPDFDataWithFallback(from: url, timeoutSeconds: 3)
                }.value
                NSLog("[Import] coordinated read success bytes=%d", data.count)
                let sniff = Self.sniffPDFSignature(in: data)
                NSLog("[Import] sniffPDF=%@ header=%@", String(sniff.isPDF), sniff.header)
                guard sniff.isPDF else {
                    crewAccessImportMessage = "Selected file is not a PDF. Re-export using Zscaler Print and retry."
                    await externalOpenCoordinator.finish(key: key, success: false)
                    pendingExternalOpenURL = nil
                    NSLog("[Import] consumeExternalOpenURL done key=%@ ok=false (not PDF)", key)
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
            NSLog("[Import] consumeExternalOpenURL done key=%@ ok=%@", key, String(isSuccess))
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
            let replacing = crewAccessSchedules.contains(where: { $0.id == schedule.id })
            let jsonWriteContext = try persistCrewAccessJSON(json)
            do {
                try mergeImportedCrewAccessSchedule(schedule)
                await applyCrewAccessRetentionPolicy()
            } catch {
                do {
                    try rollbackCrewAccessJSONWrite(with: jsonWriteContext)
                } catch {
                    logNonFatal("Failed to rollback CrewAccess JSON after merge/cache error: \(error.localizedDescription)")
                }
                throw error
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
            Task { [weak self] in await self?.uploadDeviceScheduleIfNeeded(reason: "import confirmed") }
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

    private struct CrewAccessScheduleReference: Hashable {
        let id: String
        let label: String
        let pairings: Set<String>
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
                pairings: Set($0.legs.map(\.pairing))
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
                        return lhsDate > rhsDate
                    }
                    return lhs.fileName > rhs.fileName
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
                NSLog(
                    "[CrewAccessRetention] keptPeriods=%@ deletedFiles=%d",
                    retainedOrders.map(String.init).sorted().joined(separator: ","),
                    deletedFileCount
                )
            }
        } else {
            deletedFileCount = 0
        }

        await reconcileCrewAccessSchedulesWithImportFiles()
    }

    func reconcileCrewAccessSchedulesWithImportFiles() async {
        let rebuiltSchedules = await Task.detached(priority: .utility) {
            Self.loadCrewAccessSchedulesFromImportFiles()
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
    }

    func deleteCrewAccessImportFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard !isDeletingCrewAccessTrips else { return }

        isDeletingCrewAccessTrips = true
        crewAccessDeleteMessage = nil
        defer { isDeletingCrewAccessTrips = false }

        NSLog("[CrewAccessFileDelete] start files=%d", urls.count)
        let scheduleReferences = crewAccessSchedules.map {
            CrewAccessScheduleReference(
                id: $0.id,
                label: $0.label,
                pairings: Set($0.legs.map(\.pairing))
            )
        }

        let deletionResults = await Task.detached(priority: .utility) {
            Self.deleteCrewAccessImportFilesAndCollectMatches(
                targetURLs: urls,
                scheduleReferences: scheduleReferences
            )
        }.value

        let tripIDsToRemove = Set(deletionResults.compactMap(\.tripId))
        let beforePairings = Set(crewAccessSchedules.flatMap { $0.legs.map(\.pairing) })
        let schedulesBeforeDeletion = crewAccessSchedules
        if !tripIDsToRemove.isEmpty {
            crewAccessSchedules = crewAccessSchedules.compactMap { schedule in
                let remainingLegs = schedule.legs.filter { !tripIDsToRemove.contains($0.pairing) }
                guard !remainingLegs.isEmpty else { return nil }
                guard remainingLegs.count != schedule.legs.count else { return schedule }
                return PayPeriodSchedule(
                    id: schedule.id,
                    label: schedule.label,
                    tripCount: Set(remainingLegs.map(\.pairing)).count,
                    legCount: remainingLegs.count,
                    openTimeCount: schedule.openTimeCount,
                    updatedAt: Date(),
                    legs: remainingLegs,
                    openTimeTrips: schedule.openTimeTrips
                )
            }
        }
        let removedForLogTen = schedulesBeforeDeletion.compactMap { schedule -> PayPeriodSchedule? in
            let removedLegs = schedule.legs.filter { tripIDsToRemove.contains($0.pairing) }
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
            .intersection(tripIDsToRemove)
            .count
        pruneCrewAccessLegImportReferenceTimes()
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        NSLog("[CrewAccessFileDelete] removedTrips=%d", removedTripsCount)

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
            NSLog("[CrewAccessFileDelete] cacheSaved=true error=")
        } catch {
            logNonFatal("Failed to save schedule cache after CrewAccess file delete: \(error.localizedDescription)")
            NSLog("[CrewAccessFileDelete] cacheSaved=false error=%@", error.localizedDescription)
        }

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
        NSLog("[CrewAccessDelete] start ids=%@", ids.sorted().joined(separator: ","))

        let toDelete = crewAccessSchedules.filter { ids.contains($0.id) }
        guard !toDelete.isEmpty else {
            crewAccessDeleteMessage = "No matching CrewAccess trips were found."
            return
        }

        preservePastLogTenRecords(from: toDelete)
        crewAccessSchedules.removeAll { ids.contains($0.id) }
        pruneCrewAccessLegImportReferenceTimes()
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        NSLog("[CrewAccessDelete] removedSchedules=%d", toDelete.count)

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
            NSLog("[CrewAccessDelete] cacheSaved=true error=")
        } catch {
            logNonFatal("Failed to save schedule cache after CrewAccess delete: \(error.localizedDescription)")
            NSLog("[CrewAccessDelete] cacheSaved=false error=%@", error.localizedDescription)
        }

        let scheduleIDsToDelete = toDelete.map(\.id)
        let fileDeleteResult = await Task.detached(priority: .utility) {
            Self.deleteCrewAccessImportFilesBestEffort(scheduleIDs: scheduleIDsToDelete)
        }.value
        NSLog(
            "[CrewAccessDelete] detached file delete complete deleted=%d failures=%d",
            fileDeleteResult.deleted,
            fileDeleteResult.failures
        )
        if fileDeleteResult.failures == 0 {
            crewAccessDeleteMessage = "Deleted \(toDelete.count) trip(s)."
        } else {
            crewAccessDeleteMessage = "Deleted \(toDelete.count) trip(s). Some JSON files could not be removed."
        }
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

        NSLog("[LogTenExport] start candidates=%d unexported=%d", candidates.count, unexported.count)

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
            NSLog("[LogTenExport] finished rows=%d bytes=%d", csvRows.count, data.count)
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

        let importedPairings = Set(imported.legs.map(\.pairing))
        updatedCrewAccess = updatedCrewAccess.compactMap { schedule in
            let remainingLegs = schedule.legs.filter { !importedPairings.contains($0.pairing) }
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
        NSLog("[Import] consume read method=direct success bytes=%d", data.count)
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
                NSLog("[Import] coordinated read success bytes=%d", data.count)
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
                NSLog("[Import] consume read method=coordinator success bytes=%d", data.count)
                return data
            } catch ExternalOpenReadTimeoutError.timedOut {
                NSLog("[Import] consume read method=coordinator timeout")
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
            NSLog("[Import] cleanupInbox start path=%@", normalizedPath)
            do {
                try FileManager.default.removeItem(at: url)
                NSLog("[Import] cleanupInbox deleted path=%@", normalizedPath)
            } catch {
                NSLog("[Import] cleanupInbox failed path=%@ error=%@", normalizedPath, error.localizedDescription)
            }
            return
        }

        if let appGroupDir = Self.appGroupImportDirectoryURL()?.standardizedFileURL.path,
           normalizedPath.hasPrefix(appGroupDir + "/") || normalizedPath == appGroupDir {
            NSLog("[Import] cleanupAppGroup start path=%@", normalizedPath)
            do {
                try FileManager.default.removeItem(at: url)
                NSLog("[Import] cleanupAppGroup deleted path=%@", normalizedPath)
            } catch {
                NSLog("[Import] cleanupAppGroup failed path=%@ error=%@", normalizedPath, error.localizedDescription)
            }
            return
        }

        NSLog("[Import] cleanupExternalFile skip (not managed path) url=%@", url.absoluteString)
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
            NSLog("[Import] appGroup handoff decode failed error=%@", error.localizedDescription)
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
                NSLog("[CrewAccessRetention] failedFileDelete=%@ error=%@", url.path, error.localizedDescription)
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
        scheduleReferences: [CrewAccessScheduleReference]
    ) -> String? {
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
                NSLog(
                    "[CrewAccessFileDelete] decoded tripId=%@ infoDate=%@",
                    tripId,
                    tripDate ?? "nil"
                )
            } else {
                NSLog(
                    "[CrewAccessFileDelete] decodeFailed file=%@ error=%@",
                    fileName,
                    decodeErrorMessage ?? "missing tripId/tripInformationDate"
                )
            }

            let matchedIDs: [String]
            if let tripId {
                matchedIDs = scheduleReferences
                    .filter { ref in
                        ref.id == tripId || ref.label.contains(tripId) || ref.pairings.contains(tripId)
                    }
                    .map(\.id)
            } else {
                matchedIDs = []
            }

            do {
                try fm.removeItem(at: url)
                NSLog("[CrewAccessFileDelete] deletedFile=%@", url.path)
                return CrewAccessFileDeletionResult(
                    deleted: true,
                    tripId: tripId,
                    tripInformationDate: tripDate,
                    matchedScheduleIDs: matchedIDs
                )
            } catch {
                NSLog("[CrewAccessFileDelete] failedFileDelete=%@ error=%@", url.path, error.localizedDescription)
                return CrewAccessFileDeletionResult(
                    deleted: false,
                    tripId: tripId,
                    tripInformationDate: tripDate,
                    matchedScheduleIDs: matchedIDs
                )
            }
        }
    }

    private nonisolated static func deleteCrewAccessImportFilesBestEffort(scheduleIDs: [String]) -> (deleted: Int, failures: Int) {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return (0, 0)
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else {
            return (0, 0)
        }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return (0, 0)
        }

        var deletedCount = 0
        var failedCount = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let name = url.lastPathComponent
            let shouldDelete = scheduleIDs.contains { scheduleID in
                let safeID = scheduleID.replacingOccurrences(of: "/", with: "-")
                return name.hasPrefix("\(safeID)_") || name.contains(scheduleID) || name.contains(safeID)
            }
            guard shouldDelete else { continue }

            do {
                try fm.removeItem(at: url)
                deletedCount += 1
                NSLog("[CrewAccessDelete] deletedFile=%@", url.path)
            } catch {
                failedCount += 1
                NSLog("[CrewAccessDelete] failedFileDelete=%@ error=%@", url.path, error.localizedDescription)
            }
        }
        return (deletedCount, failedCount)
    }

    private struct CrewAccessJSONWriteContext {
        let finalURL: URL
        let backupURL: URL?
        let createdNewFile: Bool
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

        // Remove any existing files for the same Trip Id with a different date prefix
        let tripIDSuffix = "_\(safeTripID).json"
        if let existingFiles = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in existingFiles {
                let name = fileURL.lastPathComponent
                guard name.hasSuffix(tripIDSuffix), fileURL.path != finalURL.path else { continue }
                do {
                    try fm.removeItem(at: fileURL)
                    NSLog("[Import] Removed stale trip file: %@", name)
                } catch {
                    NSLog("[Import] Failed to remove stale trip file %@: %@", name, error.localizedDescription)
                }
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
                createdNewFile: !hadExistingFile
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
        guard let currentCloudKitRecordName else {
            identityActionMessage = "Apple identity is unavailable. Sign into iCloud first."
            return
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
        do {
            verificationResult = try await gemsVerificationCloudKitService.verify(
                gemsID: gemsID,
                dateOfBirth: normalizedDOB
            )
        } catch {
            identityActionMessage = "Verification database is unavailable: \(error.localizedDescription)"
            return
        }

        let isAdminBootstrap = verificationResult == nil && isAdminEligible(gemsID: gemsID, dob: normalizedDOB)
        guard verificationResult != nil || isAdminBootstrap || allowVerificationWithoutSeniorityDB else {
            identityActionMessage = "Verification failed. Check GEMS ID / DOB."
            return
        }
        let domicile = verificationResult?.domicile ?? DomicileSupport.defaultDomicile

        let verified = VerifiedIdentityProfile(
            cloudKitRecordName: currentCloudKitRecordName,
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
        do {
            try await gemsVerificationCloudKitService.recordVerifiedUser(gemsID: gemsID)
        } catch {
            logNonFatal("Failed to record verified app user: \(error.localizedDescription)")
        }
        updateAdminStatus()
        identityActionMessage = isAdminBootstrap
            ? "Verified as bootstrap admin. Upload GEMS verification records to CloudKit."
            : "Verified as GEMS \(gemsID) / \(domicile)."
        if isScheduleSharingEnabled {
            Task { [weak self] in
                await self?.syncFriendCloudKit(reason: "identity verified")
            }
        }
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

    func syncTapped() async {
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
            schedules: schedules,
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
        NSLog("[BidProSchedule] %@", message)
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
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: friendConnectionsKey) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([FriendConnection].self, from: data)
            let normalized = normalizeFriendConnections(decoded)
            if normalized != decoded,
               let migratedData = try? JSONEncoder().encode(normalized) {
                defaults.set(migratedData, forKey: friendConnectionsKey)
            }
            return normalized
        } catch {
            logNonFatal("Failed to decode friend connections: \(error.localizedDescription)")
            return []
        }
    }

    private func normalizeFriendConnections(_ connections: [FriendConnection]) -> [FriendConnection] {
        var normalized: [FriendConnection] = []
        for connection in connections {
            let employeeID = GEMSIDNormalizer.normalize(connection.employeeID)
            let migrated = FriendConnection(
                id: connection.id,
                employeeID: employeeID,
                status: connection.status,
                requestedAt: connection.requestedAt,
                linkedAt: connection.linkedAt,
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

    private func mergedFriendConnection(_ lhs: FriendConnection, _ rhs: FriendConnection) -> FriendConnection {
        let accepted = lhs.status == .accepted || rhs.status == .accepted
        return FriendConnection(
            id: lhs.id,
            employeeID: lhs.employeeID,
            status: accepted ? .accepted : .pending,
            requestedAt: min(lhs.requestedAt, rhs.requestedAt),
            linkedAt: lhs.linkedAt ?? rhs.linkedAt,
            sharedSchedules: lhs.sharedSchedules.isEmpty ? rhs.sharedSchedules : lhs.sharedSchedules,
            sharedTimelineCards: lhs.sharedTimelineCards.isEmpty ? rhs.sharedTimelineCards : lhs.sharedTimelineCards
        )
    }

    private func saveFriendConnections() {
        do {
            let data = try JSONEncoder().encode(friendConnections)
            UserDefaults.standard.set(data, forKey: friendConnectionsKey)
        } catch {
            logNonFatal("Failed to save friend connections: \(error.localizedDescription)")
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
                    try oldData.write(to: fileURL, options: .atomic)
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
                    try oldData.write(to: fileURL, options: .atomic)
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
        guard let data = UserDefaults.standard.data(forKey: verifiedIdentityKey) else { return nil }
        do {
            let profile = try JSONDecoder().decode(VerifiedIdentityProfile.self, from: data)
            let normalizedGEMS = GEMSIDNormalizer.normalize(profile.gemsID)
            guard normalizedGEMS != profile.gemsID else { return profile }
            let migrated = VerifiedIdentityProfile(
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
            saveVerifiedIdentity(migrated)
            return migrated
        } catch {
            logNonFatal("Failed to decode verified identity: \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: verifiedIdentityKey)
            return nil
        }
    }

    private func saveVerifiedIdentity(_ profile: VerifiedIdentityProfile) {
        do {
            let data = try JSONEncoder().encode(profile)
            UserDefaults.standard.set(data, forKey: verifiedIdentityKey)
        } catch {
            logNonFatal("Failed to save verified identity: \(error.localizedDescription)")
        }
    }

    private func clearVerifiedIdentity() {
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
        try data.write(to: fileURL, options: .atomic)
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
        let key: String
        if let minUTC = schedule.legs.compactMap(\.depUTC).sorted().first {
            key = minUTC
        } else if let minLocal = schedule.legs.map(\.depLocal).sorted().first {
            key = minLocal
        } else {
            key = schedule.label
        }
        logNonFatal("[Timeline] scheduleSortKey scheduleId=\(schedule.id) key=\(key)")
        return key
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
