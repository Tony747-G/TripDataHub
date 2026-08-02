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
    // Single source of truth shared with the share extension (compiled into both
    // targets via AppGroupImportHandoff.swift).
    static let appGroupIdentifier = AppGroupImportHandoff.appGroupIdentifier
    static let importDirectoryName = AppGroupImportHandoff.directoryName
    static let legacyManifestFileName = AppGroupImportHandoff.legacyManifestFileName
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
    static let openTimeDemoModeKey = "opentime_demo_mode_enabled_v1"
    static let lastTripSyncCompletedAtKey = "crewaccess_trip_sync_completed_at_v1"

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
    @Published var schedules: [PayPeriodSchedule] = [] {
        didSet {
            scheduleDataRevision &+= 1
        }
    }
    @Published var bidproSchedules: [PayPeriodSchedule] = []
    @Published var crewAccessSchedules: [PayPeriodSchedule] = []
    @Published var errorMessage: String?
    @Published var authStatus: AuthStatus = .unknown
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var notificationScheduleMessage: String?
    @Published var isTripBoardServerDown = false
    @Published var didLastFetchFail = false
    @Published var isOpenTimeDemoMode = UserDefaults.standard.bool(forKey: AppViewModel.openTimeDemoModeKey) {
        didSet {
            UserDefaults.standard.set(isOpenTimeDemoMode, forKey: Self.openTimeDemoModeKey)
        }
    }
    @Published var friendConnections: [FriendConnection] = [] {
        didSet {
            friendConnectionsRevision &+= 1
        }
    }
    @Published private(set) var scheduleDataRevision: Int = 0
    @Published private(set) var friendConnectionsRevision: Int = 0
    @Published var friendActionMessage: String?
    @Published var identityActionMessage: String?
    @Published var friendCloudKitSyncMessage: String?
    @Published var isScheduleSharingEnabled = false
    @Published private(set) var isSyncingFriendCloudKit = false

    /// Outcome of the last refresh, per normalized GEMS ID. Held here rather than on
    /// `FriendConnection` so the persisted Codable shape is untouched and 1.2.4 caches still decode.
    @Published private(set) var friendScheduleSyncOutcomes: [String: FriendScheduleSyncOutcome] = [:]
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
    @Published private(set) var isTripSyncing = false
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
    private var pendingProfileUploadTask: Task<Void, Never>?
    private var recentlyConsumedHandoffFileNames: Set<String> = []
    private var isConsumingAppGroupHandoff = false
    /// Import timestamps backing the LogTen export backlog. Readable internally so tests can
    /// assert it survives a rolled-back Timeline rebuild; only this type may mutate it.
    private(set) var crewAccessLegImportReferenceTimes: [String: Date] = [:]
    private var logTenExportBacklog: [LogTenExportBacklogRecord] = []
    private var logTenExportedFingerprints: [String: String] = [:]
    /// Trip key → when this device decided the trip was deleted. Durable across launches.
    private var deletedCrewAccessTripIntents: [String: Date] = [:]

    /// Trip keys for which a later fetch has *observed* every CloudKit import record carrying a
    /// `deletedAt`. Membership means the deletion is done; absence means it is still outstanding and
    /// `flushCrewAccessDeletionOutbox` re-sends it on the next sync.
    ///
    /// Deliberately set from an observation, never from a save returning success — a save can
    /// succeed against one of several records for the same trip (legacy plus current file name), so
    /// only a subsequent fetch proves the whole trip is tombstoned.
    ///
    /// Stored under its own key rather than by changing the shape of
    /// `deleted_crewaccess_trip_intents_v2`, so 1.2.4 can still read that dictionary and this build
    /// can still read 1.2.4's.
    private var observedCrewAccessTombstoneKeys: Set<String> = []

    /// Canonical fingerprints of every payload generation that was live in CloudKit when this
    /// device's deletion was still outstanding.
    ///
    /// This is the clock-free discriminator the whole design rests on. `CrewAccessTripJSON` carries
    /// `generatedAt`, re-stamped by the parser on every import, so the fingerprint of a payload is
    /// an import generation id — even re-importing the identical PDF yields a new one. A live
    /// record whose fingerprint is in this set is therefore the deleted generation coming back from
    /// a device that never saw the tombstone; anything else is a genuine new import.
    private var deletedCrewAccessPayloadFingerprints: [String: Set<String>] = [:]

    /// Narrow purpose: the user explicitly re-imported a trip on *this* device after deleting it,
    /// but before the tombstone was observed complete. In that window a new-looking fingerprint is
    /// ambiguous, so this local, unambiguous signal is needed to accept it.
    ///
    /// It is **not** part of the normal receive path — a device receiving someone else's re-import
    /// has no such flag, and decides on fingerprint generation alone. Written only by
    /// `mergeImportedCrewAccessSchedule`; automatic paths never set it.
    private var reimportedCrewAccessTripKeys: Set<String> = []

    /// Canonical payload fingerprints the user explicitly confirmed on *this* device and that
    /// CloudKit has not yet acknowledged as a live record.
    ///
    /// This is the single sanctioned exception to INV-008. A tombstone normally removes the local
    /// JSON unconditionally, but INV-006 makes that JSON the Timeline's source of truth, so
    /// applying a stale tombstone to a generation the user just confirmed empties the Timeline
    /// immediately after a successful import. A fingerprint identifies one import generation
    /// (`generatedAt` is re-stamped by the parser on every import), so protection never leaks to
    /// the generation that was actually deleted.
    ///
    /// Written only by `recordExplicitCrewAccessReimport`, i.e. only from `confirmPendingImport`.
    /// Automatic sync, launch recovery and local file scans never add to it. Entries are dropped
    /// as soon as a live remote record carries the same fingerprint (convergence reached).
    ///
    /// FIFO and capped: a stuck entry must not grow the defaults payload without bound.
    private var confirmedCrewAccessImportFingerprints: [String] = []
    private static let confirmedCrewAccessImportFingerprintLimit = 64

    /// Depth of the in-flight import transaction opened by `confirmPendingImport`.
    ///
    /// The transaction spans the local JSON commit through the CloudKit upload of that same
    /// generation. While it is open, foreground/startup CrewAccess sync must not fetch records,
    /// apply tombstones or reconcile, because every one of those steps can delete the JSON the
    /// transaction just wrote and leave the Timeline empty.
    private var crewAccessImportTransactionDepth = 0

    /// Sync reasons that arrived while an import transaction was open. Coalesced into one run so a
    /// deferred request is never lost and never replayed N times.
    private var deferredCrewAccessSyncReasons: [String] = []

    private var isUploadingSharedSchedule = false
    private var needsSharedScheduleUpload = false
    private var pendingSharedScheduleUploadReason: String?
    /// A schedule change that arrived while `isScheduleSharingEnabled` was false. Replayed by
    /// `flushPendingSharedScheduleChangeIfNeeded()` once sharing turns on.
    private var hasPendingSharedScheduleChange = false
    private var needsFriendCloudKitSync = false
    private var pendingFriendCloudKitSyncReason: String?
    private var deviceSyncActivityCount = 0
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
    /// The `modificationDate` of the most recent manual-event CloudKit record this device accepted.
    ///
    /// **Server clock only.** It is compared against `ManualEventCloudKitSnapshot.updatedAt`, which
    /// is the record's server-assigned modification date. Writing a local `Date()` here — as the
    /// delete paths used to — makes this device ignore every remote update until the server clock
    /// passes the local one, which silently breaks delete propagation in both directions. Local
    /// edits and deletes must never touch it; they are durable in `manualEventStore` instead.
    private var lastAcceptedManualEventRecordModifiedAt: Date?
    private var cachedDeviceID: String?
    private var isFetchingCrewAccessImports = false
    private var needsCrewAccessImportFetch = false
    private var pendingCrewAccessImportFetchReason: String?
    private var isSyncingCrewAccessDeviceData = false
    private var needsCrewAccessDeviceDataSync = false
    private var pendingCrewAccessDeviceDataSyncReason: String?
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
    private let deletedCrewAccessTripIntentsKey = "deleted_crewaccess_trip_intents_v2"
    private let observedCrewAccessTombstoneKeysKey = "crewaccess_tombstone_observed_v1"
    private let deletedCrewAccessPayloadFingerprintsKey = "crewaccess_deleted_payload_fingerprints_v1"
    private let reimportedCrewAccessTripKeysKey = "crewaccess_reimported_trip_keys_v1"
    private let confirmedCrewAccessImportFingerprintsKey = "crewaccess_confirmed_import_fingerprints_v1"
    private let logTenExportBacklogKey = "logten_export_backlog_v1"
    private let logTenExportedFingerprintsKey = "logten_exported_fingerprints_v1"
    private let seniorityFileName = "pilot_seniority_records_v1.json"
    private let legacySeniorityFileName = "pilot_roster_records_v1.json"
    private let localIdentityRecordNameKey = "local_identity_record_name_v1"
    /// Where this device keeps its CrewAccess import JSON. Injectable so a test can stand up two
    /// AppViewModels with genuinely separate local file state; production uses the shared default.
    private let crewAccessImportsDirectory: URL?

    /// "Now" for the CrewAccess retention window. Injectable so a test can pin which Bid Periods
    /// are retained instead of depending on the machine date and on where today happens to fall in
    /// the Bid Period table — both of which make retention behaviour drift over time. Production
    /// passes the wall clock.
    private let retentionReferenceDate: @Sendable () -> Date

    /// On-device diagnostics ring buffer. Records only; never influences sync behaviour.
    let diagnostics: SyncDiagnosticsLog

    /// Backing store for per-device sync bookkeeping (watermarks, upload fingerprints, device id).
    /// Injectable so a test can stand up two AppViewModels in one process that behave as two
    /// genuinely separate devices; production always passes `.standard`.
    private let syncStateDefaults: UserDefaults

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
        manualEventStore: ManualEventStoring = ManualEventStore(),
        syncStateDefaults: UserDefaults = .standard,
        crewAccessImportsDirectory: URL? = AppViewModel.defaultCrewAccessImportsDirectory(),
        retentionReferenceDate: @escaping @Sendable () -> Date = { Date() },
        diagnostics: SyncDiagnosticsLog? = nil
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
        self.syncStateDefaults = syncStateDefaults
        self.crewAccessImportsDirectory = crewAccessImportsDirectory
        self.retentionReferenceDate = retentionReferenceDate
        let resolvedDiagnostics = diagnostics ?? SyncDiagnosticsLog.shared
        self.diagnostics = resolvedDiagnostics
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
        self.deletedCrewAccessTripIntents = Self.loadDeletedCrewAccessTripIntents(
            from: syncStateDefaults,
            key: deletedCrewAccessTripIntentsKey,
            legacyKey: deletedCrewAccessTripKeysKey
        )
        // Absent on upgrade from 1.2.4, so every pre-existing deletion intent starts unobserved and
        // gets re-tombstoned on the first sync. That heals trips those builds deleted locally while
        // still holding an intent; it cannot heal ones whose intent 1.2.4 already cleared.
        self.observedCrewAccessTombstoneKeys = Set(
            syncStateDefaults.stringArray(forKey: observedCrewAccessTombstoneKeysKey) ?? []
        )
        let storedDeletedFingerprints = syncStateDefaults
            .dictionary(forKey: deletedCrewAccessPayloadFingerprintsKey) ?? [:]
        self.deletedCrewAccessPayloadFingerprints = storedDeletedFingerprints
            .compactMapValues { ($0 as? [String]).map(Set.init) }
        self.reimportedCrewAccessTripKeys = Set(
            syncStateDefaults.stringArray(forKey: reimportedCrewAccessTripKeysKey) ?? []
        )
        // Durable so a Confirm whose upload was interrupted by termination still overrides the
        // stale tombstone on the next launch instead of losing the trip.
        self.confirmedCrewAccessImportFingerprints = Array(
            (syncStateDefaults.stringArray(forKey: confirmedCrewAccessImportFingerprintsKey) ?? [])
                .suffix(Self.confirmedCrewAccessImportFingerprintLimit)
        )
        Self.saveDeletedCrewAccessTripIntents(
            self.deletedCrewAccessTripIntents,
            to: syncStateDefaults,
            key: deletedCrewAccessTripIntentsKey,
            legacyKey: deletedCrewAccessTripKeysKey
        )
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
        if useCloudKitIdentity, let loadedVerifiedIdentity {
            // Keep the locally verified account usable while CloudKit account status
            // is still resolving or is restricted by device management.
            self.currentCloudKitRecordName = loadedVerifiedIdentity.cloudKitRecordName
        }
        // Re-save to drop any legacy fields from older app builds (e.g. DOB).
        if let loadedVerifiedIdentity {
            saveVerifiedIdentity(loadedVerifiedIdentity)
        }
        backfillCrewAccessLegImportReferenceTimesIfNeeded()
        pruneCrewAccessLegImportReferenceTimes()
        self.lastDeviceScheduleUploadFingerprint = syncStateDefaults.string(forKey: deviceScheduleUploadFingerprintKey)
        self.lastDeviceScheduleFetchAt = syncStateDefaults.object(forKey: deviceScheduleFetchAtKey) as? Date
        self.lastManualEventUploadFingerprint = syncStateDefaults.string(forKey: manualEventUploadFingerprintKey)
        self.lastAcceptedManualEventRecordModifiedAt = syncStateDefaults.object(forKey: manualEventFetchAtKey) as? Date
        self.cachedDeviceID = syncStateDefaults.string(forKey: deviceIDKey)
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
            await self?.recoverCloudSyncAfterIdentityAvailable(reason: "startup")
            await self?.refreshNotificationAuthorizationStatus()
            await self?.rescheduleNotificationsIfAuthorized()
            await self?.syncProfileWithCloudKit()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.diagnostics.record(.appForegrounded, [:])
                await self?.recoverCloudSyncAfterIdentityAvailable(reason: "foreground")
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
        self.diagnostics.record(.appLaunched, [
            "localPersonal": String(self.manualPersonalEvents.count),
            "localOperational": String(self.manualOperationalEvents.count),
            "localTombstones": String(self.manualEventTombstones.count),
            "hasVerifiedIdentity": String(self.verifiedIdentity != nil),
            "hasRecordName": String(self.currentCloudKitRecordName != nil),
            "storedFingerprint": SyncDiagnosticsLog.shortFingerprint(self.lastManualEventUploadFingerprint)
        ])
        self.diagnostics.record(.localSnapshotLoaded, [
            "personal": String(self.manualPersonalEvents.count),
            "operational": String(self.manualOperationalEvents.count),
            "tombstones": String(self.manualEventTombstones.count)
        ])
        logger.info("[VM] init vm=\(String(describing: ObjectIdentifier(self)), privacy: .public)")
    }

    deinit {
        pendingProfileUploadTask?.cancel()
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

    private func upsertManualOperationalEvent(_ rawEvent: ManualOperationalEvent) throws {
        // Dropping the tombstone locally is not enough: other devices still hold it, and the merge
        // would discard this event again unless it is newer than that tombstone.
        let event = try rawEvent.withUpdatedAt(
            bumpedUpdatedAtIfTombstoned(id: rawEvent.id, updatedAt: rawEvent.updatedAt)
        )
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
        diagnostics.record(.manualEventSaved, [
            "layer": "operational",
            "event": SyncDiagnosticsLog.tag(event.id),
            "operational": String(snapshot.operationalEvents.count),
            "tombstones": String(snapshot.tombstones.count)
        ])
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual operational event saved") }
    }

    func deleteManualOperationalEvent(id: UUID) throws {
        var snapshot = ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: replacingTombstone(id: id, deletedAt: Date())
        )
        snapshot.operationalEvents.removeAll { $0.id == id }
        // Same contract as deleteManualPersonalEvent: persist the tombstone, leave the CloudKit
        // watermark alone.
        try manualEventStore.save(snapshot)
        manualOperationalEvents = snapshot.operationalEvents
        manualEventTombstones = snapshot.tombstones
        diagnostics.record(.manualEventDeleted, [
            "layer": "operational",
            "event": SyncDiagnosticsLog.tag(id),
            "operational": String(snapshot.operationalEvents.count),
            "tombstones": String(snapshot.tombstones.count)
        ])
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual operational event deleted") }
    }

    func saveManualPersonalEvent(_ event: ManualPersonalEvent) throws {
        try upsertManualPersonalEvent(event)
    }

    func updateManualPersonalEvent(_ event: ManualPersonalEvent) throws {
        try upsertManualPersonalEvent(event)
    }

    private func upsertManualPersonalEvent(_ rawEvent: ManualPersonalEvent) throws {
        // See upsertManualOperationalEvent: the re-created event must outrank any tombstone that
        // other devices still hold for this id.
        let event = try rawEvent.withUpdatedAt(
            bumpedUpdatedAtIfTombstoned(id: rawEvent.id, updatedAt: rawEvent.updatedAt)
        )
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
        diagnostics.record(.manualEventSaved, [
            "layer": "personal",
            "event": SyncDiagnosticsLog.tag(event.id),
            "personal": String(snapshot.personalEvents.count),
            "tombstones": String(snapshot.tombstones.count)
        ])
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual personal event saved") }
    }

    func deleteManualPersonalEvent(id: UUID) throws {
        var snapshot = ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: replacingTombstone(id: id, deletedAt: Date())
        )
        snapshot.personalEvents.removeAll { $0.id == id }
        // The tombstone lives in the persisted snapshot, so the delete survives termination and
        // is replayed by the next upload. Deliberately does NOT touch
        // lastAcceptedManualEventRecordModifiedAt — see the note on that property.
        try manualEventStore.save(snapshot)
        manualPersonalEvents = snapshot.personalEvents
        manualEventTombstones = snapshot.tombstones
        diagnostics.record(.manualEventDeleted, [
            "layer": "personal",
            "event": SyncDiagnosticsLog.tag(id),
            "personal": String(snapshot.personalEvents.count),
            "tombstones": String(snapshot.tombstones.count)
        ])
        Task { [weak self] in await self?.uploadManualEventsIfNeeded(reason: "manual personal event deleted") }
    }

    private func replacingTombstone(id: UUID, deletedAt: Date) -> [ManualEventTombstone] {
        var tombstones = manualEventTombstones.filter { $0.id != id }
        tombstones.append(ManualEventTombstone(id: id, deletedAt: tombstoneDate(for: id, notBefore: deletedAt)))
        return tombstones
    }

    /// Picks a `deletedAt` that beats the copy of the event this device can see.
    ///
    /// `mergeManualEventSnapshots` keeps an event when `tombstone.deletedAt < event.updatedAt`.
    /// Both timestamps are client clocks, so a device running behind could otherwise produce a
    /// tombstone that loses to the very event it is deleting. Anchoring just past the local copy
    /// fixes that case.
    ///
    /// **Limits.** This does not make deletion safe against arbitrary clock skew, and the scheme
    /// does not converge on CloudKit's server ordering:
    /// - The tombstone only outranks the revision of the event this device has. A device holding a
    ///   *newer* revision it has not yet published can still win the merge.
    /// - Deleting an event that a badly future-dated device created pushes the tombstone into the
    ///   future too, so a normally-clocked device cannot re-create that id until real time catches
    ///   up. `bumpedUpdatedAtIfTombstoned(...)` covers re-creation made through this app, but not a
    ///   re-creation arriving from another device that has not seen the tombstone.
    ///
    /// Closing these properly needs a server-assigned timestamp or a logical version counter per
    /// event id, which is a `TDHManualEventSnapshot` schema change — deliberately out of scope here.
    private func tombstoneDate(for id: UUID, notBefore proposed: Date) -> Date {
        let existingUpdatedAt = manualOperationalEvents.first { $0.id == id }?.updatedAt
            ?? manualPersonalEvents.first { $0.id == id }?.updatedAt
        guard let existingUpdatedAt, existingUpdatedAt >= proposed else { return proposed }
        return existingUpdatedAt.addingTimeInterval(0.001)
    }

    /// Re-creating a deleted id must win over the tombstone that removed it.
    ///
    /// The merge drops an event whose `updatedAt` is not newer than a tombstone for the same id, so
    /// re-adding an event with a plain `Date()` silently fails whenever the tombstone was anchored
    /// into the future by `tombstoneDate(for:notBefore:)`. Nudging past the tombstone keeps
    /// re-creation working within this app.
    private func bumpedUpdatedAtIfTombstoned(id: UUID, updatedAt: Date) -> Date {
        guard let tombstone = manualEventTombstones.first(where: { $0.id == id }),
              tombstone.deletedAt >= updatedAt else {
            return updatedAt
        }
        return tombstone.deletedAt.addingTimeInterval(0.001)
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

            let handoffs = await Task.detached(priority: .utility, operation: {
                Self.readPendingAppGroupHandoffs()
            }).value

            guard !handoffs.isEmpty else {
                // Nothing left to consume and nothing awaiting review: previously
                // queued PDFs have been imported (and deleted by cleanup), so the
                // session dedup set can reset instead of growing forever.
                if pendingImport == nil {
                    recentlyConsumedHandoffFileNames.removeAll()
                }
                // No pending share: opportunistically clear PDFs that were never
                // consumed so the App Group container does not grow unbounded.
                let protected = recentlyConsumedHandoffFileNames
                await Task.detached(priority: .utility, operation: {
                    Self.sweepStaleAppGroupImportFilesBestEffort(excludingFileNames: protected)
                }).value
                return
            }

            // The queue files are the authoritative list of shared PDFs: only files
            // the extension explicitly registered are imported — never other PDFs
            // that happen to sit in the directory. Each queue file is deleted
            // individually right after its entry is handled; a queue file written
            // concurrently by the extension is untouched and picked up on the next
            // consume, so a racing share can be delayed but never lost.
            for handoff in handoffs {
                defer {
                    if let queueFileURL = handoff.queueFileURL {
                        Task.detached(priority: .utility) {
                            try? FileManager.default.removeItem(at: queueFileURL)
                        }
                    }
                }

                if recentlyConsumedHandoffFileNames.contains(handoff.fileName) {
                    logger.info("[Import] appGroup handoff skipped (already consumed) file=\(handoff.fileName, privacy: .private)")
                    continue
                }

                let fileExists = await Task.detached(priority: .utility, operation: {
                    FileManager.default.fileExists(atPath: handoff.fileURL.path)
                }).value
                guard fileExists else {
                    crewAccessImportMessage = "Import failed: shared PDF is missing. Please share the PDF again."
                    logNonFatal("AppGroup handoff missing shared file: \(handoff.fileURL.path)")
                    continue
                }

                logger.info("[Import] appGroup handoff queued file=\(handoff.fileName, privacy: .private)")
                recentlyConsumedHandoffFileNames.insert(handoff.fileName)
                queueExternalOpenURL(handoff.fileURL)
            }

            // Never sweep a PDF that was queued for import (this pass or earlier in
            // the session) — the import pipeline reads it asynchronously.
            let protected = recentlyConsumedHandoffFileNames
            await Task.detached(priority: .utility, operation: {
                Self.sweepStaleAppGroupImportFilesBestEffort(excludingFileNames: protected)
            }).value
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
        return AppReviewDemo.isDemoGEMSID(gemsID)
    }

    var seniorityCount: Int { gemsVerificationRecordCount }

    var canAccessAdminTools: Bool {
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
            // The sync below republishes anyway; clearing the deferred flag keeps it from
            // queueing a second, redundant upload.
            hasPendingSharedScheduleChange = false
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
        flushPendingSharedScheduleChangeIfNeeded()
    }

    /// Republishes if a schedule change arrived while sharing was off.
    ///
    /// `refreshFriendSchedulesFromCloud` can turn sharing on part-way through a sync
    /// (`enableScheduleSharingForFriends`), and device sync can finish at any moment. Without
    /// this, a change that landed during the window when sharing was still off would be dropped
    /// by `handleSchedulesChangedForSharing` and never republished, leaving friends on the
    /// pre-sync schedule until something else happened to change it again.
    private func flushPendingSharedScheduleChangeIfNeeded() {
        guard hasPendingSharedScheduleChange else { return }
        guard isScheduleSharingEnabled else { return }
        hasPendingSharedScheduleChange = false
        logNonFatal("Replaying schedule change deferred while sharing was disabled")
        Task { [weak self] in
            await self?.uploadSharedScheduleIfNeeded(reason: "deferred schedule change")
        }
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

    /// The dot shown next to a friend's name. The single decision point shared by the iPhone and
    /// iPad friend lists — neither view is allowed to derive this itself.
    ///
    /// A friend whose account deletion has been confirmed is red. A friend we could not fetch is
    /// red. A friend fetched cleanly is green or amber depending only on whether they have
    /// anything operating tomorrow or later — an empty-but-fetched schedule is amber, never red.
    /// Seeds per-friend outcomes without going through a refresh. Used by tests to exercise each
    /// Green/Amber/Red branch directly; production only ever sets this from `refreshConnections`.
    func applyFriendScheduleSyncOutcomesForTesting(_ outcomes: [String: FriendScheduleSyncOutcome]) {
        friendScheduleSyncOutcomes = Dictionary(
            uniqueKeysWithValues: outcomes.map { (GEMSIDNormalizer.normalize($0.key), $0.value) }
        )
    }

    /// Deliberately does **not** branch on `friend.status`. Both friend lists iterate
    /// `acceptedFriendConnections`, which filters to `.accepted`, so a cancelled or unaccepted
    /// connection has already been removed from the list and any red condition keyed on status
    /// would be unreachable. The reachable red is a per-friend fetch failure: `refreshConnections`
    /// returns that friend's cached connection (still accepted, so the row stays on screen) plus a
    /// `.failed` outcome, which is what turns the dot red.
    func scheduleSyncHealth(
        for friend: FriendConnection,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> FriendScheduleSyncHealth {
        let key = GEMSIDNormalizer.normalize(friend.employeeID)
        // No recorded outcome means this friend has not been through a refresh in this session;
        // treat the cached data as trustworthy rather than flagging a failure that did not happen.
        let outcome = friendScheduleSyncOutcomes[key] ?? .succeeded
        return FriendScheduleHealthEvaluator.health(
            outcome: outcome,
            schedules: friend.sharedSchedules,
            now: now,
            calendar: calendar
        )
    }

    func handleSchedulesChangedForSharing() {
        guard !AppEnvironment.isAppStoreReviewMode else { return }
        guard !isAppReviewMockVerifiedIdentity else { return }
        guard isScheduleSharingEnabled else {
            // Do not drop the change: sharing may be enabled moments later by
            // enableScheduleSharingForFriends() during the same friend sync.
            hasPendingSharedScheduleChange = true
            return
        }
        hasPendingSharedScheduleChange = false
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
        if isSyncingFriendCloudKit {
            needsFriendCloudKitSync = true
            pendingFriendCloudKitSyncReason = reason
            logNonFatal("Friend CloudKit sync coalesced: \(reason)")
            return
        }

        isSyncingFriendCloudKit = true
        var nextReason: String? = reason
        defer {
            isSyncingFriendCloudKit = false
            needsFriendCloudKitSync = false
            pendingFriendCloudKitSyncReason = nil
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsFriendCloudKitSync = false
            pendingFriendCloudKitSyncReason = nil

            await refreshFriendSchedulesFromCloud()
            await uploadSharedScheduleIfNeeded(reason: currentReason)

            if needsFriendCloudKitSync {
                nextReason = pendingFriendCloudKitSyncReason ?? "coalesced"
            }
        }
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
        let importsDirectory = crewAccessImportsDirectory
        let shareableSchedules = schedules.isEmpty ? crewAccessSchedules : schedules
        let crewAccessTrips = await Self.loadCrewAccessTripJSONPayloadsFromImportFiles(
            directory: crewAccessImportsDirectory
        )
        // Enrich schedules with hotel names from local JSON before uploading —
        // friends see hotel names without needing to re-import PDFs.
        let enrichedSchedules = await Task.detached(priority: .utility) {
            Self.enrichSchedulesWithHotelNames(shareableSchedules, directory: importsDirectory)
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
            let refreshResult = try await friendScheduleCloudKitService.refreshConnections(
                myGEMSID: verifiedIdentity.gemsID,
                connections: currentConnections,
                friendResetAt: friendConnectionsResetAt()
            )
            friendScheduleSyncOutcomes = refreshResult.outcomes
            let nextConnections = currentFriendConnections(refreshResult.connections)
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

    private func beginDeviceSyncActivity() {
        deviceSyncActivityCount += 1
        isDeviceSyncing = true
    }

    private func endDeviceSyncActivity() {
        deviceSyncActivityCount = max(0, deviceSyncActivityCount - 1)
        isDeviceSyncing = deviceSyncActivityCount > 0
    }

    @discardableResult
    func uploadDeviceScheduleIfNeeded(reason: String) async -> Bool {
        // Coalescing: if an upload is already in flight, queue the request and return.
        // The in-flight upload will loop until no more pending requests remain (same pattern
        // as uploadSharedScheduleIfNeeded).
        if isUploadingDeviceSchedule {
            needsDeviceScheduleUpload = true
            pendingDeviceScheduleUploadReason = reason
            logNonFatal("Device schedule upload coalesced: \(reason)")
            return false
        }

        isUploadingDeviceSchedule = true
        beginDeviceSyncActivity()
        var nextReason: String? = reason
        var allSucceeded = true
        defer {
            isUploadingDeviceSchedule = false
            needsDeviceScheduleUpload = false
            pendingDeviceScheduleUploadReason = nil
            endDeviceSyncActivity()
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsDeviceScheduleUpload = false
            pendingDeviceScheduleUploadReason = nil
            let succeeded = await performDeviceScheduleUpload(reason: currentReason)
            allSucceeded = allSucceeded && succeeded
            if needsDeviceScheduleUpload {
                nextReason = pendingDeviceScheduleUploadReason ?? "coalesced"
            }
        }
        return allSucceeded
    }

    private func performDeviceScheduleUpload(reason: String) async -> Bool {
        guard isIdentityVerified,
              let verifiedIdentity,
              let currentCloudKitRecordName else { return false }

        let schedules = crewAccessSchedules
        // Upload even if empty: an empty snapshot signals "all trips deleted" to other devices.
        guard let fingerprint = Self.canonicalFingerprint(schedules) else { return false }
        guard fingerprint != lastDeviceScheduleUploadFingerprint else { return true }

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
            syncStateDefaults.set(fingerprint, forKey: deviceScheduleUploadFingerprintKey)
            deviceSyncStatusMessage = "Device schedule synced."
            logNonFatal("Device schedule uploaded: \(reason) tripCount=\(schedules.count)")
            return true
        } catch {
            deviceSyncStatusMessage = "Device sync upload failed."
            logNonFatal("Device schedule upload failed: \(error.localizedDescription) reason=\(reason)")
            return false
        }
    }

    /// Applies the legacy whole-Timeline snapshot.
    ///
    /// The authoritative source is the per-trip `CrewAccessImports` files; this snapshot only
    /// covers installs that cannot rebuild a Timeline from files. Because it replaces
    /// `crewAccessSchedules` wholesale and has no per-trip merge, it must never run against a
    /// Timeline that files already produced — that is enforced here rather than left to the
    /// caller, so the guarantee cannot be lost by a future call site.
    ///
    /// Deliberately does NOT compare `snapshot.updatedAt` (a CloudKit server modification date)
    /// against `schedule.updatedAt` (a local file mtime). Those are different clocks measuring
    /// different events; the empty-Timeline precondition replaces that comparison.
    @discardableResult
    func fetchLegacyDeviceScheduleFallbackIfNeeded(reason: String) async -> Bool {
        guard isIdentityVerified,
              let verifiedIdentity else { return false }

        guard crewAccessSchedules.isEmpty else {
            logNonFatal("Legacy device schedule fallback skipped, Timeline rebuilt from files: \(reason)")
            return true
        }

        beginDeviceSyncActivity()
        defer { endDeviceSyncActivity() }

        do {
            guard let snapshot = try await deviceScheduleCloudKitService.fetchDeviceSchedule(
                gemsID: verifiedIdentity.gemsID
            ) else { return true }

            // Gate 1: skip if we already accepted this exact snapshot.
            if let lastFetch = lastDeviceScheduleFetchAt, snapshot.updatedAt <= lastFetch { return true }

            // Gate 2: skip snapshots uploaded by this device — they mirror local state.
            let myDeviceID = getOrCreateDeviceID()
            if snapshot.deviceID == myDeviceID { return true }

            // LogTen backlog protection: preserve import reference times across schedule replacement.
            // Intentionally not pruned so past-leg entries survive for any future LogTen export.
            let preservedReferenceTimes = crewAccessLegImportReferenceTimes

            let deletedCrewAccessTripKeys = Set(deletedCrewAccessTripIntents.keys)
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
            syncStateDefaults.set(snapshot.updatedAt, forKey: deviceScheduleFetchAtKey)

            await rescheduleNotificationsIfAuthorized()
            deviceSyncStatusMessage = "Schedule updated from device sync."
            logNonFatal("Device schedule fetched: \(reason) source=\(snapshot.source.rawValue) tripCount=\(remoteSchedules.count)")
            return true
        } catch {
            deviceSyncStatusMessage = "Device sync download failed. Local schedule preserved."
            logNonFatal("Device schedule fetch failed: \(error.localizedDescription) reason=\(reason)")
            return false
        }
    }

    /// Re-sends every deletion this device has decided on but not yet seen tombstoned in CloudKit.
    ///
    /// Replaces the old behaviour of tombstoning only the files that happened to be deleted from
    /// this device's Documents directory. That derived the CloudKit work from local disk state, so
    /// a trip whose JSON was already pruned by the retention policy, or was never downloaded here,
    /// produced no tombstone at all — and the caller still reported success. Matching on trip key
    /// against the records actually in CloudKit covers those cases, and covers a trip stored under
    /// both a legacy and a current file name (every matching record is tombstoned, not just one).
    ///
    /// A key is only marked confirmed once no live record for it remains, so a failed tombstone
    /// upload, a background/terminated app, or an offline device all simply retry on the next sync.
    @discardableResult
    private func flushCrewAccessDeletionOutbox(
        records: [CrewAccessImportCloudKitRecord],
        domicile: String
    ) async -> Bool {
        guard !deletedCrewAccessTripIntents.isEmpty else { return true }

        // Group this account's records by trip key, keeping only keys we have a deletion for.
        var recordsByTripKey: [String: [CrewAccessImportCloudKitRecord]] = [:]
        for record in records {
            guard let tripKey = Self.crewAccessTripKey(fromCloudKitRecord: record, domicile: domicile),
                  deletedCrewAccessTripIntents[tripKey] != nil else { continue }
            recordsByTripKey[tripKey, default: []].append(record)
        }

        var allSucceeded = true

        for (tripKey, tripRecords) in recordsByTripKey {
            let live = tripRecords.filter { $0.deletedAt == nil }
            let hasObservedTombstone = observedCrewAccessTombstoneKeys.contains(tripKey)

            if !hasObservedTombstone {
                // State 1 — deletion not yet observed as complete.
                //
                // Everything live right now belongs to the generation being deleted, including
                // legacy or duplicate file names this device never held locally. Recording their
                // fingerprints is what lets state 2 recognise them later as stale re-uploads. A
                // fingerprint that merely looks new is NOT treated as a re-import here: at this
                // point the deletion has not finished propagating and "new-looking" is ambiguous.
                //
                // The one exception is an explicit re-import performed on *this* device between
                // the delete and the first observation — that intent is unambiguous and local.
                let explicitLocalReimport = reimportedCrewAccessTripKeys.contains(tripKey)
                if explicitLocalReimport,
                   live.contains(where: { record in
                       guard let fingerprint = Self.canonicalPayloadFingerprint(record.jsonData) else { return false }
                       return !(deletedCrewAccessPayloadFingerprints[tripKey]?.contains(fingerprint) ?? false)
                   }) {
                    cancelCrewAccessDeletion(tripKey: tripKey, reason: "explicit re-import on this device")
                    continue
                }

                for record in live {
                    // A payload that will not decode is never assumed to be a new generation;
                    // it stays a deletion target.
                    if let fingerprint = Self.canonicalPayloadFingerprint(record.jsonData) {
                        deletedCrewAccessPayloadFingerprints[tripKey, default: []].insert(fingerprint)
                    }
                }

                if live.isEmpty {
                    observedCrewAccessTombstoneKeys.insert(tripKey)
                    logNonFatal("CrewAccess deletion observed complete: \(tripKey)")
                } else {
                    // Every record for the trip must be tombstoned; a trip can exist under both a
                    // legacy and a current file name and tombstoning one leaves the other to
                    // resurrect it. Observation is deferred to the next fetch.
                    let tombstoned = await tombstoneCrewAccessImportFiles(fileNames: live.map(\.fileName))
                    if tombstoned {
                        logNonFatal("CrewAccess deletion outbox tombstoned \(live.count) record(s) for \(tripKey)")
                    } else {
                        allSucceeded = false
                        logNonFatal("CrewAccess deletion outbox retry pending for \(tripKey)")
                    }
                }
                continue
            }

            // State 2 — the deletion was observed complete, so any live record is new information.
            // Decided purely by payload generation: no device clock, no record.updatedAt, no mtime.
            guard !live.isEmpty else { continue }
            let deletedGenerations = deletedCrewAccessPayloadFingerprints[tripKey] ?? []
            let staleRecords = live.filter { record in
                guard let fingerprint = Self.canonicalPayloadFingerprint(record.jsonData) else {
                    return true // undecodable → safe side → still a deletion target
                }
                return deletedGenerations.contains(fingerprint)
            }

            if staleRecords.count == live.count {
                let tombstoned = await tombstoneCrewAccessImportFiles(fileNames: staleRecords.map(\.fileName))
                if !tombstoned { allSucceeded = false }
                logNonFatal("CrewAccess stale re-upload re-tombstoned: \(tripKey)")
            } else {
                // At least one record carries a generation that was never deleted — a genuine new
                // import, wherever it came from. `generatedAt` is re-stamped by the parser on every
                // import, so even the same PDF produces a new fingerprint.
                cancelCrewAccessDeletion(tripKey: tripKey, reason: "new import generation received")
            }
        }

        saveDeletedCrewAccessTripIntents()
        saveCrewAccessDeletionOutboxState()
        return allSucceeded
    }

    /// Records that the user explicitly confirmed an import for these trips.
    ///
    /// The **only** path allowed to cancel a deletion. Automatic sync, launch recovery and local
    /// file scans must never call it. The re-import outbox is persisted, so a failed upload of the
    /// new generation is retried on the next sync rather than being forgotten.
    /// - Parameter payloadFingerprint: canonical fingerprint of the generation being confirmed.
    ///   Supplying it is what lets the fetch path keep this generation's JSON when a stale remote
    ///   tombstone for the same file name arrives mid-import. Omit it only from tests that are
    ///   exercising the deletion outbox rather than the import path.
    func recordExplicitCrewAccessReimport(tripKeys: Set<String>, payloadFingerprint: String? = nil) {
        guard !tripKeys.isEmpty else { return }
        for tripKey in tripKeys {
            deletedCrewAccessTripIntents.removeValue(forKey: tripKey)
            reimportedCrewAccessTripKeys.insert(tripKey)
        }
        if let payloadFingerprint, !confirmedCrewAccessImportFingerprints.contains(payloadFingerprint) {
            confirmedCrewAccessImportFingerprints.append(payloadFingerprint)
            if confirmedCrewAccessImportFingerprints.count > Self.confirmedCrewAccessImportFingerprintLimit {
                confirmedCrewAccessImportFingerprints.removeFirst(
                    confirmedCrewAccessImportFingerprints.count - Self.confirmedCrewAccessImportFingerprintLimit
                )
            }
        }
        saveDeletedCrewAccessTripIntents()
        syncStateDefaults.set(Array(reimportedCrewAccessTripKeys), forKey: reimportedCrewAccessTripKeysKey)
        saveConfirmedCrewAccessImportFingerprints()
    }

    private func saveConfirmedCrewAccessImportFingerprints() {
        syncStateDefaults.set(
            confirmedCrewAccessImportFingerprints,
            forKey: confirmedCrewAccessImportFingerprintsKey
        )
    }

    /// True when this payload is a generation the user confirmed on this device and CloudKit has
    /// not yet acknowledged. The only condition under which a remote tombstone may be overridden.
    private func isConfirmedCrewAccessImportGeneration(_ jsonData: Data) -> Bool {
        guard !confirmedCrewAccessImportFingerprints.isEmpty,
              let fingerprint = Self.canonicalPayloadFingerprint(jsonData) else { return false }
        return confirmedCrewAccessImportFingerprints.contains(fingerprint)
    }

    /// Drops the override once CloudKit carries the generation live: the tombstone race is over and
    /// leaving the entry in place would let a *future* legitimate delete of this same generation be
    /// overridden.
    private func clearConfirmedCrewAccessImportGeneration(_ jsonData: Data) {
        guard !confirmedCrewAccessImportFingerprints.isEmpty,
              let fingerprint = Self.canonicalPayloadFingerprint(jsonData),
              confirmedCrewAccessImportFingerprints.contains(fingerprint) else { return }
        confirmedCrewAccessImportFingerprints.removeAll { $0 == fingerprint }
        saveConfirmedCrewAccessImportFingerprints()
    }

    // MARK: - Import Transaction

    /// True while `confirmPendingImport` is committing a generation locally and pushing it to
    /// CloudKit. Exposed for tests and for the sync entry points that must stand down.
    var isCrewAccessImportTransactionActive: Bool { crewAccessImportTransactionDepth > 0 }

    private func beginCrewAccessImportTransaction() {
        crewAccessImportTransactionDepth += 1
    }

    /// Closes the transaction and replays, exactly once, whatever sync was deferred while it ran.
    private func endCrewAccessImportTransaction() {
        guard crewAccessImportTransactionDepth > 0 else { return }
        crewAccessImportTransactionDepth -= 1
        guard crewAccessImportTransactionDepth == 0,
              !deferredCrewAccessSyncReasons.isEmpty else { return }
        let reason = deferredCrewAccessSyncReasons.joined(separator: "+")
        deferredCrewAccessSyncReasons = []
        Task { [weak self] in
            await self?.syncCrewAccessDeviceData(reason: "deferred after import (\(reason))")
        }
    }

    private func deferCrewAccessSyncDuringImportTransaction(reason: String) {
        if !deferredCrewAccessSyncReasons.contains(reason) {
            deferredCrewAccessSyncReasons.append(reason)
        }
        logNonFatal("CrewAccess sync deferred by in-flight import transaction: \(reason)")
    }

    /// Trip key for a CrewAccess trip id and information date, using this device's domicile.
    /// Exposed so callers (and tests) can address the outbox without duplicating the key format.
    func crewAccessTripKey(tripID: String, tripInformationDate: String?) -> String? {
        Self.crewAccessTripKey(
            tripID: tripID,
            tripInformationDate: tripInformationDate,
            fallbackDate: nil
        )
    }

    private func cancelCrewAccessDeletion(tripKey: String, reason: String) {
        deletedCrewAccessTripIntents.removeValue(forKey: tripKey)
        deletedCrewAccessPayloadFingerprints.removeValue(forKey: tripKey)
        observedCrewAccessTombstoneKeys.remove(tripKey)
        reimportedCrewAccessTripKeys.remove(tripKey)
        logNonFatal("CrewAccess deletion cancelled (\(reason)): \(tripKey)")
    }

    /// Clock-free identity for an import payload, used to tell one generation of a trip from
    /// another. Uses the shared canonical encoder so the value is stable across launches.
    private nonisolated static func canonicalPayloadFingerprint(_ jsonData: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: jsonData) else {
            return nil
        }
        return canonicalFingerprint(payload)
    }

    /// Fingerprints of specific import files, keyed by trip key. Read before a delete removes them.
    private nonisolated static func crewAccessPayloadFingerprints(at urls: [URL]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: data),
                  let tripKey = crewAccessTripKey(
                    tripID: payload.tripId,
                    tripInformationDate: payload.tripInformationDate,
                    fallbackDate: nil
                  ),
                  let fingerprint = canonicalFingerprint(payload) else { continue }
            result[tripKey, default: []].insert(fingerprint)
        }
        return result
    }

    /// Fingerprints of the local import files currently representing each trip key. Read before a
    /// delete removes them.
    private nonisolated static func crewAccessPayloadFingerprintsByTripKey(
        for tripKeys: [String],
        directory: URL?
    ) -> [String: Set<String>] {
        guard !tripKeys.isEmpty else { return [:] }
        let wanted = Set(tripKeys)
        var result: [String: Set<String>] = [:]
        for (payload, _) in loadCrewAccessTripJSONPayloadsFromImportFilesSync(directory: directory) {
            guard let tripKey = crewAccessTripKey(
                tripID: payload.tripId,
                tripInformationDate: payload.tripInformationDate,
                fallbackDate: nil
            ), wanted.contains(tripKey) else { continue }
            if let fingerprint = canonicalFingerprint(payload) {
                result[tripKey, default: []].insert(fingerprint)
            }
        }
        return result
    }

    private func saveCrewAccessDeletionOutboxState() {
        // The observation set and the deleted-payload fingerprints annotate deletion intents, so
        // they are pruned with them. The re-import outbox is a *separate* outbox — it exists
        // precisely for keys whose deletion intent has been cleared — and must never be pruned
        // against the deletion outbox.
        let liveKeys = Set(deletedCrewAccessTripIntents.keys)
        observedCrewAccessTombstoneKeys.formIntersection(liveKeys)
        deletedCrewAccessPayloadFingerprints = deletedCrewAccessPayloadFingerprints
            .filter { liveKeys.contains($0.key) }

        syncStateDefaults.set(Array(observedCrewAccessTombstoneKeys), forKey: observedCrewAccessTombstoneKeysKey)
        syncStateDefaults.set(
            deletedCrewAccessPayloadFingerprints.mapValues(Array.init),
            forKey: deletedCrewAccessPayloadFingerprintsKey
        )
        syncStateDefaults.set(Array(reimportedCrewAccessTripKeys), forKey: reimportedCrewAccessTripKeysKey)
    }


    /// Records a deletion in the outbox. Every delete entry point funnels through here so the same
    /// convergence guarantee applies whether the user deleted from the trip list or the file
    /// manager screen.
    private func enqueueCrewAccessDeletion(tripKeys: [String], deletedAt: Date, payloads: [String: Set<String>]) {
        guard !tripKeys.isEmpty else { return }
        for tripKey in tripKeys {
            deletedCrewAccessTripIntents[tripKey] = deletedAt
            observedCrewAccessTombstoneKeys.remove(tripKey)
            reimportedCrewAccessTripKeys.remove(tripKey)
            if let fingerprints = payloads[tripKey] {
                deletedCrewAccessPayloadFingerprints[tripKey, default: []].formUnion(fingerprints)
            }
        }
        saveDeletedCrewAccessTripIntents()
        saveCrewAccessDeletionOutboxState()
    }

    private func saveDeletedCrewAccessTripIntents() {
        Self.saveDeletedCrewAccessTripIntents(
            deletedCrewAccessTripIntents,
            to: syncStateDefaults,
            key: deletedCrewAccessTripIntentsKey,
            legacyKey: deletedCrewAccessTripKeysKey
        )
    }

    // MARK: - Manual Event Device Sync

    func uploadManualEventsIfNeeded(reason: String) async {
        if isUploadingManualEvents {
            needsManualEventUpload = true
            pendingManualEventUploadReason = reason
            diagnostics.record(.uploadAlreadyActive, ["reason": reason])
            diagnostics.record(.uploadCoalesced, ["reason": reason])
            logNonFatal("Manual event upload coalesced: \(reason)")
            return
        }

        isUploadingManualEvents = true
        beginDeviceSyncActivity()
        var nextReason: String? = reason
        defer {
            isUploadingManualEvents = false
            needsManualEventUpload = false
            pendingManualEventUploadReason = nil
            endDeviceSyncActivity()
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
        // Diagnostics only — the guards below are unchanged. Each early exit gets its own code so a
        // silent return can be told apart from an attempted upload on a device we cannot attach to.
        let snapshotForDiagnostics = currentManualEventSnapshot()
        diagnostics.record(.uploadRequested, [
            "reason": reason,
            "personal": String(snapshotForDiagnostics.personalEvents.count),
            "operational": String(snapshotForDiagnostics.operationalEvents.count),
            "tombstones": String(snapshotForDiagnostics.tombstones.count),
            "identityVerified": String(isIdentityVerified),
            "hasVerifiedIdentity": String(verifiedIdentity != nil),
            "hasRecordName": String(currentCloudKitRecordName != nil)
        ])
        if verifiedIdentity == nil {
            diagnostics.record(.verifiedIdentityMissing, ["reason": reason])
        }
        if currentCloudKitRecordName == nil {
            diagnostics.record(.recordNameMissing, ["reason": reason])
        }
        if !isIdentityVerified {
            diagnostics.record(.identityNotVerified, [
                "reason": reason,
                "hasVerifiedIdentity": String(verifiedIdentity != nil),
                "hasRecordName": String(currentCloudKitRecordName != nil)
            ])
        }

        guard isIdentityVerified,
              let verifiedIdentity,
              let currentCloudKitRecordName else { return }

        let snapshot = currentManualEventSnapshot()
        guard let fingerprint = Self.canonicalFingerprint(snapshot) else { return }
        if fingerprint == lastManualEventUploadFingerprint {
            diagnostics.record(.fingerprintUnchanged, [
                "reason": reason,
                "current": SyncDiagnosticsLog.shortFingerprint(fingerprint),
                "stored": SyncDiagnosticsLog.shortFingerprint(lastManualEventUploadFingerprint),
                "personal": String(snapshot.personalEvents.count),
                "tombstones": String(snapshot.tombstones.count)
            ])
        }
        guard fingerprint != lastManualEventUploadFingerprint else { return }

        diagnostics.record(.uploadStarted, [
            "reason": reason,
            "gems": SyncDiagnosticsLog.tag(verifiedIdentity.gemsID),
            "fingerprint": SyncDiagnosticsLog.shortFingerprint(fingerprint),
            "personal": String(snapshot.personalEvents.count),
            "tombstones": String(snapshot.tombstones.count)
        ])

        let myDeviceID = getOrCreateDeviceID()
        let source: DeviceScheduleSyncSource = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone

        do {
            let published = try await manualEventCloudKitService.uploadManualEvents(
                gemsID: verifiedIdentity.gemsID,
                cloudKitRecordName: currentCloudKitRecordName,
                snapshot: snapshot,
                deviceID: myDeviceID,
                source: source
            )

            // The service merges any concurrent write from another device into what it saves, so
            // `published` — not `snapshot` — is the state that now exists in CloudKit. Adopt it
            // locally and fingerprint that, otherwise the fingerprint would mark a pre-merge
            // snapshot as published and suppress the upload that would have re-sent our tombstones.
            if published != snapshot {
                try manualEventStore.save(published)
                manualOperationalEvents = published.operationalEvents
                manualPersonalEvents = published.personalEvents
                manualEventTombstones = published.tombstones
                logNonFatal("Manual events merged with concurrent remote write during upload: \(reason)")
            }
            let publishedFingerprint = Self.canonicalFingerprint(published) ?? fingerprint
            lastManualEventUploadFingerprint = publishedFingerprint
            syncStateDefaults.set(publishedFingerprint, forKey: manualEventUploadFingerprintKey)
            deviceSyncStatusMessage = "Manual events synced."
            diagnostics.record(.uploadSucceeded, [
                "reason": reason,
                "personal": String(published.personalEvents.count),
                "operational": String(published.operationalEvents.count),
                "tombstones": String(published.tombstones.count),
                "mergedRemote": String(published != snapshot),
                "fingerprint": SyncDiagnosticsLog.shortFingerprint(publishedFingerprint)
            ])
            logNonFatal("Manual events uploaded: \(reason) operational=\(published.operationalEvents.count) personal=\(published.personalEvents.count) tombstones=\(published.tombstones.count)")
        } catch {
            // Leave the fingerprint untouched so the next sync retries this exact state.
            deviceSyncStatusMessage = "Manual event sync upload failed."
            diagnostics.record(.uploadFailed, [
                "reason": reason,
                "error": Self.diagnosticErrorCode(error),
                "fingerprintUnchanged": SyncDiagnosticsLog.shortFingerprint(lastManualEventUploadFingerprint)
            ])
            logNonFatal("Manual event upload failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    func fetchManualEventsIfNeeded(reason: String) async {
        guard isIdentityVerified,
              let verifiedIdentity else { return }
        beginDeviceSyncActivity()
        defer { endDeviceSyncActivity() }

        let localBeforeFetch = currentManualEventSnapshot()
        diagnostics.record(.fetchStarted, [
            "reason": reason,
            "localPersonal": String(localBeforeFetch.personalEvents.count),
            "localTombstones": String(localBeforeFetch.tombstones.count)
        ])

        do {
            guard let remote = try await manualEventCloudKitService.fetchManualEvents(
                gemsID: verifiedIdentity.gemsID
            ) else {
                diagnostics.record(.fetchNoRemoteRecord, ["reason": reason])
                return
            }

            diagnostics.record(.fetchSucceeded, [
                "reason": reason,
                "remotePersonal": String(remote.manualEvents.personalEvents.count),
                "remoteOperational": String(remote.manualEvents.operationalEvents.count),
                "remoteTombstones": String(remote.manualEvents.tombstones.count),
                "remoteDevice": SyncDiagnosticsLog.tag(remote.deviceID),
                "myDevice": SyncDiagnosticsLog.tag(getOrCreateDeviceID())
            ])

            if let lastAccepted = lastAcceptedManualEventRecordModifiedAt, remote.updatedAt <= lastAccepted {
                diagnostics.record(.fetchSkippedWatermark, ["reason": reason])
                return
            }

            let myDeviceID = getOrCreateDeviceID()
            let localSnapshot = currentManualEventSnapshot()
            let merged = mergeManualEventSnapshots(local: localSnapshot, remote: remote.manualEvents)
            diagnostics.record(.snapshotsMerged, [
                "reason": reason,
                "beforePersonal": String(localSnapshot.personalEvents.count),
                "afterPersonal": String(merged.personalEvents.count),
                "beforeTombstones": String(localSnapshot.tombstones.count),
                "afterTombstones": String(merged.tombstones.count),
                // A local event present before the merge but absent after it was outranked by a
                // tombstone — the case that would silently drop an unsent event.
                "localDropped": Self.diagnosticDroppedTags(before: localSnapshot, after: merged)
            ])
            guard merged != localSnapshot else {
                lastAcceptedManualEventRecordModifiedAt = remote.updatedAt
                syncStateDefaults.set(remote.updatedAt, forKey: manualEventFetchAtKey)
                diagnostics.record(.mergeNoChange, ["reason": reason])
                return
            }

            try manualEventStore.save(merged)
            diagnostics.record(.mergedSnapshotPersisted, [
                "reason": reason,
                "personal": String(merged.personalEvents.count),
                "tombstones": String(merged.tombstones.count)
            ])
            manualOperationalEvents = merged.operationalEvents
            manualPersonalEvents = merged.personalEvents
            manualEventTombstones = merged.tombstones
            lastAcceptedManualEventRecordModifiedAt = remote.updatedAt
            syncStateDefaults.set(remote.updatedAt, forKey: manualEventFetchAtKey)
            deviceSyncStatusMessage = "Manual events updated from device sync."
            logNonFatal("Manual events fetched: \(reason) source=\(remote.source.rawValue) operational=\(merged.operationalEvents.count) personal=\(merged.personalEvents.count) tombstones=\(merged.tombstones.count)")

            if remote.deviceID != myDeviceID {
                await uploadManualEventsIfNeeded(reason: "manual event merge")
            }
        } catch {
            diagnostics.record(.fetchFailed, [
                "reason": reason,
                "error": Self.diagnosticErrorCode(error)
            ])
            logNonFatal("Manual event fetch failed: \(error.localizedDescription) reason=\(reason)")
        }
    }

    /// CloudKit error code without any user data, for the diagnostics buffer.
    private nonisolated static func diagnosticErrorCode(_ error: Error) -> String {
        if let ckError = error as? CKError {
            return "CKError.\(ckError.code.rawValue)"
        }
        let nsError = error as NSError
        return "\(nsError.domain).\(nsError.code)"
    }

    /// Tags of manual events that existed locally before a merge and were dropped by it.
    private nonisolated static func diagnosticDroppedTags(
        before: ManualEventStoreSnapshot,
        after: ManualEventStoreSnapshot
    ) -> String {
        let afterIDs = Set(after.personalEvents.map(\.id) + after.operationalEvents.map(\.id))
        let dropped = (before.personalEvents.map(\.id) + before.operationalEvents.map(\.id))
            .filter { !afterIDs.contains($0) }
        guard !dropped.isEmpty else { return "none" }
        return dropped.map { SyncDiagnosticsLog.tag($0) }.joined(separator: ",")
    }

    /// The shared on-device location for CrewAccess import JSON.
    nonisolated static func defaultCrewAccessImportsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CrewAccessImports", isDirectory: true)
    }

    /// The single place upload fingerprints are produced.
    ///
    /// Fingerprints are persisted and compared across launches, so the encoding must be stable for
    /// the same value — a bare `JSONEncoder()` gives no key-order guarantee, which would make a
    /// re-encode of identical content look like a change (or, worse, make a real change look
    /// unchanged is impossible, but the false-change case defeats the whole point of the gate and
    /// republishes on every launch). `.sortedKeys` pins the ordering; the default date strategy
    /// writes a `Double` that round-trips exactly.
    ///
    /// Both operands of any fingerprint comparison must come from this function.
    private nonisolated static func canonicalFingerprint<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func currentManualEventSnapshot() -> ManualEventStoreSnapshot {
        ManualEventStoreSnapshot(
            operationalEvents: manualOperationalEvents,
            personalEvents: manualPersonalEvents,
            tombstones: manualEventTombstones
        )
    }

    // MARK: - CrewAccess Import CloudKit Sync

    @discardableResult
    func fetchCrewAccessImportFilesIfNeeded(reason: String) async -> Bool {
        guard isIdentityVerified else { return false }
        // An open import transaction owns the local JSON directory until its new generation is on
        // CloudKit. Fetching here would apply the pre-import record set — including a tombstone for
        // the file just written — and reconcile would then rebuild an empty Timeline (INV-006).
        if isCrewAccessImportTransactionActive {
            deferCrewAccessSyncDuringImportTransaction(reason: reason)
            return false
        }
        if isFetchingCrewAccessImports {
            needsCrewAccessImportFetch = true
            pendingCrewAccessImportFetchReason = reason
            logNonFatal("CrewAccess import file fetch coalesced: \(reason)")
            return false
        }

        isFetchingCrewAccessImports = true
        var nextReason: String? = reason
        var allSucceeded = true
        defer {
            isFetchingCrewAccessImports = false
            needsCrewAccessImportFetch = false
            pendingCrewAccessImportFetchReason = nil
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsCrewAccessImportFetch = false
            pendingCrewAccessImportFetchReason = nil
            let succeeded = await performCrewAccessImportFileFetch(reason: currentReason)
            allSucceeded = allSucceeded && succeeded
            if needsCrewAccessImportFetch {
                nextReason = pendingCrewAccessImportFetchReason ?? "coalesced"
            }
        }
        return allSucceeded
    }

    private func performCrewAccessImportFileFetch(reason: String) async -> Bool {
        guard isIdentityVerified, let verifiedIdentity else { return false }

        let fm = FileManager.default
        guard let dir = crewAccessImportsDirectory else { return false }

        do {
            let records = try await crewAccessImportCloudKitService.fetchImportFiles(gemsID: verifiedIdentity.gemsID)
            let recordsByFileName = Dictionary(
                records.map { ($0.fileName, $0) },
                uniquingKeysWith: { current, candidate in
                    candidate.updatedAt > current.updatedAt ? candidate : current
                }
            )
            // Resolve deletion intents before applying records. In the observed state, a live
            // payload with a new generation cancels the deletion; the record loop below must see
            // that cancellation so it can persist the re-import during this same sync.
            var recoveryUploadsSucceeded = await flushCrewAccessDeletionOutbox(
                records: records,
                domicile: verifiedIdentity.domicile
            )
            var writtenCount = 0
            for record in records {
                let url = dir.appendingPathComponent(record.fileName)
                let localModifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let tripKey = Self.crewAccessTripKey(
                    fromCloudKitRecord: record,
                    domicile: verifiedIdentity.domicile
                )
                if record.deletedAt != nil {
                    // Tombstoned remotely: the local copy always goes. No mtime comparison —
                    // a sync-down rewrites files, so a "newer" local file proves nothing about a
                    // re-import. Deletion intents are owned by the outbox below and are never
                    // adjusted from here.
                    //
                    // The one exception: the local file *is* a generation the user confirmed on
                    // this device and CloudKit has not acknowledged yet. That is not a re-import
                    // inferred from the filesystem — it is an explicit local Confirm recorded by
                    // `recordExplicitCrewAccessReimport`. Deleting it would drop the source of
                    // truth for a trip the user just imported (INV-006) on the strength of a
                    // tombstone that describes the *previous* generation. The local-upload loop
                    // below republishes it, restoring the CloudKit record to live.
                    if let localData = try? Data(contentsOf: url),
                       isConfirmedCrewAccessImportGeneration(localData) {
                        logNonFatal("CrewAccess tombstone overridden by explicit local re-import: \(record.fileName)")
                        continue
                    }
                    try? fm.removeItem(at: url)
                    continue
                }
                // Live remote record carrying a confirmed generation: the race is over, so the
                // override is retired rather than left armed against a future delete.
                clearConfirmedCrewAccessImportGeneration(record.jsonData)
                // A live record for a trip this device deleted is left to the outbox, which decides
                // by payload generation whether it is a stale re-upload or a new import.
                if let tripKey, deletedCrewAccessTripIntents[tripKey] != nil {
                    if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
                    continue
                }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = url
                guard localModifiedAt == nil || record.updatedAt > localModifiedAt! else { continue }
                try? record.jsonData.write(to: fileURL)
                writtenCount += 1
            }

            // Retry uploads that were skipped while identity or CloudKit was unavailable.
            // Comparing payload bytes avoids rewriting every CloudKit record on each launch.
            if fm.fileExists(atPath: dir.path) {
                let localURLs = (try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in localURLs where url.pathExtension.lowercased() == "json" {
                    guard let data = try? Data(contentsOf: url),
                          let json = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: data)
                    else { continue }
                    let remote = recordsByFileName[url.lastPathComponent]

                    // Never re-upload over another device's tombstone. This loop used to fall
                    // through whenever `remote.deletedAt != nil`, which cleared the tombstone and
                    // resurrected the trip — and because a sync-down rewrites local files, their
                    // mtime is always fresh, so the device would resurrect it again every sync.
                    // A genuine re-import is represented by a deletion intent that is older than
                    // this file, not by the file simply existing.
                    // A tombstoned record is never republished by this automatic path. This loop
                    // used to fall through whenever `remote.deletedAt != nil`, which cleared the
                    // tombstone and resurrected the trip on every sync. No filesystem timestamp is
                    // consulted: mtime is refreshed by sync-down, and creation date is refreshed by
                    // download, restore, copy and reinstall, so neither proves a user re-imported.
                    // Only `confirmPendingImport` may cancel a deletion, via the re-import outbox.
                    if remote?.deletedAt != nil {
                        // Same single exception as the record loop above: an explicit Confirm on
                        // this device outranks a tombstone that describes the generation it
                        // replaced. Republishing here is what makes CloudKit converge on the new
                        // generation as a live record. Automatic paths still cannot reach this —
                        // the fingerprint set is only ever written by `confirmPendingImport`.
                        guard isConfirmedCrewAccessImportGeneration(data) else {
                            try? fm.removeItem(at: url)
                            continue
                        }
                        let uploaded = await uploadCrewAccessImportFile(at: url, json: json)
                        if uploaded { clearConfirmedCrewAccessImportGeneration(data) }
                        recoveryUploadsSucceeded = recoveryUploadsSucceeded && uploaded
                        logNonFatal("CrewAccess explicit re-import republished over tombstone: \(url.lastPathComponent)")
                        continue
                    }

                    if remote?.deletedAt == nil, remote?.jsonData == data {
                        continue
                    }
                    let uploaded = await uploadCrewAccessImportFile(at: url, json: json)
                    recoveryUploadsSucceeded = recoveryUploadsSucceeded && uploaded
                }
            }
            lastCrewAccessImportFetchAt = Date()
            UserDefaults.standard.set(lastCrewAccessImportFetchAt, forKey: crewAccessImportFetchAtKey)
            logNonFatal("CrewAccess import files fetched: \(reason) total=\(records.count) written=\(writtenCount)")
            return recoveryUploadsSucceeded
        } catch {
            logNonFatal("CrewAccess import file fetch failed: \(error.localizedDescription) reason=\(reason)")
            return false
        }
    }

    @discardableResult
    private func uploadCrewAccessImportFile(at url: URL, json: CrewAccessTripJSON) async -> Bool {
        let fileName = url.lastPathComponent
        guard isIdentityVerified, let verifiedIdentity else {
            logger.info("[CrewAccessImportUpload] skipped (identity not verified) file=\(fileName, privacy: .private)")
            return false
        }
        guard let jsonData = try? Data(contentsOf: url) else {
            logger.info("[CrewAccessImportUpload] skipped (cannot read file) path=\(url.path, privacy: .private)")
            return false
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
            return true
        } catch {
            logger.error("[CrewAccessImportUpload] FAILED file=\(fileName, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            logNonFatal("CrewAccess import file upload failed: \(error.localizedDescription) file=\(fileName)")
            return false
        }
    }

    @discardableResult
    private func tombstoneCrewAccessImportFiles(fileNames: [String]) async -> Bool {
        guard isIdentityVerified, let verifiedIdentity else { return false }
        var allSucceeded = true
        for fileName in fileNames {
            do {
                try await crewAccessImportCloudKitService.tombstoneImportFile(
                    gemsID: verifiedIdentity.gemsID,
                    fileName: fileName
                )
            } catch {
                allSucceeded = false
                logNonFatal("CrewAccess tombstone failed: \(error.localizedDescription) file=\(fileName)")
            }
        }
        return allSucceeded
    }

    /// Identifies this device for the "skip snapshots this device uploaded" gate.
    ///
    /// `identifierForVendor` is device+vendor scoped and, unlike a UUID in UserDefaults, is not
    /// carried into a restored backup — so an iPad restored from an iPhone backup no longer
    /// shares an identity and the two devices cannot mutually ignore each other's uploads.
    ///
    /// Two accepted consequences: the value changes if the user removes every app from this
    /// vendor and reinstalls, and it changes once for existing installs on the update that
    /// introduced this. In both cases the device stops recognising its own earlier snapshot and
    /// may re-apply it. That is bounded because `fetchLegacyDeviceScheduleFallbackIfNeeded`
    /// only applies a snapshot when the file-backed Timeline is empty, in which case re-applying
    /// this device's own last known Timeline is the desired outcome anyway.
    ///
    /// Returns nil before first unlock, so the legacy stored UUID remains as a fallback.
    private func getOrCreateDeviceID() -> String {
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            if cachedDeviceID != vendorID {
                syncStateDefaults.set(vendorID, forKey: deviceIDKey)
                cachedDeviceID = vendorID
            }
            return vendorID
        }
        if let existing = cachedDeviceID { return existing }
        let stored = syncStateDefaults.string(forKey: deviceIDKey)
        if let stored {
            cachedDeviceID = stored
            return stored
        }
        let newID = UUID().uuidString
        syncStateDefaults.set(newID, forKey: deviceIDKey)
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
                        self.logNonFatal("CloudKit identity confirmed for cached GEMS verification.")
                        Task { [weak self] in
                            await self?.recoverCloudSyncAfterIdentityAvailable(reason: "identity resolved")
                        }
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
            keepCachedIdentityAfterTransientCloudKitFailure(
                "iCloud access is restricted on this device. Using the locally verified GEMS identity."
            )
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

    /// Drives the exact startup-recovery sequence a relaunch performs. Exposed so tests can model a
    /// relaunch without depending on the init-time background Task, which is skipped under XCTest.
    func recoverCloudSyncForTesting(reason: String) async {
        await recoverCloudSyncAfterIdentityAvailable(reason: reason)
    }

    private func recoverCloudSyncAfterIdentityAvailable(reason: String) async {
        guard isIdentityVerified else {
            diagnostics.record(.identityUnavailable, [
                "reason": reason,
                "hasVerifiedIdentity": String(verifiedIdentity != nil),
                "hasRecordName": String(currentCloudKitRecordName != nil)
            ])
            return
        }

        let local = currentManualEventSnapshot()
        diagnostics.record(.startupRecoveryBegan, [
            "reason": reason,
            "localPersonal": String(local.personalEvents.count),
            "localTombstones": String(local.tombstones.count),
            "storedFingerprint": SyncDiagnosticsLog.shortFingerprint(lastManualEventUploadFingerprint)
        ])
        await syncCrewAccessDeviceData(reason: reason)
        await fetchManualEventsIfNeeded(reason: reason)
        await uploadManualEventsIfNeeded(reason: "\(reason) recovery")
        let after = currentManualEventSnapshot()
        diagnostics.record(.startupRecoveryEnded, [
            "reason": reason,
            "localPersonal": String(after.personalEvents.count),
            "localTombstones": String(after.tombstones.count),
            "storedFingerprint": SyncDiagnosticsLog.shortFingerprint(lastManualEventUploadFingerprint)
        ])
    }

    func syncCrewAccessDeviceData(reason: String) async {
        guard isIdentityVerified else { return }
        // Gated at the outermost sync entry point as well as at the fetch, so neither the fetch,
        // the tombstone application, nor `applyCrewAccessRetentionPolicy`'s reconcile can run
        // against a half-committed import. The request is replayed once the transaction closes.
        if isCrewAccessImportTransactionActive {
            deferCrewAccessSyncDuringImportTransaction(reason: reason)
            return
        }
        if isSyncingCrewAccessDeviceData {
            needsCrewAccessDeviceDataSync = true
            pendingCrewAccessDeviceDataSyncReason = reason
            logNonFatal("CrewAccess device sync coalesced: \(reason)")
            return
        }

        isSyncingCrewAccessDeviceData = true
        beginDeviceSyncActivity()
        isTripSyncing = true
        var nextReason: String? = reason
        defer {
            isSyncingCrewAccessDeviceData = false
            needsCrewAccessDeviceDataSync = false
            pendingCrewAccessDeviceDataSyncReason = nil
            endDeviceSyncActivity()
            isTripSyncing = false
        }

        while let currentReason = nextReason {
            nextReason = nil
            needsCrewAccessDeviceDataSync = false
            pendingCrewAccessDeviceDataSyncReason = nil

            let succeeded = await performCrewAccessDeviceSync(reason: currentReason)
            if succeeded {
                markTripSyncCompleted()
            }

            if needsCrewAccessDeviceDataSync {
                nextReason = pendingCrewAccessDeviceDataSyncReason ?? "coalesced"
            }
        }
    }

    private func performCrewAccessDeviceSync(reason: String) async -> Bool {
        // Download files first, rebuild local Timeline from the file source of truth,
        // then use the compact snapshot only as a legacy fallback when no import
        // files can rebuild the Timeline.
        let filesFetched = await fetchCrewAccessImportFilesIfNeeded(reason: reason)
        guard filesFetched else {
            deviceSyncStatusMessage = "Trip sync download failed. Local schedule preserved."
            logNonFatal("CrewAccess device sync stopped after import file fetch failure: \(reason)")
            return false
        }

        let schedulesBeforeReconcile = crewAccessSchedules
        // reconcile → pruneCrewAccessLegImportReferenceTimes() filters these down to the
        // rebuilt Timeline and persists the result.
        let referenceTimesBeforeReconcile = crewAccessLegImportReferenceTimes
        await applyCrewAccessRetentionPolicy()
        if crewAccessSchedules.isEmpty {
            // An empty rebuild means "no import files to rebuild from", not "the user deleted
            // every trip", so reconcile's prune of the LogTen reference times was not
            // authoritative. Put them back *before* the fallback runs: the fallback preserves
            // whatever map it finds on entry, so restoring afterwards would only cover the
            // failure path and still leave the export backlog wiped on success.
            restoreCrewAccessLegImportReferenceTimes(referenceTimesBeforeReconcile)

            let snapshotFetched = await fetchLegacyDeviceScheduleFallbackIfNeeded(reason: reason)
            guard snapshotFetched else {
                // Reconciliation may have cleared an in-memory/cache fallback before
                // the legacy snapshot fetch failed. Restore it so a network failure
                // never turns into local data loss.
                crewAccessSchedules = schedulesBeforeReconcile
                schedules = mergeAndSortSchedules(crew: schedulesBeforeReconcile, bidpro: bidproSchedules)
                try? cacheService.save(ScheduleCacheSnapshotV2(
                    crewAccessSchedules: schedulesBeforeReconcile,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: lastSyncAt ?? Date(),
                    migratedAt: nil
                ))
                deviceSyncStatusMessage = "Trip sync download failed. Cloud schedule not overwritten."
                logNonFatal("CrewAccess device sync stopped after snapshot fetch failure: \(reason)")
                return false
            }
        }
        let snapshotUploaded = await uploadDeviceScheduleIfNeeded(reason: "\(reason) recovery")
        return snapshotUploaded
    }

    private func markTripSyncCompleted() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastTripSyncCompletedAtKey)
        deviceSyncStatusMessage = "Trip sync completed."
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

            // Everything from here to the CloudKit upload is one Import transaction. Foreground and
            // startup CrewAccess sync stand down for its duration (see `syncCrewAccessDeviceData`),
            // because a fetch landing between the local commit and the upload applies the
            // pre-import record set — including a tombstone for the generation being replaced — and
            // reconcile then rebuilds a Timeline without the trip the user just confirmed.
            beginCrewAccessImportTransaction()
            var transactionHandedToUpload = false
            defer { if !transactionHandedToUpload { endCrewAccessImportTransaction() } }

            // Fail-closed rollback state, captured before the first write.
            let rollbackState = CrewAccessImportRollbackState(
                crewAccessSchedules: crewAccessSchedules,
                schedules: schedules,
                legImportReferenceTimes: crewAccessLegImportReferenceTimes,
                lastSyncAt: lastSyncAt
            )

            let jsonWriteContext = try persistCrewAccessJSON(json)
            // Stale same-trip files are moved aside rather than deleted, because they are removed
            // before verification runs and the rollback has to be able to undo that too.
            var staleStashes: [CrewAccessStaleJSONStash] = []
            do {
                try mergeImportedCrewAccessSchedule(
                    schedule,
                    payloadFingerprint: Self.canonicalFingerprint(json)
                )
                staleStashes = stashStaleCrewAccessJSONFilesBestEffort(
                    jsonWriteContext.staleSameBidPeriodTripURLs
                )
                await applyCrewAccessRetentionPolicy()
                // The reconcile above rebuilds the Timeline from the JSON directory. If the trip
                // the user just confirmed is not in the result, the import did not succeed no
                // matter how well the individual steps reported — persisting or uploading that
                // state would publish "old trip gone, new trip gone".
                try verifyCrewAccessImportCommit(json: json, jsonURL: jsonWriteContext.finalURL)
            } catch {
                do {
                    try rollbackCrewAccessJSONWrite(with: jsonWriteContext)
                } catch {
                    logNonFatal("Failed to rollback CrewAccess JSON after merge/cache error: \(error.localizedDescription)")
                }
                // Every file this commit removed comes back, not just `finalURL`.
                restoreStashedStaleCrewAccessJSONFiles(staleStashes)
                // The generation is no longer on disk, so its tombstone override must be
                // disarmed — an armed fingerprint with no file behind it would only make a
                // later legitimate delete harder to converge.
                if let fingerprint = Self.canonicalFingerprint(json) {
                    confirmedCrewAccessImportFingerprints.removeAll { $0 == fingerprint }
                    saveConfirmedCrewAccessImportFingerprints()
                }
                await restoreCrewAccessStateAfterFailedImport(rollbackState)
                throw error
            }
            // Verification passed, so the superseded copies are safe to discard.
            finalizeCrewAccessJSONWriteBestEffort(with: jsonWriteContext)
            discardStashedStaleCrewAccessJSONFilesBestEffort(staleStashes)

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
                let importsDirectory = crewAccessImportsDirectory
                if !overlapTripIDs.isEmpty {
                    _ = await Task.detached(priority: .utility) {
                        Self.deleteCrewAccessImportFilesBestEffort(
                            scheduleIDs: Array(resolvedOverlapIDs),
                            tripIDs: overlapTripIDs,
                            tripKeys: [],
                            directory: importsDirectory
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
            transactionHandedToUpload = true
            Task { [weak self] in
                guard let self else { return }
                // The transaction stays open across these uploads and is closed exactly once, in
                // this defer, so a deferred foreground sync resumes only after the new generation
                // is on CloudKit.
                defer { self.endCrewAccessImportTransaction() }

                // Source JSON first, schedule snapshot second. INV-006 makes the JSON the
                // recoverable source and the snapshot merely derived, so publishing the snapshot
                // first opens a window in which another device fetches a snapshot referencing a
                // trip whose JSON it cannot yet download — and, when the JSON upload then fails,
                // a window in which the only surviving artifact is the derived one. Uploading the
                // source first means every intermediate state another device can observe is one it
                // can fully rebuild from files.
                let importUploaded = await self.uploadCrewAccessImportFile(at: uploadURL, json: json)

                // Never publish a snapshot that lost the trip this import just confirmed. The
                // snapshot is a legacy fallback for devices with no files, so an empty or
                // trip-less one is exactly what would propagate the empty-Timeline bug.
                let scheduleUploaded: Bool
                if self.crewAccessSchedules.isEmpty {
                    scheduleUploaded = false
                    self.logNonFatal("Skipped device schedule upload after import: rebuilt schedule is empty")
                } else {
                    scheduleUploaded = await self.uploadDeviceScheduleIfNeeded(reason: "import confirmed")
                }

                var staleTombstoned = true
                if !staleFileNames.isEmpty {
                    staleTombstoned = await self.tombstoneCrewAccessImportFiles(fileNames: staleFileNames)
                }
                if scheduleUploaded && importUploaded && staleTombstoned {
                    self.markTripSyncCompleted()
                }
            }
        } catch let error as CrewAccessImportCommitError {
            // Reached only after the rollback above restored the pre-import state, so "no changes
            // were applied" is accurate and the user can retry the same Confirm.
            crewAccessImportMessage = "Import failed: \(error.userFacingDescription) No changes were applied."
            logNonFatal("CrewAccess confirm verification failed: \(error.diagnosticDescription)")
            importInProgress = false
        } catch {
            crewAccessImportMessage = "Import failed: unable to write CrewAccess JSON. No changes were applied."
            logNonFatal("CrewAccess confirm transaction failed: \(error.localizedDescription)")
            importInProgress = false
        }
    }

    // MARK: - Import Commit Verification

    /// Why a confirmed import was rejected after its local commit.
    ///
    /// These are not write errors — every individual step reported success. They mean the rebuilt
    /// Timeline does not contain the trip the user confirmed, which is the "Timeline went empty
    /// after Confirm" failure. Treating it as success is what previously let the state be cached
    /// and uploaded.
    enum CrewAccessImportCommitError: Error {
        /// The JSON the commit just wrote is not on disk any more.
        case sourceJSONMissing(fileName: String)
        /// The JSON is on disk but is not a readable payload for this trip.
        case sourceJSONUnreadable(fileName: String)
        /// Reconcile rebuilt the Timeline without the confirmed trip.
        case tripMissingFromRebuiltTimeline(tripID: String)
        /// Reconcile kept the trip but dropped legs of it (for example a GND segment).
        case legsMissingFromRebuiltTimeline(tripID: String, missing: Int, expected: Int)

        var userFacingDescription: String {
            switch self {
            case .sourceJSONMissing, .sourceJSONUnreadable:
                return "the imported trip file could not be re-read."
            case .tripMissingFromRebuiltTimeline, .legsMissingFromRebuiltTimeline:
                return "the trip did not appear in the rebuilt Timeline."
            }
        }

        var diagnosticDescription: String {
            switch self {
            case .sourceJSONMissing(let fileName):
                return "source JSON missing after commit: \(fileName)"
            case .sourceJSONUnreadable(let fileName):
                return "source JSON unreadable after commit: \(fileName)"
            case .tripMissingFromRebuiltTimeline(let tripID):
                return "trip absent from rebuilt Timeline: \(tripID)"
            case .legsMissingFromRebuiltTimeline(let tripID, let missing, let expected):
                return "trip \(tripID) rebuilt with \(expected - missing)/\(expected) legs"
            }
        }
    }

    /// Pre-import state, restored verbatim when the commit fails verification.
    private struct CrewAccessImportRollbackState {
        let crewAccessSchedules: [PayPeriodSchedule]
        let schedules: [PayPeriodSchedule]
        let legImportReferenceTimes: [String: Date]
        let lastSyncAt: Date?
    }

    /// Fail-closed check that the confirmed trip survived the JSON write and the reconcile.
    ///
    /// Checks the three things that can independently go wrong: the file is gone (a concurrent
    /// tombstone application), the file is unreadable (a truncated or clobbered write), or the
    /// reconcile produced a Timeline without the trip or without some of its legs.
    ///
    /// The expectation is derived from the JSON that was just written, not from the pending
    /// import's `parsedSchedule`. Reconcile reads that file and nothing else, so comparing against
    /// it is the only self-consistent check — comparing against the in-memory parse would flag
    /// harmless differences between the two representations as import failures.
    private func verifyCrewAccessImportCommit(json: CrewAccessTripJSON, jsonURL: URL) throws {
        let fileName = jsonURL.lastPathComponent
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL) else {
            throw CrewAccessImportCommitError.sourceJSONMissing(fileName: fileName)
        }
        guard let decoded = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: data),
              Self.normalizedCrewAccessTripID(decoded.tripId)
                == Self.normalizedCrewAccessTripID(json.tripId) else {
            throw CrewAccessImportCommitError.sourceJSONUnreadable(fileName: fileName)
        }

        // What reconcile should have produced from that file.
        guard let expected = Self.buildCrewAccessSchedule(from: decoded, modifiedAt: Date()) else {
            // The payload carries no buildable trip at all. Nothing to assert against, and the
            // pre-existing parse/preview gates own that case — do not turn it into a new failure.
            return
        }

        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        let expectedTripKeys = Self.crewAccessTripKeys(for: expected, domicile: domicile)
        let rebuiltTripKeys = Set(
            crewAccessSchedules.flatMap { Self.crewAccessTripKeys(for: $0, domicile: domicile) }
        )
        guard expectedTripKeys.isEmpty || !expectedTripKeys.isDisjoint(with: rebuiltTripKeys) else {
            throw CrewAccessImportCommitError.tripMissingFromRebuiltTimeline(tripID: decoded.tripId)
        }

        // Leg-level check, so a segment silently dropped by the rebuild is caught too: the
        // in-progress replacement case adds a GND leg, and a trip that came back with only its
        // flight legs is still a broken import.
        let rebuiltLegKeys = Set(
            crewAccessSchedules.flatMap { $0.legs.map(Self.logTenLegDedupKey(for:)) }
        )
        let expectedLegKeys = expected.legs
            .map(Self.logTenLegDedupKey(for:))
            .filter { !$0.hasPrefix("|") }
        let missingLegCount = expectedLegKeys.filter { !rebuiltLegKeys.contains($0) }.count
        guard missingLegCount == 0 else {
            throw CrewAccessImportCommitError.legsMissingFromRebuiltTimeline(
                tripID: decoded.tripId,
                missing: missingLegCount,
                expected: expectedLegKeys.count
            )
        }
    }

    /// Puts memory, the derived schedule list and the on-disk cache back to their pre-import
    /// values. The JSON write is rolled back separately by `rollbackCrewAccessJSONWrite`.
    private func restoreCrewAccessStateAfterFailedImport(
        _ state: CrewAccessImportRollbackState
    ) async {
        crewAccessSchedules = state.crewAccessSchedules
        schedules = state.schedules
        restoreCrewAccessLegImportReferenceTimes(state.legImportReferenceTimes)
        lastSyncAt = state.lastSyncAt
        // Reconcile already told the sharing layer about the broken state; correct it.
        handleSchedulesChangedForSharing()
        do {
            try cacheService.save(
                ScheduleCacheSnapshotV2(
                    crewAccessSchedules: state.crewAccessSchedules,
                    bidproSchedules: bidproSchedules,
                    lastSyncAt: state.lastSyncAt ?? Date(),
                    migratedAt: nil
                )
            )
        } catch {
            logNonFatal("Failed to restore schedule cache after failed CrewAccess import: \(error.localizedDescription)")
        }
        await rescheduleNotificationsIfAuthorized()
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
        let incomingOperationalInterval = Self.crewAccessOperationalInterval(
            startUTC: newStart,
            endUTC: newEnd
        )
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
            let existingStart = existing.legs
                .compactMap { LegConnectionTextBuilder.parseUTC($0.depUTC) }.min()
            let existingEnd = existing.legs
                .compactMap { LegConnectionTextBuilder.parseUTC($0.arrUTC) }.max()
            let existingOperationalInterval = Self.crewAccessOperationalInterval(
                startUTC: existingStart,
                endUTC: existingEnd
            )
            if let incomingInterval = incomingOperationalInterval,
               let existingInterval = existingOperationalInterval {
                if incomingInterval.start < existingInterval.end,
                   incomingInterval.end > existingInterval.start {
                    candidates.append(TripImportReplacementCandidate(
                        id: existing.id,
                        tripId: existingPairings.sorted().joined(separator: ", "),
                        pairings: existingPairings,
                        reason: .timeOverlap
                    ))
                }
                // UTC is authoritative. A shared domicile-local calendar day is not an
                // overlap when both operational intervals are known (for example, an
                // international trip arriving in the morning and another reporting later).
                continue
            }
            let existingDayKeys = Self.baseLocalDayKeys(
                startUTC: existingStart,
                endUTC: existingEnd,
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

    /// Approximate the duty footprint until exact duty-start/duty-end fields are persisted.
    /// The parser already treats UTC as authoritative; these buffers cover normal report and
    /// post-flight duties while keeping independent same-local-day trips separate.
    private nonisolated static func crewAccessOperationalInterval(
        startUTC: Date?,
        endUTC: Date?
    ) -> (start: Date, end: Date)? {
        guard let startUTC, let endUTC, startUTC <= endUTC else { return nil }
        return (
            start: startUTC.addingTimeInterval(-90 * 60),
            end: endUTC.addingTimeInterval(30 * 60)
        )
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
        let directory = crewAccessImportsDirectory
        return await Task.detached(priority: .utility) { () -> [CrewAccessImportFile] in
            let fm = FileManager.default
            guard let dir = directory else { return [] }
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
        let directory = crewAccessImportsDirectory
        let deletedFileCount: Int
        if let retainedOrders = retainedCrewAccessBidPeriodOrders() {
            deletedFileCount = await Task.detached(priority: .utility) {
                Self.deleteCrewAccessImportFilesOutsideRetainedBidPeriods(
                    retainedOrders: retainedOrders,
                    directory: directory
                )
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
        let directory = crewAccessImportsDirectory
        let deletedKeys = Set(deletedCrewAccessTripIntents.keys)
        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        var rebuiltSchedules = await Task.detached(priority: .utility) {
            Self.loadCrewAccessSchedulesFromImportFiles(directory: directory).filter { schedule in
                Self.crewAccessTripKeys(for: schedule, domicile: domicile).isDisjoint(with: deletedKeys)
            }
        }.value
        rebuiltSchedules = preservingAppReviewMockSchedules(in: rebuiltSchedules)

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

    private func preservingAppReviewMockSchedules(
        in rebuiltSchedules: [PayPeriodSchedule]
    ) -> [PayPeriodSchedule] {
        guard let gemsID = verifiedIdentity?.gemsID else { return rebuiltSchedules }
        guard let mockSchedules = Self.appReviewMockSchedules(
            for: gemsID,
            updatedAt: Self.appReviewMockUpdatedAt
        ) else {
            return rebuiltSchedules
        }
        return Self.replacingCachedAppReviewMockSchedules(
            in: rebuiltSchedules,
            with: mockSchedules
        )
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

        // Read the payload generations about to be removed, while the files still exist.
        let deletedPayloadFingerprints = await Task.detached(priority: .utility) {
            Self.crewAccessPayloadFingerprints(at: urls)
        }.value

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

        // Same convergence guarantee as deleting from the trip list: record the deletion in the
        // shared trip-key outbox, then let a full sync tombstone every matching CloudKit record.
        // Deleting from the file manager used to tombstone only the file names it happened to
        // remove, from an unstructured Task, with no durable retry.
        let deletedTripKeys = Array(Set(deletionResults.compactMap { result -> String? in
            guard let tripId = result.tripId else { return nil }
            return Self.crewAccessTripKey(
                tripID: tripId,
                tripInformationDate: result.tripInformationDate,
                fallbackDate: nil
            )
        }))
        if !deletedTripKeys.isEmpty {
            enqueueCrewAccessDeletion(
                tripKeys: deletedTripKeys,
                deletedAt: Date(),
                payloads: deletedPayloadFingerprints
            )
        }

        let deletedFileNames = zip(urls, deletionResults)
            .filter { $0.1.deleted }
            .map { $0.0.lastPathComponent }
        if !deletedFileNames.isEmpty {
            _ = await tombstoneCrewAccessImportFiles(fileNames: deletedFileNames)
        }
        await syncCrewAccessDeviceData(reason: "import file deleted")
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
        let deletionTime = Date()
        // Capture which payload generation is being deleted *before* the files are removed, so the
        // outbox can recognise that same generation coming back from a device that never saw the
        // tombstone. Both delete entry points funnel through enqueueCrewAccessDeletion.
        let deletedPayloads = Self.crewAccessPayloadFingerprintsByTripKey(
            for: tripKeysToDelete,
            directory: crewAccessImportsDirectory
        )
        enqueueCrewAccessDeletion(
            tripKeys: tripKeysToDelete,
            deletedAt: deletionTime,
            payloads: deletedPayloads
        )
        let importsDirectory = crewAccessImportsDirectory
        let fileDeleteResult = await Task.detached(priority: .utility) {
            Self.deleteCrewAccessImportFilesBestEffort(
                scheduleIDs: scheduleIDsToDelete,
                tripIDs: Array(Set(toDelete.flatMap { $0.legs.map(\.pairing) })),
                tripKeys: tripKeysToDelete,
                directory: importsDirectory
            )
        }.value
        logger.info("[CrewAccessDelete] detached file delete complete deleted=\(fileDeleteResult.deleted, privacy: .public) failures=\(fileDeleteResult.failures, privacy: .public)")
        if fileDeleteResult.failures == 0 {
            crewAccessDeleteMessage = "Deleted \(toDelete.count) trip(s)."
        } else {
            crewAccessDeleteMessage = "Deleted \(toDelete.count) trip(s). Some JSON files could not be removed."
        }
        // Deliberately does NOT stamp lastDeviceScheduleFetchAt with `deletionTime`. That watermark
        // is compared against the snapshot record's server modification date; writing a client
        // Date() into it made this device ignore later remote snapshots.

        // Best effort immediate tombstone of what we could see locally. Success is not required and
        // is not treated as completion — the outbox below is the guarantee.
        if !fileDeleteResult.deletedFileNames.isEmpty {
            _ = await tombstoneCrewAccessImportFiles(fileNames: fileDeleteResult.deletedFileNames)
        }
        await rescheduleNotificationsIfAuthorized()

        // Structured, not a detached Task: a full sync reconciles the outbox against the records
        // actually in CloudKit, tombstones every remaining one, and only then reports completion.
        // Anything still outstanding stays in the outbox and is retried on the next sync.
        await syncCrewAccessDeviceData(reason: "trip deleted")
    }

    func prepareCrewAccessTripJSONExport(for schedule: PayPeriodSchedule) async throws -> TripJSONExportOutput {
        let directory = crewAccessImportsDirectory
        let profile = ProfileSnapshot.loadFromLocalStorage()
        let identity = verifiedIdentity
        let ownerSource = TripJSONExportOwnerSource(
            profileName: profile.displayName,
            profileGivenName: UserDefaults.standard.string(forKey: ProfileStorageKeys.givenName) ?? "",
            profileFamilyName: UserDefaults.standard.string(forKey: ProfileStorageKeys.familyName) ?? "",
            profileGEMS: profile.gemsID,
            profileBase: profile.base,
            profileFleet: profile.fleet,
            profilePosition: profile.position,
            verifiedName: identity?.name ?? "",
            verifiedGEMS: identity?.gemsID ?? "",
            verifiedBase: identity?.domicile ?? "",
            verifiedFleet: identity?.equipment ?? "",
            verifiedPosition: identity?.seat ?? ""
        )
        let generator = TripJSONExportService.generator()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let candidates = Self.loadCrewAccessTripJSONPayloadsFromImportFilesSync(
                    directory: directory
                ).map(\.payload)
                guard let payload = TripJSONExportService.payload(for: schedule, candidates: candidates) else {
                    throw TripJSONExportError.tripDataUnavailable
                }
                let output = try TripJSONExportService.makeTemporaryFile(
                    for: schedule,
                    payload: payload,
                    ownerSource: ownerSource,
                    generator: generator
                )
                return (output, payload.tripId)
            }.value
            let (output, tripID) = result
            logger.info("[TripJSONExport] ready trip=\(tripID, privacy: .private) file=\(output.url.lastPathComponent, privacy: .public)")
            return output
        } catch {
            logger.error("[TripJSONExport] failed schedule=\(schedule.id, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func prepareBidPeriodScheduleJSONExport(
        scheduleID: String,
        pairing: String
    ) async throws -> TripJSONExportOutput {
        guard let selectedSchedule = crewAccessSchedules.first(where: { $0.id == scheduleID }) else {
            throw BidPeriodScheduleExportError.selectedTripUnavailable
        }
        let normalizedPairing = pairing.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let selectedTripLegs = selectedSchedule.legs.filter {
            $0.pairing.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedPairing
        }
        guard !selectedTripLegs.isEmpty else {
            throw BidPeriodScheduleExportError.selectedTripUnavailable
        }
        guard let firstDeparture = selectedTripLegs
            .compactMap({ LegConnectionTextBuilder.parseUTC($0.depUTC) })
            .min() else {
            throw BidPeriodScheduleExportError.selectedTripDepartureUnavailable
        }

        let selectedCrewBase = OperationalSettings.selectedCrewBase()
        let domicile = selectedCrewBase.rawValue
        guard let resolvedBidPeriod = bidPeriod(for: firstDeparture, domicile: domicile) else {
            throw BidPeriodScheduleExportError.assignedBidPeriodUnavailable
        }

        return try await prepareBidPeriodScheduleJSONExport(
            for: resolvedBidPeriod,
            domicile: domicile
        )
    }

    func prepareBidPeriodScheduleJSONExport(
        bidPeriodID: String
    ) async throws -> TripJSONExportOutput {
        let domicile = OperationalSettings.selectedCrewBase().rawValue
        guard let resolvedBidPeriod = bidPeriod(
            identifier: bidPeriodID,
            domicile: domicile
        ) else {
            throw BidPeriodScheduleExportError.assignedBidPeriodUnavailable
        }
        return try await prepareBidPeriodScheduleJSONExport(
            for: resolvedBidPeriod,
            domicile: domicile
        )
    }

    private func prepareBidPeriodScheduleJSONExport(
        for resolvedBidPeriod: CalendarBidPeriod,
        domicile: String
    ) async throws -> TripJSONExportOutput {
        let profile = ProfileSnapshot.loadFromLocalStorage()
        let identity = verifiedIdentity
        let canonicalGEMS = GEMSIDNormalizer.normalize(
            profile.gemsID.isEmpty ? (identity?.gemsID ?? "") : profile.gemsID
        )
        let ownSeniorityRecord = seniorityRecords.first {
            GEMSIDNormalizer.normalize($0.gemsID) == canonicalGEMS && !canonicalGEMS.isEmpty
        }
        let owner = BidPeriodExportOwnerInput(
            profileName: profile.displayName,
            profileGEMS: profile.gemsID,
            profileFleet: profile.fleet,
            profilePosition: profile.position,
            verifiedName: identity?.name ?? "",
            verifiedGEMS: identity?.gemsID ?? "",
            verifiedEquipment: identity?.equipment ?? "",
            verifiedSeat: identity?.seat ?? "",
            verifiedDateOfHire: identity?.dateOfHire ?? ownSeniorityRecord?.dateOfHire ?? "",
            seniorityNumber: ownSeniorityRecord?.seniorityNumber ?? ""
        )
        let qualification = PilotQualification(
            rawValue: UserDefaults.standard.string(forKey: "pilot_qualification") ?? ""
        ) ?? .captain
        let schedules = crewAccessSchedules
        let operationalEvents = manualOperationalEvents
        let personalEvents = manualPersonalEvents
        let generator = TripJSONExportService.generator()
        let directory = crewAccessImportsDirectory
        let payloads = await Task.detached(priority: .userInitiated) {
            Self.loadCrewAccessTripJSONPayloadsFromImportFilesSync(directory: directory).map(\.payload)
        }.value

        let input = BidPeriodScheduleExportInput(
            bidPeriod: resolvedBidPeriod,
            domicile: domicile,
            owner: owner,
            schedules: schedules,
            crewAccessPayloads: payloads,
            manualOperationalEvents: operationalEvents,
            manualPersonalEvents: personalEvents,
            pilotQualification: qualification,
            faaMedicalExpiryDate: profile.faaMedicalExpiryDate,
            passportExpiryDate: profile.passportExpiryDate,
            chinaVisaExpiryDate: profile.chinaVisaExpiryDate,
            generator: generator,
            exportedAt: Date()
        )

        do {
            let output = try BidPeriodScheduleExportService.makeTemporaryFile(input: input)
            logger.info("[BidPeriodJSONExport] ready file=\(output.url.lastPathComponent, privacy: .public)")
            return output
        } catch {
            logger.error("[BidPeriodJSONExport] failed")
            throw error
        }
    }

    func displaySchedules(filter: TimelineSourceFilter) -> [PayPeriodSchedule] {
        switch filter {
        case .crewAccess:
            return crewAccessSchedules
        case .tripBoard:
            return bidproSchedules
        }
    }

    var openTimeDisplaySchedules: [PayPeriodSchedule] {
        isOpenTimeDemoMode ? Self.openTimeDemoSchedules : schedules
    }

    func refreshOpenTimeDemoData() {
        guard isOpenTimeDemoMode else { return }
        lastSyncAt = Date()
        errorMessage = nil
        didLastFetchFail = false
        isTripBoardServerDown = false
        isShowingLoginSheet = false
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

    private func mergeImportedCrewAccessSchedule(
        _ imported: PayPeriodSchedule,
        payloadFingerprint: String?
    ) throws {
        var updatedCrewAccess = crewAccessSchedules
        let importConfirmedAt = Date()
        for leg in imported.legs {
            let key = Self.logTenLegDedupKey(for: leg)
            guard !key.hasPrefix("|") else { continue }
            crewAccessLegImportReferenceTimes[key] = importConfirmedAt
        }

        let domicile = verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
        let importedTripKeys = Self.crewAccessTripKeys(for: imported, domicile: domicile)
        // Reached only after persistCrewAccessJSON succeeded in confirmPendingImport, so the new
        // generation is already durable on disk before the deletion is cancelled. The fingerprint
        // additionally lets the fetch path protect this exact generation from a stale tombstone
        // until CloudKit acknowledges it.
        recordExplicitCrewAccessReimport(
            tripKeys: importedTripKeys,
            payloadFingerprint: payloadFingerprint
        )
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

    /// Puts back reference times that `pruneCrewAccessLegImportReferenceTimes` dropped when a
    /// Timeline rebuild was later rolled back. Restores the in-memory map and the persisted copy
    /// together so the LogTen backlog cannot be lost to a transient sync failure.
    private func restoreCrewAccessLegImportReferenceTimes(_ referenceTimes: [String: Date]) {
        guard crewAccessLegImportReferenceTimes != referenceTimes else { return }
        crewAccessLegImportReferenceTimes = referenceTimes
        Self.saveCrewAccessLegImportReferenceTimes(
            referenceTimes,
            to: UserDefaults.standard,
            key: crewAccessLegImportReferenceTimesKey
        )
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

    func backfillCrewAccessLegImportReferenceTimesIfNeeded() {
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

    private struct AppGroupPendingImportReference {
        let fileName: String
        let fileURL: URL
        /// The per-share queue file this reference came from; nil when it came from
        /// the legacy single-slot manifest. Deleted individually after consumption —
        /// never as a bulk "clear everything" that could race a concurrent share.
        let queueFileURL: URL?
    }

    private nonisolated static func appGroupImportDirectoryURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupImportConfig.appGroupIdentifier) else {
            return nil
        }
        return container.appendingPathComponent(AppGroupImportConfig.importDirectoryName, isDirectory: true)
    }

    private nonisolated static func readPendingAppGroupHandoffs() -> [AppGroupPendingImportReference] {
        guard let directoryURL = appGroupImportDirectoryURL() else { return [] }
        let fm = FileManager.default
        var references: [AppGroupPendingImportReference] = []

        // Per-share queue files (current format). Sorted by share timestamp so a
        // rapid multi-share imports in the order the user shared.
        let queueFileURLs = ((try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { AppGroupImportHandoff.isQueueFileName($0.lastPathComponent) }

        var queueReferences: [(createdAt: String, reference: AppGroupPendingImportReference)] = []
        for queueFileURL in queueFileURLs {
            guard let data = try? Data(contentsOf: queueFileURL),
                  let entry = AppGroupImportHandoff.decodeEntries(from: data).first else {
                logger.error("[Import] appGroup queue file unreadable — discarding name=\(queueFileURL.lastPathComponent, privacy: .private)")
                try? fm.removeItem(at: queueFileURL)
                continue
            }
            queueReferences.append((
                createdAt: entry.createdAtISO8601 ?? "",
                reference: AppGroupPendingImportReference(
                    fileName: entry.fileName,
                    fileURL: directoryURL.appendingPathComponent(entry.fileName, isDirectory: false),
                    queueFileURL: queueFileURL
                )
            ))
        }
        references += queueReferences
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.reference)

        // Legacy single-slot manifest from a pre-update extension. Read once here;
        // consumed entries delete it. New code never writes this file, so deleting
        // it after consumption cannot race a concurrent share.
        let legacyURL = directoryURL.appendingPathComponent(AppGroupImportConfig.legacyManifestFileName, isDirectory: false)
        if let data = try? Data(contentsOf: legacyURL) {
            let entries = AppGroupImportHandoff.decodeEntries(from: data)
            if entries.isEmpty {
                logger.error("[Import] appGroup legacy manifest unreadable — discarding")
                try? fm.removeItem(at: legacyURL)
            }
            references += entries.enumerated().map { index, entry in
                AppGroupPendingImportReference(
                    fileName: entry.fileName,
                    fileURL: directoryURL.appendingPathComponent(entry.fileName, isDirectory: false),
                    // The legacy array is one shared manifest. Assign cleanup to
                    // exactly one reference so later entries do not all claim
                    // ownership of the same file.
                    queueFileURL: index == 0 ? legacyURL : nil
                )
            }
        }

        return references
    }

    /// Deletes share-directory PDFs and queue files that were never consumed
    /// (e.g. leftovers of a failed import). Without this the App Group container
    /// grows forever. `excludingFileNames` protects PDFs that were queued for
    /// import in this session: a share left unconsumed past the age threshold is
    /// still queued by consume, and the sweep must not delete it out from under
    /// the (asynchronous) import pipeline.
    private nonisolated static func sweepStaleAppGroupImportFilesBestEffort(
        olderThanDays days: Int = 7,
        excludingFileNames excluded: Set<String> = []
    ) {
        guard let directoryURL = appGroupImportDirectoryURL() else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        for url in entries {
            let name = url.lastPathComponent
            guard !excluded.contains(name) else { continue }
            let isSweepable = url.pathExtension.lowercased() == "pdf"
                || AppGroupImportHandoff.isQueueFileName(name)
                || name == AppGroupImportConfig.legacyManifestFileName
            guard isSweepable else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? fm.removeItem(at: url)
            }
        }
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
            currentDateUTC: retentionReferenceDate(),
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

    private nonisolated static func crewAccessTripKey(
        fromCloudKitRecord record: CrewAccessImportCloudKitRecord,
        domicile: String
    ) -> String? {
        guard let payload = try? JSONDecoder().decode(CrewAccessTripJSON.self, from: record.jsonData) else {
            return nil
        }
        let startUTC = payload.items
            .compactMap { LegConnectionTextBuilder.parseUTC($0.startUtc) }
            .min()
            ?? record.firstDepartureUTC.flatMap { LegConnectionTextBuilder.parseUTC($0) }
        let endUTC = payload.items
            .compactMap { LegConnectionTextBuilder.parseUTC($0.endUtc) }
            .max()
        if let operationalKey = crewAccessTripKey(
            tripID: payload.tripId,
            startUTC: startUTC,
            endUTC: endUTC,
            domicile: domicile
        ) {
            return operationalKey
        }
        let payloadTripInformationDate = payload.tripInformationDate.trimmingCharacters(in: .whitespacesAndNewlines)
        return crewAccessTripKey(
            tripID: payload.tripId,
            tripInformationDate: payloadTripInformationDate.isEmpty ? record.tripInformationDate : payloadTripInformationDate,
            fallbackDate: record.firstDepartureUTC.flatMap { LegConnectionTextBuilder.parseUTC($0) }
        )
    }

    private nonisolated static func loadDeletedCrewAccessTripIntents(
        from defaults: UserDefaults,
        key: String,
        legacyKey: String
    ) -> [String: Date] {
        var intents: [String: Date] = [:]
        if let stored = defaults.dictionary(forKey: key) {
            for (tripKey, rawValue) in stored {
                let timestamp: TimeInterval?
                if let value = rawValue as? TimeInterval {
                    timestamp = value
                } else if let value = rawValue as? NSNumber {
                    timestamp = value.doubleValue
                } else {
                    timestamp = nil
                }
                if let timestamp {
                    intents[tripKey] = Date(timeIntervalSince1970: timestamp)
                }
            }
        }

        // v1 stored only permanent keys without timestamps. Treat them as legacy
        // deletion intents so any subsequently active CloudKit record (a re-import)
        // can win and heal older devices instead of being tombstoned again.
        for tripKey in defaults.stringArray(forKey: legacyKey) ?? [] where intents[tripKey] == nil {
            intents[tripKey] = .distantPast
        }
        return intents
    }

    private nonisolated static func saveDeletedCrewAccessTripIntents(
        _ intents: [String: Date],
        to defaults: UserDefaults,
        key: String,
        legacyKey: String
    ) {
        let stored = intents.mapValues(\.timeIntervalSince1970)
        defaults.set(stored, forKey: key)
        defaults.removeObject(forKey: legacyKey)
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

    private nonisolated static func deleteCrewAccessImportFilesOutsideRetainedBidPeriods(
        retainedOrders: Set<Int>,
        directory: URL?
    ) -> Int {
        let fm = FileManager.default
        guard let dir = directory else {
            return 0
        }
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

    private nonisolated static func loadCrewAccessSchedulesFromImportFiles(
        directory: URL?
    ) -> [PayPeriodSchedule] {
        let payloads = loadCrewAccessTripJSONPayloadsFromImportFilesSync(directory: directory)
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

    private nonisolated static func loadCrewAccessTripJSONPayloadsFromImportFiles(
        directory: URL?
    ) async -> [CrewAccessTripJSON] {
        await Task.detached(priority: .utility) {
            loadCrewAccessTripJSONPayloadsFromImportFilesSync(directory: directory).map(\.payload)
        }.value
    }

    private nonisolated static func loadCrewAccessTripJSONPayloadsFromImportFilesSync(
        directory: URL?
    ) -> [(payload: CrewAccessTripJSON, modifiedAt: Date)] {
        let fm = FileManager.default
        guard let dir = directory else {
            return []
        }
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
        _ schedules: [PayPeriodSchedule],
        directory: URL?
    ) -> [PayPeriodSchedule] {
        let hotelMap = hotelMapFromCrewAccessImports(directory: directory)
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
    private nonisolated static func hotelMapFromCrewAccessImports(
        directory: URL?
    ) -> [String: [String: String]] {
        let payloads = loadCrewAccessTripJSONPayloadsFromImportFilesSync(directory: directory)
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

    /// Internal rather than private so tests can build the *same* schedule the import path builds.
    /// Hand-rolled test schedules drift from the production leg/trip key formats and then assert
    /// against keys that never occur in the app.
    nonisolated static func buildCrewAccessSchedule(from payload: CrewAccessTripJSON, modifiedAt: Date) -> PayPeriodSchedule? {
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
                status: item.flight.caseInsensitiveCompare("GND") == .orderedSame
                    ? "GND"
                    : (item.deadhead ? "DH" : "-"),
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
        tripKeys: [String],
        directory: URL?
    ) -> (deleted: Int, failures: Int, deletedFileNames: [String]) {
        struct ImportFileHeader {
            let url: URL
            let name: String
            let tripID: String?
            let tripKey: String?
        }

        let fm = FileManager.default
        guard let dir = directory else {
            return (0, 0, [])
        }
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
        guard let dir = crewAccessImportsDirectory else {
            throw NSError(
                domain: "CrewAccessImport",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Documents directory is unavailable."]
            )
        }

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

    private func finalizeCrewAccessJSONWriteBestEffort(with context: CrewAccessJSONWriteContext) {
        guard let backupURL = context.backupURL,
              FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: backupURL)
        } catch {
            logger.error("[Import] Failed to remove committed JSON backup \(backupURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A stale same-trip JSON moved aside during a commit, and where it went.
    ///
    /// These files are removed *before* `verifyCrewAccessImportCommit` runs, so deleting them
    /// outright made the rollback incomplete: a commit that then failed verification restored
    /// `finalURL` but had already destroyed every other file representing the same trip, which is
    /// exactly the "old trip gone and new trip gone" state the fail-closed path exists to prevent.
    /// Moving instead of deleting keeps the rollback total.
    private struct CrewAccessStaleJSONStash {
        let originalURL: URL
        let backupURL: URL
    }

    /// Moves stale same-trip JSON files aside instead of deleting them. Same hidden-dotfile naming
    /// as the `finalURL` backup, so the import-file scan skips them while they exist.
    private func stashStaleCrewAccessJSONFilesBestEffort(_ urls: [URL]) -> [CrewAccessStaleJSONStash] {
        guard !urls.isEmpty else { return [] }
        let fm = FileManager.default
        var stashes: [CrewAccessStaleJSONStash] = []
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            let backupURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).stale-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: url, to: backupURL)
                stashes.append(CrewAccessStaleJSONStash(originalURL: url, backupURL: backupURL))
                logger.info("[Import] Stashed stale trip file: \(url.lastPathComponent, privacy: .private)")
            } catch {
                // Falling back to a delete would reintroduce the unrecoverable case, so leave the
                // file in place. A surviving duplicate is reconciled on the next import or sync;
                // an unrecoverable one is not.
                logger.error("[Import] Failed to stash stale trip file \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        return stashes
    }

    /// Puts every stashed stale file back. Called on every failure path, alongside
    /// `rollbackCrewAccessJSONWrite`.
    private func restoreStashedStaleCrewAccessJSONFiles(_ stashes: [CrewAccessStaleJSONStash]) {
        let fm = FileManager.default
        for stash in stashes {
            guard fm.fileExists(atPath: stash.backupURL.path) else { continue }
            do {
                if fm.fileExists(atPath: stash.originalURL.path) {
                    _ = try fm.replaceItemAt(stash.originalURL, withItemAt: stash.backupURL)
                } else {
                    try fm.moveItem(at: stash.backupURL, to: stash.originalURL)
                }
                logger.info("[Import] Restored stale trip file: \(stash.originalURL.lastPathComponent, privacy: .private)")
            } catch {
                logger.error("[Import] Failed to restore stale trip file \(stash.originalURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Discards the stashes. Only safe once the commit has passed verification — until then the
    /// stash is the only copy of the superseded trip.
    private func discardStashedStaleCrewAccessJSONFilesBestEffort(_ stashes: [CrewAccessStaleJSONStash]) {
        let fm = FileManager.default
        for stash in stashes where fm.fileExists(atPath: stash.backupURL.path) {
            do {
                try fm.removeItem(at: stash.backupURL)
            } catch {
                logger.error("[Import] Failed to remove stale trip stash \(stash.backupURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
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
        await restoreProfileAfterIdentityVerification(gemsID: gemsID)
        do {
            try await gemsVerificationCloudKitService.recordVerifiedUser(gemsID: gemsID)
        } catch {
            logNonFatal("Failed to record verified app user: \(error.localizedDescription)")
        }
        updateAdminStatus()
        identityActionMessage = isAdminBootstrap
            ? "Verified as bootstrap admin. Upload GEMS verification records to CloudKit."
            : "Verified as GEMS \(gemsID) / \(domicile)."
        async let friendRestore: Void = syncFriendCloudKit(reason: "identity verified")
        async let deviceRestore: Void = recoverCloudSyncAfterIdentityAvailable(reason: "identity verified")
        _ = await (friendRestore, deviceRestore)
    }

    private func appReviewMockVerificationResult(gemsID: String, normalizedDOB: String) -> GEMSVerificationResult? {
        guard AppReviewDemo.isDemoCredential(gemsID: gemsID, normalizedDOB: normalizedDOB) else { return nil }
        return GEMSVerificationResult(gemsID: gemsID, domicile: DomicileSupport.defaultDomicile)
    }

    private func linkAppReviewMockFriendIfNeeded(myGEMSID: String, friendGEMSID: String) -> Bool {
        guard AppReviewDemo.role(for: myGEMSID) == .pilotOne,
              AppReviewDemo.role(for: friendGEMSID) == .pilotTwo else { return false }

        let linkedAt = Date()
        upsertAppReviewMockPilotTwoFriend(linkedAt: linkedAt)
        friendCloudKitSyncMessage = "App Review mock friend linked locally."
        friendActionMessage = "Friend linked: \(AppReviewDemo.pilotTwoGEMSID)"
        return true
    }

    private func upsertAppReviewMockPilotTwoFriend(linkedAt: Date) {
        enableScheduleSharingForFriends()
        let friend = AppReviewDemo.pilotTwoGEMSID
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
        guard let mockSchedules = Self.appReviewMockSchedules(
            for: normalized,
            updatedAt: Self.appReviewMockUpdatedAt
        ) else {
            return
        }

        let updatedCrewAccess = Self.replacingCachedAppReviewMockSchedules(
            in: crewAccessSchedules,
            with: mockSchedules
        )
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
        let pairings = mockSchedules.compactMap { $0.legs.first?.pairing }.joined(separator: ", ")
        lastImportSummaryMessage = "Loaded App Review sample trips \(pairings)."
        if AppReviewDemo.role(for: normalized) == .pilotOne,
           friendConnections.contains(where: { $0.employeeID == AppReviewDemo.pilotTwoGEMSID }) {
            upsertAppReviewMockPilotTwoFriend(linkedAt: Date())
        }
    }

    static func replacingCachedAppReviewMockSchedules(
        in schedules: [PayPeriodSchedule],
        for gemsID: String,
        updatedAt: Date
    ) -> [PayPeriodSchedule] {
        guard let mockSchedules = appReviewMockSchedules(for: gemsID, updatedAt: updatedAt) else {
            return schedules
        }
        return replacingCachedAppReviewMockSchedules(in: schedules, with: mockSchedules)
    }

    private static func appReviewMockSchedules(
        for gemsID: String,
        updatedAt: Date
    ) -> [PayPeriodSchedule]? {
        switch AppReviewDemo.role(for: gemsID) {
        case .pilotOne:
            return appReviewPilotOneSchedules(updatedAt: updatedAt)
        case .pilotTwo:
            return [appReviewPilotTwoSchedule(updatedAt: updatedAt)]
        case nil:
            return nil
        }
    }

    private static func replacingCachedAppReviewMockSchedules(
        in schedules: [PayPeriodSchedule],
        with selectedAccountSchedules: [PayPeriodSchedule]
    ) -> [PayPeriodSchedule] {
        let allMockSchedules =
            appReviewPilotOneSchedules(updatedAt: appReviewMockUpdatedAt)
            + [appReviewPilotTwoSchedule(updatedAt: appReviewMockUpdatedAt)]
        let allMockIDs = Set(allMockSchedules.map(\.id))
        let allMockPairings = Set(allMockSchedules.flatMap { $0.legs.map(\.pairing) })
        return (
            schedules.filter { existing in
                !allMockIDs.contains(existing.id)
                    && existing.legs.allSatisfy { !allMockPairings.contains($0.pairing) }
            }
            + selectedAccountSchedules
        )
        .sorted { $0.label < $1.label }
    }

    /// Fixed timestamp for App Review demo schedules. Using a constant (rather than
    /// `Date()`) keeps rebuilt demo schedules byte-for-byte identical so reconcile
    /// does not detect a spurious change on every pass.
    static let appReviewMockUpdatedAt = Date(timeIntervalSince1970: 1_780_000_000)

    /// Deterministic UUID derived from a seed so demo legs keep a stable identity
    /// across rebuilds (no timeline/cache/notification churn from random UUIDs).
    private static func stableMockLegID(_ seed: String) -> UUID {
        let prime: UInt64 = 1_099_511_628_211
        var hi: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hi = (hi ^ UInt64(byte)) &* prime
        }
        var lo: UInt64 = hi ^ 0x9E37_79B9_7F4A_7C15
        for byte in seed.utf8.reversed() {
            lo = (lo ^ UInt64(byte)) &* prime
        }
        let hex = String(format: "%016llx%016llx", hi, lo)
        let c = Array(hex)
        let uuidString =
            "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func withStableMockLegID(_ leg: TripLeg) -> TripLeg {
        TripLeg(
            id: stableMockLegID("\(leg.pairing)-\(leg.leg)-\(leg.flight)"),
            payPeriod: leg.payPeriod, pairing: leg.pairing, leg: leg.leg, flight: leg.flight,
            depAirport: leg.depAirport, depLocal: leg.depLocal,
            arrAirport: leg.arrAirport, arrLocal: leg.arrLocal,
            depUTC: leg.depUTC, arrUTC: leg.arrUTC, status: leg.status, block: leg.block,
            layoverStation: leg.layoverStation, layoverHotelName: leg.layoverHotelName,
            layoverDuration: leg.layoverDuration,
            stdUTC: leg.stdUTC, staUTC: leg.staUTC, atdUTC: leg.atdUTC, ataUTC: leg.ataUTC
        )
    }

    private static func withStableMockLegIDs(_ schedule: PayPeriodSchedule) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: schedule.id,
            label: schedule.label,
            tripCount: schedule.tripCount,
            legCount: schedule.legCount,
            openTimeCount: schedule.openTimeCount,
            updatedAt: schedule.updatedAt,
            legs: schedule.legs.map(withStableMockLegID),
            openTimeTrips: schedule.openTimeTrips
        )
    }

    static func appReviewPilotOneSchedules(updatedAt: Date) -> [PayPeriodSchedule] {
        [
            appReviewPilotOneJuneSchedule(updatedAt: updatedAt),
            appReviewPilotOneCurrentSchedule(updatedAt: updatedAt),
            appReviewPilotOneJulySchedule(updatedAt: updatedAt)
        ].map(Self.withStableMockLegIDs)
    }

    private static func appReviewPilotOneCurrentSchedule(updatedAt: Date) -> PayPeriodSchedule {
        let payPeriod = "PP26-07"
        let pairing = "A00001"
        let legs = [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "XX001",
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
                flight: "XX002",
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
                flight: "XX003",
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

    private static func appReviewPilotOneJuneSchedule(updatedAt: Date) -> PayPeriodSchedule {
        let payPeriod = "PP26-06"
        let pairing = "A00020"
        let legs = [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "XX020",
                depAirport: "ANC",
                depLocal: "2026-06-01 10:00",
                arrAirport: "HKG",
                arrLocal: "2026-06-02 13:00",
                depUTC: "2026-06-01T18:00:00Z",
                arrUTC: "2026-06-02T05:00:00Z",
                status: "-",
                block: "11:00",
                layoverStation: "HKG",
                layoverDuration: "55:35",
                stdUTC: "2026-06-01T18:00:00Z",
                staUTC: "2026-06-02T05:00:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 2,
                flight: "XX021",
                depAirport: "HKG",
                depLocal: "2026-06-04 20:35",
                arrAirport: "ANC",
                arrLocal: "2026-06-04 15:10",
                depUTC: "2026-06-04T12:35:00Z",
                arrUTC: "2026-06-04T23:10:00Z",
                status: "-",
                block: "10:35",
                stdUTC: "2026-06-04T12:35:00Z",
                staUTC: "2026-06-04T23:10:00Z"
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

    private static func appReviewPilotOneJulySchedule(updatedAt: Date) -> PayPeriodSchedule {
        let payPeriod = "PP26-07"
        let pairing = "A00010"
        let legs = [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "XX010",
                depAirport: "ANC",
                depLocal: "2026-06-30 15:10",
                arrAirport: "HGH",
                arrLocal: "2026-07-01 16:45",
                depUTC: "2026-06-30T23:10:00Z",
                arrUTC: "2026-07-01T08:45:00Z",
                status: "-",
                block: "09:35",
                layoverStation: "HGH",
                layoverDuration: "45:20",
                stdUTC: "2026-06-30T23:10:00Z",
                staUTC: "2026-07-01T08:45:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 2,
                flight: "XX011",
                depAirport: "HGH",
                depLocal: "2026-07-03 14:05",
                arrAirport: "TPE",
                arrLocal: "2026-07-03 16:10",
                depUTC: "2026-07-03T06:05:00Z",
                arrUTC: "2026-07-03T08:10:00Z",
                status: "-",
                block: "02:05",
                layoverStation: "TPE",
                layoverDuration: "39:20",
                stdUTC: "2026-07-03T06:05:00Z",
                staUTC: "2026-07-03T08:10:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 3,
                flight: "XX012",
                depAirport: "TPE",
                depLocal: "2026-07-05 07:30",
                arrAirport: "DXB",
                arrLocal: "2026-07-05 14:45",
                depUTC: "2026-07-04T23:30:00Z",
                arrUTC: "2026-07-05T10:45:00Z",
                status: "-",
                block: "11:15",
                layoverStation: "DXB",
                layoverDuration: "25:15",
                stdUTC: "2026-07-04T23:30:00Z",
                staUTC: "2026-07-05T10:45:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 4,
                flight: "XX013",
                depAirport: "DXB",
                depLocal: "2026-07-06 16:00",
                arrAirport: "FRA",
                arrLocal: "2026-07-06 20:10",
                depUTC: "2026-07-06T12:00:00Z",
                arrUTC: "2026-07-06T18:10:00Z",
                status: "-",
                block: "06:10",
                layoverStation: "FRA",
                layoverDuration: "32:25",
                stdUTC: "2026-07-06T12:00:00Z",
                staUTC: "2026-07-06T18:10:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 5,
                flight: "XX014",
                depAirport: "FRA",
                depLocal: "2026-07-08 04:35",
                arrAirport: "CVG",
                arrLocal: "2026-07-08 05:40",
                depUTC: "2026-07-08T02:35:00Z",
                arrUTC: "2026-07-08T09:40:00Z",
                status: "-",
                block: "07:05",
                layoverStation: "CVG",
                layoverDuration: "26:20",
                stdUTC: "2026-07-08T02:35:00Z",
                staUTC: "2026-07-08T09:40:00Z"
            ),
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 6,
                flight: "XX015",
                depAirport: "CVG",
                depLocal: "2026-07-10 08:00",
                arrAirport: "ANC",
                arrLocal: "2026-07-10 10:35",
                depUTC: "2026-07-10T12:00:00Z",
                arrUTC: "2026-07-10T18:35:00Z",
                status: "-",
                block: "06:35",
                stdUTC: "2026-07-10T12:00:00Z",
                staUTC: "2026-07-10T18:35:00Z"
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

    static func appReviewPilotTwoSchedule(updatedAt: Date) -> PayPeriodSchedule {
        withStableMockLegIDs(appReviewPilotTwoScheduleRaw(updatedAt: updatedAt))
    }

    private static func appReviewPilotTwoScheduleRaw(updatedAt: Date) -> PayPeriodSchedule {
        let payPeriod = "PP26-07"
        let pairing = "B00001"
        let legs = [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "XX004",
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
                flight: "XX005",
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
                flight: "XX003",
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
        // Cancel any debounced profile upload so a stale snapshot cannot land in
        // CloudKit after the tombstone and resurrect the deleted account.
        pendingProfileUploadTask?.cancel()
        pendingProfileUploadTask = nil
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
            await writeProfileTombstoneToCloudKit()
            if let deletingGEMSID {
                await deleteFriendSharingDataForAccountDelete(gemsID: deletingGEMSID)
            }
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
        defaults.removeObject(forKey: ProfileStorageKeys.faaMedicalExpiryDate)
        defaults.removeObject(forKey: ProfileStorageKeys.passportExpiryDate)
        defaults.removeObject(forKey: ProfileStorageKeys.chinaVisaExpiryDate)
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
                // Pure last-write-wins. We deliberately do NOT fold local-only
                // readiness dates into an empty cloud value here: CloudKit cannot
                // tell a legacy record (predating the dates feature) from one whose
                // dates were intentionally cleared on another device, so merging
                // would resurrect a deletion. Pre-verification dates are migrated
                // once via restoreProfileAfterIdentityVerification; ongoing edits
                // upload immediately, so newer local dates already win below.
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
        guard !isDeletingProfileAccount else { return }
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

    /// Called by Settings bindings for readiness dates. Changes are persisted locally
    /// immediately and coalesced into one CloudKit upload after wheel interaction settles.
    func profileSettingsDidChange() {
        markProfileUpdated()
        pendingProfileUploadTask?.cancel()
        guard verifiedIdentity != nil else { return }
        pendingProfileUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.uploadProfileToCloudKit()
        }
    }

    func restoreProfileAfterIdentityVerification(gemsID: String) async {
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        do {
            if let remote = try await profileCloudKitService.fetchProfile() {
                let remoteGEMSID = GEMSIDNormalizer.normalize(remote.gemsID)
                if remoteGEMSID == normalizedGEMSID {
                    // Same account: the cloud record is authoritative. Only fold in
                    // readiness dates the user entered *before ever verifying* — i.e.
                    // when the local GEMS ID is still blank (true pre-verification
                    // input). Never re-merge dates left over from a prior verified
                    // session: a cleared-on-another-device value (cloud nil) must not
                    // be revived by this device's stale copy.
                    let local = ProfileSnapshot.loadFromLocalStorage()
                    let isPreVerificationInput = GEMSIDNormalizer.normalize(local.gemsID).isEmpty
                    if isPreVerificationInput {
                        var stamped = local
                        stamped.gemsID = normalizedGEMSID
                        let merged = remote.mergingLegacyReadinessDates(from: stamped)
                        if merged.didMerge {
                            var restored = merged.snapshot
                            restored.updatedAt = Date()
                            restored.saveToLocalStorage()
                            try await profileCloudKitService.saveProfile(restored)
                            return
                        }
                    }
                    remote.saveToLocalStorage()
                    return
                }
            }

            // No cloud record, or it belongs to a *different* GEMS ID. Never inherit
            // a previous account's avatar / passport / visa / medical data — only the
            // current (or first-time) user's own local profile may carry forward.
            let existing = ProfileSnapshot.loadFromLocalStorage()
            let existingGEMSID = GEMSIDNormalizer.normalize(existing.gemsID)
            var profile: ProfileSnapshot
            if existingGEMSID.isEmpty || existingGEMSID == normalizedGEMSID {
                profile = existing
            } else {
                profile = ProfileSnapshot(
                    gemsID: normalizedGEMSID,
                    displayName: "",
                    fleet: ProfileFleet.fleet757.rawValue,
                    base: OperationalSettings.defaultCrewBase.rawValue,
                    position: ProfilePosition.ca.rawValue,
                    avatarImageData: nil,
                    faaMedicalExpiryDate: nil,
                    passportExpiryDate: nil,
                    chinaVisaExpiryDate: nil,
                    updatedAt: Date(),
                    lastSeenAt: nil
                )
            }
            profile.gemsID = normalizedGEMSID
            if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.displayName = verifiedIdentity?.name ?? "GEMS \(normalizedGEMSID)"
            }
            profile.updatedAt = Date()
            profile.saveToLocalStorage()
            try await profileCloudKitService.saveProfile(profile)
        } catch {
            logNonFatal("Profile restore after identity verification failed: \(error.localizedDescription)")
        }
    }

    /// Writes an empty profile tombstone to CloudKit so other devices detect the
    /// deletion via last-write-wins (`tombstone.updatedAt > their local.updatedAt`).
    /// Does NOT call CKDatabase.delete — the record stays, content is cleared.
    private func writeProfileTombstoneToCloudKit() async {
        let tombstone = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil,
            faaMedicalExpiryDate: nil,
            passportExpiryDate: nil,
            chinaVisaExpiryDate: nil,
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
        guard !isOpenTimeDemoMode else {
            refreshOpenTimeDemoData()
            return
        }
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
        guard !isOpenTimeDemoMode else {
            lastAutoFetchAt = nil
            return
        }
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
            guard !isOpenTimeDemoMode else {
                refreshOpenTimeDemoData()
                return
            }

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
        guard !isOpenTimeDemoMode else {
            refreshOpenTimeDemoData()
            return
        }
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

    /// Failures that are recoverable but should never be invisible. Logged at
    /// `.error` so they persist in the unified log store and stand out in Console;
    /// `.public` is kept deliberately because these messages are the only signal
    /// in TestFlight sysdiagnose captures.
    private func logNonFatal(_ message: String) {
        logger.error("\(message, privacy: .public)")
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
            sharedSchedules: Self.newerFriendSchedules(lhs.sharedSchedules, rhs.sharedSchedules),
            sharedTimelineCards: lhs.sharedTimelineCards.isEmpty ? rhs.sharedTimelineCards : lhs.sharedTimelineCards
        )
    }

    nonisolated static func newerFriendSchedules(
        _ lhs: [PayPeriodSchedule],
        _ rhs: [PayPeriodSchedule]
    ) -> [PayPeriodSchedule] {
        // Friend caches can contain different pay periods. Comparing only each
        // array's maximum timestamp lets one recently updated period discard
        // unrelated periods known only to the other device.
        //
        // Both arrays arrive from another user's device, so duplicate ids must be
        // treated as ordinary input, never as a precondition. `PayPeriodSchedule.id`
        // is the CrewAccess label (e.g. "CA26-07-A70606") built one-per-import-file,
        // and the same trip can legitimately exist under both a legacy and a current
        // file name — `Dictionary(uniqueKeysWithValues:)` would trap on that.
        //
        // Deliberately no early return when one side is empty: a lone array can carry
        // duplicate ids of its own, and short-circuiting would pass them through
        // un-collapsed. Every input reaches the same merge so the result is always
        // deduplicated and ordered consistently.
        var mergedByID: [String: PayPeriodSchedule] = [:]
        mergedByID.reserveCapacity(lhs.count + rhs.count)
        for schedule in lhs + rhs {
            if let existing = mergedByID[schedule.id] {
                mergedByID[schedule.id] = Self.newerSchedule(existing, schedule)
            } else {
                mergedByID[schedule.id] = schedule
            }
        }
        return mergedByID.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// Ties resolve to `candidate`. A friend's schedules are all stamped with the same
    /// server record timestamp by `fetchSchedule`, so equal timestamps mean "same fetch"
    /// and either value is correct; taking the later argument keeps the freshly fetched
    /// copy when merging a cache into a new fetch.
    private nonisolated static func newerSchedule(
        _ current: PayPeriodSchedule,
        _ candidate: PayPeriodSchedule
    ) -> PayPeriodSchedule {
        current.updatedAt > candidate.updatedAt ? current : candidate
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
        // Normalisation can collapse two legacy KV entries onto one id, so duplicates are
        // ordinary input here, not a precondition. Keep the entry that proves acceptance.
        let existingByID = Dictionary(
            existingEntries.map { (GEMSIDNormalizer.normalize($0.employeeID), $0) },
            uniquingKeysWith: { current, candidate in
                switch (current.acceptedAt, candidate.acceptedAt) {
                case let (currentAccepted?, candidateAccepted?):
                    return candidateAccepted > currentAccepted ? candidate : current
                case (nil, _?):
                    return candidate
                default:
                    return current
                }
            }
        )
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

    private static let openTimeDemoSchedules: [PayPeriodSchedule] = [
        PayPeriodSchedule(
                id: "DEMO-PP26-06",
                label: "PP26-06",
                tripCount: 0,
                legCount: 0,
                openTimeCount: 4,
                updatedAt: Date(timeIntervalSince1970: 1_780_358_400),
                legs: [],
                openTimeTrips: [
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260601") ?? UUID(),
                        payPeriod: "PP26-06",
                        pairing: "A76102",
                        startLocal: "2026-05-28 08:15",
                        endLocal: "2026-06-01 19:40",
                        route: "ANC CVG HND ANC",
                        credit: "28:35",
                        requestType: "PO",
                        status: "Demo",
                        legs: [
                            TripLeg(
                                id: UUID(uuidString: "00000000-0000-0000-0000-000000260611") ?? UUID(),
                                payPeriod: "PP26-06",
                                pairing: "A76102",
                                leg: 1,
                                flight: "XX102",
                                depAirport: "ANC",
                                depLocal: "2026-05-28 08:15",
                                arrAirport: "CVG",
                                arrLocal: "2026-05-28 17:40",
                                depUTC: "2026-05-28T16:15:00Z",
                                arrUTC: "2026-05-28T21:40:00Z",
                                status: "-",
                                block: "5:25"
                            ),
                            TripLeg(
                                id: UUID(uuidString: "00000000-0000-0000-0000-000000260612") ?? UUID(),
                                payPeriod: "PP26-06",
                                pairing: "A76102",
                                leg: 2,
                                flight: "XX184",
                                depAirport: "CVG",
                                depLocal: "2026-05-29 11:30",
                                arrAirport: "HND",
                                arrLocal: "2026-05-30 14:10",
                                depUTC: "2026-05-29T15:30:00Z",
                                arrUTC: "2026-05-30T05:10:00Z",
                                status: "-",
                                block: "13:40"
                            )
                        ]
                    ),
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260602") ?? UUID(),
                        payPeriod: "PP26-06",
                        pairing: "A76218",
                        startLocal: "2026-06-05 22:10",
                        endLocal: "2026-06-09 09:55",
                        route: "ANC SDF CGN SDF ANC",
                        credit: "31:20",
                        requestType: "PC",
                        status: "Demo"
                    ),
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260603") ?? UUID(),
                        payPeriod: "PP26-06",
                        pairing: "A76344",
                        startLocal: "2026-06-10 06:45",
                        endLocal: "2026-06-13 16:25",
                        route: "ANC NRT SIN HKG ANC",
                        credit: "36:05",
                        requestType: "PO",
                        status: "Demo"
                    ),
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260604") ?? UUID(),
                        payPeriod: "PP26-06",
                        pairing: "A76470",
                        startLocal: "2026-06-12 18:00",
                        endLocal: "2026-06-13 23:40",
                        route: "ANC LAX ANC",
                        credit: "12:15",
                        requestType: "PC",
                        status: "Demo"
                    )
                ]
        ),
        PayPeriodSchedule(
                id: "DEMO-PP26-07",
                label: "PP26-07",
                tripCount: 0,
                legCount: 0,
                openTimeCount: 3,
                updatedAt: Date(timeIntervalSince1970: 1_782_777_600),
                legs: [],
                openTimeTrips: [
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260701") ?? UUID(),
                        payPeriod: "PP26-07",
                        pairing: "A77005",
                        startLocal: "2026-06-16 07:30",
                        endLocal: "2026-06-20 18:05",
                        route: "ANC ICN BKK ICN ANC",
                        credit: "34:50",
                        requestType: "PO",
                        status: "Demo"
                    ),
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260702") ?? UUID(),
                        payPeriod: "PP26-07",
                        pairing: "A77191",
                        startLocal: "2026-06-24 12:10",
                        endLocal: "2026-06-28 21:30",
                        route: "ANC SDF DWC HKG",
                        credit: "42:10",
                        requestType: "PC",
                        status: "Demo"
                    ),
                    OpenTimeTrip(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000260703") ?? UUID(),
                        payPeriod: "PP26-07",
                        pairing: "A77260",
                        startLocal: "2026-07-03 09:20",
                        endLocal: "2026-07-06 15:05",
                        route: "ANC CVG AMS CVG ANC",
                        credit: "27:45",
                        requestType: "PO",
                        status: "Demo"
                    )
                ]
        )
    ]

}

private struct AdminPolicy {
    let verificationHashes: Set<String>
}

private struct AdminPolicyRaw: Decodable {
    let adminVerificationHashes: [String]
}

#if DEBUG
// MARK: - Raw trip debug snapshot (development-only diagnostic aggregate)
//
// This is NOT the CloudKit sync payload and NOT the future public Export JSON schema.
// It is a broader, unstable dump of everything the app currently has in memory/on-disk
// for one trip, meant to be inspected once to help design that future public schema.
// See docs/INTERNAL_JSON_EXPORT_INVESTIGATION.md for the full data-source investigation.

struct TripRawDebugSnapshot: Encodable {
    struct Generator: Encodable {
        let appVersion: String
        let buildNumber: String
        let snapshotSource: String
    }

    struct RawExtractStatsSnapshot: Encodable {
        let pageCount: Int
        let characterCount: Int
        let lineCount: Int
    }

    struct ImportIssueSnapshot: Encodable {
        let code: String
        let message: String
        let remediation: String?
    }

    struct TripSection: Encodable {
        let tripId: String
        let tripDate: String
        let importSource: String
        let sourceFileName: String?
        let importCreatedAt: Date
        /// The domain model that CloudKit's `schedulesData` field encodes — stored source data.
        let parsedSchedule: PayPeriodSchedule?
        /// The richer parser-time DTO written to `Documents/CrewAccessImports/*.json` — stored source data.
        let crewAccessTripJSON: CrewAccessTripJSON?
        let rawExtractStats: RawExtractStatsSnapshot
        let warnings: [ImportIssueSnapshot]
        let errors: [ImportIssueSnapshot]
    }

    /// A representation of the CloudKit `TDHSharedSchedule.schedulesData` shape for this trip —
    /// re-encoded here alongside the rest of the snapshot, not a byte-exact copy of the upload.
    struct CloudKitScheduleRepresentation: Encodable {
        let recordType: String
        let field: String
        let note: String
        let payload: [PayPeriodSchedule]
    }

    /// Resolved at export time from IATATimeZoneResolver's static table — derived, not stored per-trip.
    struct AirportInfoSnapshot: Encodable {
        let timeZoneIdentifier: String?
        let airportName: String?
        let cityName: String?
    }

    /// Mirrors `CrewAccessTripSummary` (Services/CrewAccessTripSummaryStore.swift), which is not Codable.
    struct HotelSummarySnapshot: Encodable {
        let tripId: String
        let fileKey: String
        let creditTime: String?
        let tripDays: String?
        let tafb: String?
        let hotelByStation: [String: String]
    }

    /// Manual events (crew-base + UTC time range, not trip-scoped in production) whose window
    /// overlaps this trip's leg span. The overlap filter below is diagnostic-only, computed here,
    /// and is not the app's real rest/timeline overlap logic (Views/TimelineSupport.swift).
    struct ManualEventsSnapshot: Encodable {
        /// Production manual events carry no trip ID; this grouping is inferred at export time.
        let associationMethod: String
        let overlapWindowStartUTC: Date?
        let overlapWindowEndUTC: Date?
        let operational: [ManualOperationalEvent]
        let personal: [ManualPersonalEvent]
    }

    struct RelatedData: Encodable {
        let manualEvents: ManualEventsSnapshot
        let tripSummaryStoreEntry: HotelSummarySnapshot?
    }

    struct DerivedData: Encodable {
        let legCount: Int
        let openTimeTripCount: Int
        let uniqueAirports: [String]
        let hasDeadheadLegs: Bool?
        /// Static-table lookups (IATATimeZoneResolver) performed at export time, not stored on any trip model.
        let airports: [String: AirportInfoSnapshot]
    }

    /// One data group confirmed to exist in the source PDF but not reachable at export time.
    struct UnavailableDataItem: Encodable {
        let dataGroup: String
        let status: String
        let reason: String
        let sourceStage: String
        let availableWithParserChanges: Bool
    }

    struct Diagnostics: Encodable {
        /// Data confirmed to exist in the source PDF but not reachable from this snapshot without
        /// invasive parser/model changes — see docs/INTERNAL_JSON_EXPORT_INVESTIGATION.md.
        let unavailableData: [UnavailableDataItem]
        let mappingVersion: String?
    }

    let snapshotVersion: String
    let generatedAt: Date
    let generator: Generator
    /// Machine-readable stability disclaimer, emitted into every snapshot file.
    let warning: String
    let trip: TripSection
    let cloudKitScheduleRepresentation: CloudKitScheduleRepresentation?
    let relatedData: RelatedData
    let derivedData: DerivedData
    let diagnostics: Diagnostics
}
#endif

#if DEBUG
extension AppViewModel {
    static func previewMock() -> AppViewModel {
        let vm = AppViewModel()
        vm.schedules = Self.previewSchedules
        vm.authStatus = .loggedIn
        return vm
    }

    private static let rawSnapshotUnavailableData: [TripRawDebugSnapshot.UnavailableDataItem] = [
        TripRawDebugSnapshot.UnavailableDataItem(
            dataGroup: "dutyPeriods.reportReleaseTimes",
            status: "unavailable",
            reason: "Duty start/end and report/release times are parsed by PDFTripParser into Trip/FlightLeg, but that intermediate object is discarded; only layover station/hotelName/duration survive into TripLeg.",
            sourceStage: "CrewAccessPDFImportService.analyzeTrip -> PDFTripParser output discarded",
            availableWithParserChanges: true
        ),
        TripRawDebugSnapshot.UnavailableDataItem(
            dataGroup: "groundTransportation",
            status: "unavailable",
            reason: "All three parsers treat the \"Hotel Transport:\" token purely as a text delimiter; the transport details following it are never captured into any field.",
            sourceStage: "PDFTripParser / TripScheduleSnapshotEncoder / CrewAccessTripSummaryStore hotel-line parsing",
            availableWithParserChanges: true
        ),
        TripRawDebugSnapshot.UnavailableDataItem(
            dataGroup: "hotel.phoneAndCheckInOut",
            status: "unavailable",
            reason: "Hotel phone and check-in/check-out times are parsed into LayoverLeg but discarded before reaching TripLeg or CrewAccessTripJSON.",
            sourceStage: "CrewAccessPDFImportService.layoverMetadataByArrivingSequence drops LayoverLeg fields",
            availableWithParserChanges: true
        ),
        TripRawDebugSnapshot.UnavailableDataItem(
            dataGroup: "rawExtractedPDFText",
            status: "unavailable",
            reason: "The full extracted text exists only in a local variable inside analyzeTrip and is not retained on CrewAccessImportDraft, PendingImport, or disk.",
            sourceStage: "CrewAccessPDFImportService.analyzeTrip local variable",
            availableWithParserChanges: true
        )
    ]

    private func buildRawSnapshotAirports(for pending: PendingImport) -> [String: TripRawDebugSnapshot.AirportInfoSnapshot] {
        var codes = Set<String>()
        func collect(_ legs: [TripLeg]) {
            for leg in legs {
                codes.insert(leg.depAirport)
                codes.insert(leg.arrAirport)
            }
        }
        if let schedule = pending.parsedSchedule {
            collect(schedule.legs)
            for openTimeTrip in schedule.openTimeTrips {
                collect(openTimeTrip.legs)
            }
        }
        if let items = pending.jsonPayload?.items {
            for item in items {
                codes.insert(item.depAirport)
                codes.insert(item.arrAirport)
            }
        }
        var result: [String: TripRawDebugSnapshot.AirportInfoSnapshot] = [:]
        for code in codes where !code.isEmpty {
            result[code] = TripRawDebugSnapshot.AirportInfoSnapshot(
                timeZoneIdentifier: IATATimeZoneResolver.shared.resolve(code),
                airportName: IATATimeZoneResolver.shared.airportName(code),
                cityName: IATATimeZoneResolver.shared.cityName(code)
            )
        }
        return result
    }

    private func buildRawSnapshotManualEvents(for pending: PendingImport) -> TripRawDebugSnapshot.ManualEventsSnapshot {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()
        func parseUTC(_ string: String?) -> Date? {
            guard let string else { return nil }
            return isoFormatter.date(from: string) ?? isoFormatterNoFraction.date(from: string)
        }
        let legs = (pending.parsedSchedule?.legs ?? []) + (pending.parsedSchedule?.openTimeTrips.flatMap(\.legs) ?? [])
        let starts = legs.compactMap { parseUTC($0.depUTC) }
        let ends = legs.compactMap { parseUTC($0.arrUTC) }
        let associationMethod = "inferred-by-utc-overlap: manual events carry no trip ID in production; selected here only because their UTC window overlaps this trip's leg span"
        guard let windowStart = starts.min(), let windowEnd = ends.max() else {
            return TripRawDebugSnapshot.ManualEventsSnapshot(
                associationMethod: associationMethod,
                overlapWindowStartUTC: nil,
                overlapWindowEndUTC: nil,
                operational: [],
                personal: []
            )
        }
        func overlaps(_ start: Date, _ end: Date) -> Bool {
            start <= windowEnd && end >= windowStart
        }
        return TripRawDebugSnapshot.ManualEventsSnapshot(
            associationMethod: associationMethod,
            overlapWindowStartUTC: windowStart,
            overlapWindowEndUTC: windowEnd,
            operational: manualOperationalEvents.filter { overlaps($0.startUTC, $0.endUTC) },
            personal: manualPersonalEvents.filter { overlaps($0.startUTC, $0.endUTC) }
        )
    }

    /// Writes a raw, unstable diagnostic snapshot of everything currently reachable for one pending
    /// trip import — for investigation only. This is not the CloudKit payload and not the future
    /// public Export JSON schema; see docs/INTERNAL_JSON_EXPORT_INVESTIGATION.md.
    @discardableResult
    func debugExportRawTripSnapshot(pending: PendingImport) -> URL? {
        let tripSection = TripRawDebugSnapshot.TripSection(
            tripId: pending.tripId,
            tripDate: pending.tripDate,
            importSource: pending.source.rawValue,
            sourceFileName: pending.sourceFileName,
            importCreatedAt: pending.createdAt,
            parsedSchedule: pending.parsedSchedule,
            crewAccessTripJSON: pending.jsonPayload,
            rawExtractStats: TripRawDebugSnapshot.RawExtractStatsSnapshot(
                pageCount: pending.rawExtractStats.pageCount,
                characterCount: pending.rawExtractStats.characterCount,
                lineCount: pending.rawExtractStats.lineCount
            ),
            warnings: pending.warnings.map {
                TripRawDebugSnapshot.ImportIssueSnapshot(code: $0.code.rawValue, message: $0.message, remediation: nil)
            },
            errors: pending.errors.map {
                TripRawDebugSnapshot.ImportIssueSnapshot(code: $0.code.rawValue, message: $0.message, remediation: $0.remediation)
            }
        )

        let cloudKitRepresentation = pending.parsedSchedule.map {
            TripRawDebugSnapshot.CloudKitScheduleRepresentation(
                recordType: "TDHSharedSchedule",
                field: "schedulesData",
                note: "Re-encoded here for readability alongside the rest of this snapshot; not a byte-exact copy of the CloudKit upload. See FriendScheduleCloudKitService.uploadSchedule.",
                payload: [$0]
            )
        }

        let tripSummaryEntry = CrewAccessTripSummaryStore.load().byTripID[pending.tripId].map {
            TripRawDebugSnapshot.HotelSummarySnapshot(
                tripId: $0.tripId,
                fileKey: $0.fileKey,
                creditTime: $0.creditTime,
                tripDays: $0.tripDays,
                tafb: $0.tafb,
                hotelByStation: $0.hotelByStation
            )
        }

        let relatedData = TripRawDebugSnapshot.RelatedData(
            manualEvents: buildRawSnapshotManualEvents(for: pending),
            tripSummaryStoreEntry: tripSummaryEntry
        )

        let allLegs = (pending.parsedSchedule?.legs ?? []) + (pending.parsedSchedule?.openTimeTrips.flatMap(\.legs) ?? [])
        let uniqueAirports = Set(allLegs.flatMap { [$0.depAirport, $0.arrAirport] }).sorted()
        let derivedData = TripRawDebugSnapshot.DerivedData(
            legCount: pending.parsedSchedule?.legs.count ?? 0,
            openTimeTripCount: pending.parsedSchedule?.openTimeTrips.count ?? 0,
            uniqueAirports: uniqueAirports,
            hasDeadheadLegs: pending.jsonPayload?.items.contains { $0.deadhead },
            airports: buildRawSnapshotAirports(for: pending)
        )

        let diagnostics = TripRawDebugSnapshot.Diagnostics(
            unavailableData: Self.rawSnapshotUnavailableData,
            mappingVersion: pending.jsonPayload?.mappingVersion
        )

        let bundleInfo = Bundle.main.infoDictionary
        let snapshot = TripRawDebugSnapshot(
            snapshotVersion: "1",
            generatedAt: Date(),
            generator: TripRawDebugSnapshot.Generator(
                appVersion: (bundleInfo?["CFBundleShortVersionString"] as? String) ?? "unknown",
                buildNumber: (bundleInfo?["CFBundleVersion"] as? String) ?? "unknown",
                snapshotSource: "TripRawDebugSnapshot"
            ),
            warning: "UNSTABLE DEBUG DIAGNOSTIC FORMAT. Field names, structure, and contents may change at any time. This is not the CloudKit sync payload and not the public Export JSON schema. Do not parse programmatically.",
            trip: tripSection,
            cloudKitScheduleRepresentation: cloudKitRepresentation,
            relatedData: relatedData,
            derivedData: derivedData,
            diagnostics: diagnostics
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            logNonFatal("Debug raw snapshot export failed: could not encode trip \(pending.tripId)")
            return nil
        }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let sanitizedTripId = pending.tripId.replacingOccurrences(of: "/", with: "-")
        let fileURL = documentsURL.appendingPathComponent("tripdatahub-raw-trip-\(sanitizedTripId).json")
        do {
            try data.write(to: fileURL, options: .atomic)
            logNonFatal("Debug raw trip snapshot written to \(fileURL.path)")
            return fileURL
        } catch {
            logNonFatal("Debug raw snapshot export failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clears persisted session cookies for UI tests that need a deterministic logged-out state.
    /// Without this, stale Keychain cookies cause syncTapped() to try performSync instead of
    /// immediately showing the login sheet, causing waitForExistence to time out.
    func clearSessionCookiesForUITest() {
        sessionCookies = []
    }
}
#endif
