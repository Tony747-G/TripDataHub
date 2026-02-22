import Foundation
import CloudKit
import UserNotifications
import CryptoKit

enum AuthStatus: String {
    case unknown
    case loggedOut
    case loggedIn
}

struct CrewAccessImportFile: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let fileName: String
    let url: URL
    let bytes: Int64
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

    func finish(key: String, success: Bool) {
        inflightKeys.remove(key)
        if success {
            recentProcessedKeys[key] = Date()
        }
    }

    func removeQueued(key: String) {
        queue.removeAll { $0.key == key }
        queuedKeys.remove(key)
    }

    /// Clears all dedup history so the same file can be re-shared immediately
    /// after an import is confirmed or discarded.
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

@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()

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
    @Published var isAdmin = false
    @Published var currentCloudKitRecordName: String?
    @Published var seniorityRecords: [PilotSeniorityRecord] = []
    @Published var seniorityImportMessage: String?
    @Published var verifiedIdentity: VerifiedIdentityProfile?
    @Published var verifiedUsers: [VerifiedUserRecord] = []
    @Published var crewAccessImportMessage: String?
    @Published var crewAccessDeleteMessage: String?
    @Published var lastImportDidReplaceExistingTrip: Bool = false
    @Published var lastImportSummaryMessage: String?
    @Published var pendingImport: PendingImport?
    @Published var pendingExternalOpenURL: URL?
    @Published var isDeletingCrewAccessTrips = false
    @Published var hasLoadedSeniorityRecords = false
    @Published private(set) var isRefreshingCloudKitIdentity = false
    @Published private(set) var hasSeniorityDataOnDisk = false

    private let syncService: TripBoardSyncServiceProtocol
    private let authService: TripBoardAuthServiceProtocol
    private let cacheService: ScheduleCacheServiceProtocol
    private let notificationService: NextReportNotificationServiceProtocol
    private let crewAccessImportService: CrewAccessPDFImportServiceProtocol
    private let externalOpenCoordinator: ExternalOpenImportCoordinator
    private var sessionCookies: [HTTPCookie] = []
    private var lastAutoFetchAt: Date?
    private var externalConsumerTask: Task<Void, Never>?

    private let notification48hKey = "notification_48h_enabled"
    private let notification24hKey = "notification_24h_enabled"
    private let notification12hKey = "notification_12h_enabled"
    private let friendConnectionsKey = "friend_connections_v1"
    private let seniorityRecordsKey = "pilot_seniority_records_v1"
    // Legacy keys/file names kept only for one-time migration from older builds.
    private let legacySeniorityRecordsKey = "pilot_roster_records_v1"
    private let verifiedIdentityKey = "verified_identity_profile_v1"
    private let verifiedUsersKey = "verified_users_v1"
    private let seniorityFileName = "pilot_seniority_records_v1.json"
    private let legacySeniorityFileName = "pilot_roster_records_v1.json"
    private let localIdentityRecordNameKey = "local_identity_record_name_v1"
    // Temporary safety switch: CloudKit identity call is hanging in current runtime.
    // Set to true after confirming CKContainer.userRecordID() returns reliably.
    private let useCloudKitIdentity = false
    // Internal testing fallback:
    // when true, users can verify with entered GEMS ID + DOB even if Seniority DB is not loaded.
    // This never grants admin eligibility.
    private let allowVerificationWithoutSeniorityDB = true
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
        crewAccessImportService: CrewAccessPDFImportServiceProtocol = CrewAccessPDFImportService()
    ) {
        self.syncService = syncService
        self.authService = authService
        self.cacheService = cacheService
        self.notificationService = notificationService
        self.crewAccessImportService = crewAccessImportService
        self.externalOpenCoordinator = ExternalOpenImportCoordinator.shared
        let loadedAdminPolicy = Self.loadAdminPolicy()
        self.adminPolicy = loadedAdminPolicy
        self.adminPolicyFingerprint = Self.fingerprint(for: loadedAdminPolicy)

        let cached = cacheService.load()
        let cachedCrewAccessSchedules = cached?.crewAccessSchedules ?? []
        let cachedBidproSchedules = cached?.bidproSchedules ?? []
        self.crewAccessSchedules = cachedCrewAccessSchedules
        self.bidproSchedules = cachedBidproSchedules
        self.schedules = mergeAndSortSchedules(crew: cachedCrewAccessSchedules, bidpro: cachedBidproSchedules)
        self.lastSyncAt = cached?.lastSyncAt
        self.sessionCookies = authService.loadPersistedCookies()
        self.authStatus = authService.isAuthenticated(url: nil, cookies: sessionCookies) ? .loggedIn : .loggedOut
        self.friendConnections = loadFriendConnections()
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
        self.verifiedUsers = loadVerifiedUsers()
        if !useCloudKitIdentity {
            self.currentCloudKitRecordName = localIdentityRecordName()
        }
        self.updateAdminStatus()
        if self.authStatus == .loggedIn, errorMessage == SyncServiceError.notAuthenticated.localizedDescription {
            errorMessage = nil
        }

        Task { [weak self] in
            await self?.refreshNotificationAuthorizationStatus()
            await self?.rescheduleNotificationsIfAuthorized()
        }

#if DEBUG
        logNonFatal("Cache restore (v2): crew=\(cachedCrewAccessSchedules.count) bidpro=\(cachedBidproSchedules.count)")
#endif
        NSLog("[VM] init vm=%@", String(describing: ObjectIdentifier(self)))
    }

    deinit {
        NSLog("[VM] deinit vm=%@", String(describing: ObjectIdentifier(self)))
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
        guard let verifiedIdentity, let currentCloudKitRecordName else { return false }
        return verifiedIdentity.cloudKitRecordName == currentCloudKitRecordName
    }

    var seniorityCount: Int { seniorityRecords.count }

    var canAccessAdminTab: Bool {
        isAdmin
    }

    func loadSeniorityRecordsIfNeeded() async {
        guard !hasLoadedSeniorityRecords else { return }
        await loadSeniorityRecordsAsync()
    }

    func submitPseudoFriendRequest(employeeID rawEmployeeID: String) {
        guard isIdentityVerified else {
            friendActionMessage = "Verify your identity first (GEMS ID + DOB)."
            return
        }
        let employeeID = rawEmployeeID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !employeeID.isEmpty else {
            friendActionMessage = "GEMS ID is required."
            return
        }
        if let index = friendConnections.firstIndex(where: { $0.employeeID == employeeID }) {
            if friendConnections[index].status == .pending {
                friendConnections[index].status = .accepted
                friendConnections[index].linkedAt = Date()
                friendConnections[index].sharedSchedules = buildPseudoFriendSchedules(for: employeeID)
                saveFriendConnections()
                friendActionMessage = "Friend linked: \(employeeID)"
            } else {
                friendActionMessage = "Friend already linked: \(employeeID)"
            }
            return
        }
        // Internal-friend testing mode:
        // requests are auto-approved once the current user has verified GEMS ID + DOB.
        var request = FriendConnection(employeeID: employeeID, status: .accepted)
        request.linkedAt = Date()
        request.sharedSchedules = buildPseudoFriendSchedules(for: employeeID)
        friendConnections.append(request)
        saveFriendConnections()
        friendActionMessage = "Friend linked: \(employeeID)"
    }

    func approvePseudoFriendRequest(_ id: UUID) {
        guard let index = friendConnections.firstIndex(where: { $0.id == id }) else { return }
        guard friendConnections[index].status == .pending else { return }
        friendConnections[index].status = .accepted
        friendConnections[index].linkedAt = Date()
        friendConnections[index].sharedSchedules = buildPseudoFriendSchedules(for: friendConnections[index].employeeID)
        saveFriendConnections()
        friendActionMessage = "Friend linked: \(friendConnections[index].employeeID)"
    }

    func rejectPseudoFriendRequest(_ id: UUID) {
        guard let index = friendConnections.firstIndex(where: { $0.id == id }) else { return }
        let employeeID = friendConnections[index].employeeID
        friendConnections.remove(at: index)
        saveFriendConnections()
        friendActionMessage = "Request rejected: \(employeeID)"
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

        enum IdentityFetchError: Error {
            case timeout
        }

        Task.detached(priority: .utility) { [weak self] in
            let result: Result<String, Error> = await withTaskGroup(of: Result<String, Error>.self) { group in
                group.addTask {
                    do {
                        let recordID = try await CKContainer.default().userRecordID()
                        return .success(recordID.recordName)
                    } catch {
                        return .failure(error)
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return .failure(IdentityFetchError.timeout)
                }
                let first = await group.next() ?? .failure(IdentityFetchError.timeout)
                group.cancelAll()
                return first
            }

            Task { @MainActor [weak self] in
                guard let self, self.isRefreshingCloudKitIdentity else { return }
                self.isRefreshingCloudKitIdentity = false

                switch result {
                case let .success(recordName):
                    self.currentCloudKitRecordName = recordName
                    if let verifiedIdentity = self.verifiedIdentity,
                       verifiedIdentity.cloudKitRecordName != recordName {
                        self.verifiedIdentity = nil
                        self.clearVerifiedIdentity()
                    }
                    self.updateAdminStatus()
                case let .failure(error):
                    self.currentCloudKitRecordName = nil
                    self.updateAdminStatus()
                    if (error as? IdentityFetchError) == .timeout {
                        self.logNonFatal("CloudKit identity fetch timed out.")
                    } else {
                        self.logNonFatal("Failed to fetch CloudKit identity: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @discardableResult
    func importSeniorityCSVData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            seniorityImportMessage = "Failed to decode CSV as UTF-8."
            return false
        }

        let parsedRecords = parseSeniorityCSV(text)
        guard !parsedRecords.isEmpty else {
            seniorityImportMessage = "No valid seniority records found."
            return false
        }

        seniorityRecords = parsedRecords
        hasLoadedSeniorityRecords = true
        do {
            try Self.saveSeniorityRecordsToDisk(records: parsedRecords, seniorityFileName: seniorityFileName)
            hasSeniorityDataOnDisk = true
            seniorityImportMessage = "Imported \(parsedRecords.count) seniority records."
            return true
        } catch {
            hasSeniorityDataOnDisk = false
            seniorityImportMessage = "Imported in memory, but failed to save Seniority DB: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func importCrewAccessPDFData(_ data: Data, sourceFileName: String?) -> Bool {
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
        let draft = crewAccessImportService.analyzeTrip(pdfData: data, sourceFileName: sourceFileName)
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
        let key = stableExternalKey(for: url)
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
            guard let self else { return }
            await self.externalConsumerLoop()
        }
        NSLog("[Import] externalConsumer start")
    }

    private func externalConsumerLoop() async {
        while true {
            guard let nextItem = await externalOpenCoordinator.dequeueNext() else {
                pendingExternalOpenURL = nil
                externalConsumerTask = nil
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
                await externalOpenCoordinator.finish(key: key, success: false)
                pendingExternalOpenURL = nil
                NSLog("[Import] consumeExternalOpenURL done key=%@ ok=%@", key, String(isSuccess))
                continue
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
                    continue
                }
                _ = importCrewAccessPDFData(data, sourceFileName: url.lastPathComponent)
                if pendingImport != nil {
                    await externalOpenCoordinator.removeQueued(key: key)
                    cleanupInboxFileBestEffort(at: url)
                    isSuccess = true
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
            return
        }

        do {
            let replacing = crewAccessSchedules.contains(where: { $0.id == schedule.id })
            let jsonWriteContext = try persistCrewAccessJSON(json)
            do {
                try mergeImportedCrewAccessSchedule(schedule)
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
            await resetExternalOpenDedup()
            importInProgress = false
            crewAccessImportMessage = "CrewAccess import complete: \(json.tripId) (\(schedule.legCount) legs)."
            errorMessage = nil
        } catch {
            crewAccessImportMessage = "Import failed: unable to write CrewAccess JSON. No changes were applied."
            logNonFatal("CrewAccess confirm transaction failed: \(error.localizedDescription)")
            importInProgress = false
        }
    }

    func discardPendingImport() async {
        pendingImport = nil
        crewAccessImportMessage = "CrewAccess import preview discarded."
        await resetExternalOpenDedup()
        importInProgress = false
    }

    private struct CrewAccessTripHeader: Decodable {
        let tripId: String?
        let tripInformationDate: String?
    }

    private struct CrewAccessScheduleReference: Hashable {
        let id: String
        let label: String
    }

    private struct CrewAccessFileDeletionResult {
        let deleted: Bool
        let tripId: String?
        let tripInformationDate: String?
        let matchedScheduleIDs: [String]
    }

    func listCrewAccessImportFiles() async -> [CrewAccessImportFile] {
        let scheduleReferences = crewAccessSchedules.map {
            CrewAccessScheduleReference(id: $0.id, label: $0.label)
        }
        return await Task.detached(priority: .utility) { () -> [CrewAccessImportFile] in
            let fm = FileManager.default
            guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
            let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { return [] }

            do {
                let urls = try fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                return urls.compactMap { url in
                    guard let values = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                    ) else {
                        return nil
                    }
                    guard values.isRegularFile == true, url.pathExtension.lowercased() == "json" else { return nil }
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
                    let displayName = "\(displayDateResult.dateString)_\(tripId) (\(tripId))"
                    let matchedScheduleId = Self.matchScheduleID(
                        tripId: tripId,
                        scheduleReferences: scheduleReferences
                    )
                    return CrewAccessImportFile(
                        fileName: fileName,
                        url: url,
                        bytes: Int64(values.fileSize ?? 0),
                        modifiedAt: modifiedAt,
                        tripId: tripId,
                        tripInformationDate: header?.tripInformationDate,
                        displayName: displayName,
                        usedFallbackDate: displayDateResult.usedFallback,
                        matchedScheduleId: matchedScheduleId,
                        isOrphan: matchedScheduleId == nil
                    )
                }.sorted { lhs, rhs in
                    (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
                }
            } catch {
                return [CrewAccessImportFile]()
            }
        }.value
    }

    func deleteCrewAccessImportFiles(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard !isDeletingCrewAccessTrips else { return }

        isDeletingCrewAccessTrips = true
        crewAccessDeleteMessage = nil
        defer { isDeletingCrewAccessTrips = false }

        NSLog("[CrewAccessFileDelete] start files=%d", urls.count)
        let scheduleReferences = crewAccessSchedules.map {
            CrewAccessScheduleReference(id: $0.id, label: $0.label)
        }

        let deletionResults = await Task.detached(priority: .utility) {
            Self.deleteCrewAccessImportFilesAndCollectMatches(
                targetURLs: urls,
                scheduleReferences: scheduleReferences
            )
        }.value

        let scheduleIDsToRemove = Set(deletionResults.flatMap(\.matchedScheduleIDs))
        let removedSchedulesCount = crewAccessSchedules.filter { scheduleIDsToRemove.contains($0.id) }.count
        if removedSchedulesCount > 0 {
            crewAccessSchedules.removeAll { scheduleIDsToRemove.contains($0.id) }
        }
        schedules = mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)
        NSLog("[CrewAccessFileDelete] removedSchedules=%d", removedSchedulesCount)

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
        if removedSchedulesCount > 0 {
            crewAccessDeleteMessage = "Deleted \(deletedFileCount) file(s). Removed \(removedSchedulesCount) trip(s) from Timeline."
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

        crewAccessSchedules.removeAll { ids.contains($0.id) }
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
    }

    func displaySchedules(filter: TimelineSourceFilter) -> [PayPeriodSchedule] {
        switch filter {
        case .crewAccess:
            return crewAccessSchedules
        case .tripBoard:
            return bidproSchedules
        }
    }

    func importSeniorityCSVFromDocuments(named preferredFileName: String = "ups_sen.csv") {
        let fm = FileManager.default
        guard let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            seniorityImportMessage = "Documents directory is unavailable."
            return
        }

        let preferredURL = documentsURL.appendingPathComponent(preferredFileName)
        if fm.fileExists(atPath: preferredURL.path) {
            do {
                let data = try Data(contentsOf: preferredURL)
                if importSeniorityCSVData(data) {
                    seniorityImportMessage = "Imported from Documents/\(preferredFileName)."
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
                if importSeniorityCSVData(data) {
                    seniorityImportMessage = "Imported from Documents/\(firstCSV.lastPathComponent)."
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
        let isReplacement = updatedCrewAccess.contains(where: { $0.id == imported.id })
        if let index = updatedCrewAccess.firstIndex(where: { $0.id == imported.id }) {
            let existing = updatedCrewAccess[index]
            let importedPairings = Set(imported.legs.map(\.pairing))
            let keptLegs = existing.legs.filter { !importedPairings.contains($0.pairing) }
            let mergedLegs = (keptLegs + imported.legs).sorted { lhs, rhs in
                let lhsUTC = lhs.depUTC ?? ""
                let rhsUTC = rhs.depUTC ?? ""
                if lhsUTC == rhsUTC {
                    return lhs.leg < rhs.leg
                }
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
        schedules = updatedAll
        if lastSyncAt == nil {
            lastSyncAt = persistedLastSyncAt
        }
#if DEBUG
        logNonFatal("CrewAccess merge completed. replacement=\(isReplacement) scheduleId=\(imported.id)")
#endif
    }

    private enum ExternalOpenError: Error {
        case securityScopeDenied
        case fileReadFailed
    }

    private enum ExternalOpenReadTimeoutError: Error {
        case timedOut
    }

    private func stableExternalKey(for url: URL) -> String {
        // Key on file content identity (size + mtime) rather than path, so that iOS delivering
        // the same PDF via different paths (tmp original vs Inbox copy, or "in place" vs copy mode)
        // all map to the same dedup key and only the first delivery is processed.
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "size:\(bytes)|mtime:\(Int64(modified))"
        } catch {
            return resolvedURL.absoluteString
        }
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
        return "sha256:\(hashString)|bytes:\(data.count)"
    }

    /// Claims a cross-launch fingerprint in UserDefaults. Returns false if the same content
    /// was already imported in this launch or a recent previous launch (TTL 30s).
    /// `importInProgress` handles same-launch re-entrancy; this handles app-restart edge cases.
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
        guard didStartScopedAccess else {
            throw ExternalOpenError.securityScopeDenied
        }
        defer { originalURL.stopAccessingSecurityScopedResource() }

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

    private func cleanupInboxFileBestEffort(at url: URL) {
        let normalizedPath = url.standardizedFileURL.path
        let inboxPathToken = "/Documents/Inbox/"
        guard normalizedPath.contains(inboxPathToken) else {
            NSLog("[Import] cleanupInbox skip (not inbox) url=%@", url.absoluteString)
            return
        }

        NSLog("[Import] cleanupInbox start path=%@", normalizedPath)
        do {
            try FileManager.default.removeItem(at: url)
            NSLog("[Import] cleanupInbox deleted path=%@", normalizedPath)
        } catch {
            NSLog("[Import] cleanupInbox failed path=%@ error=%@", normalizedPath, error.localizedDescription)
        }
    }

    private nonisolated static func readCrewAccessTripHeader(from url: URL) -> CrewAccessTripHeader? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrewAccessTripHeader.self, from: data)
    }

    private nonisolated static func inferTripIdFromFileName(_ fileName: String) -> String {
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
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
            ref.id == tripId || ref.label.contains(tripId)
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
                        ref.id == tripId || ref.label.contains(tripId)
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
        let fileName = "\(safeTripID)_\(payload.tripInformationDate).json"
        let finalURL = dir.appendingPathComponent(fileName)

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: finalURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw NSError(
                domain: "CrewAccessImport",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "JSON output path is a directory: \(finalURL.path)"]
            )
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

    func verifyIdentity(gemsID rawGemsID: String, dateOfBirth rawDateOfBirth: String) {
        guard let currentCloudKitRecordName else {
            friendActionMessage = "Apple identity is unavailable. Sign into iCloud first."
            return
        }

        let gemsID = rawGemsID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let dobInput = rawDateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gemsID.isEmpty, !dobInput.isEmpty else {
            friendActionMessage = "GEMS ID and DOB are required."
            return
        }
        guard let normalizedDOB = normalizeDOB(dobInput) else {
            friendActionMessage = "DOB format must be MM/DD/YYYY."
            return
        }

        if seniorityRecords.isEmpty {
            guard allowVerificationWithoutSeniorityDB else {
                friendActionMessage = "Seniority DB is empty. Ask admin to import the CSV."
                return
            }

            let verified = VerifiedIdentityProfile(
                cloudKitRecordName: currentCloudKitRecordName,
                name: "Internal Tester",
                gemsID: gemsID,
                domicile: "-",
                equipment: "-",
                seat: "-",
                dateOfHire: "-",
                isAdminEligible: false,
                adminPolicyFingerprint: adminPolicyFingerprint,
                verifiedAt: Date()
            )
            verifiedIdentity = verified
            saveVerifiedIdentity(verified)
            upsertVerifiedUser(
                VerifiedUserRecord(
                    identityRecordName: currentCloudKitRecordName,
                    name: verified.name,
                    gemsID: verified.gemsID,
                    domicile: verified.domicile,
                    equipment: verified.equipment,
                    seat: verified.seat,
                    verifiedAt: Date()
                )
            )
            autoApprovePendingFriendRequests(for: gemsID)
            updateAdminStatus()
            friendActionMessage = "Verified for internal test as GEMS \(gemsID)."
            return
        }

        guard let record = seniorityRecords.first(where: {
            $0.gemsID == gemsID && normalizeDOB($0.dateOfBirth) == normalizedDOB
        }) else {
            friendActionMessage = "Verification failed. Check GEMS ID / DOB."
            return
        }

        let verified = VerifiedIdentityProfile(
            cloudKitRecordName: currentCloudKitRecordName,
            name: record.name,
            gemsID: record.gemsID,
            domicile: record.domicile,
            equipment: record.equipment,
            seat: record.seat,
            dateOfHire: record.dateOfHire,
            isAdminEligible: isAdminEligible(gemsID: record.gemsID, dob: normalizedDOB),
            adminPolicyFingerprint: adminPolicyFingerprint,
            verifiedAt: Date()
        )
        verifiedIdentity = verified
        saveVerifiedIdentity(verified)
        upsertVerifiedUser(
            VerifiedUserRecord(
                identityRecordName: currentCloudKitRecordName,
                name: record.name,
                gemsID: record.gemsID,
                domicile: record.domicile,
                equipment: record.equipment,
                seat: record.seat,
                verifiedAt: Date()
            )
        )
        autoApprovePendingFriendRequests(for: record.gemsID)
        updateAdminStatus()
        friendActionMessage = "Verified as \(record.name) (\(record.gemsID))."
    }

    private func autoApprovePendingFriendRequests(for employeeID: String) {
        var changed = false
        for index in friendConnections.indices {
            guard friendConnections[index].employeeID == employeeID,
                  friendConnections[index].status == .pending else { continue }
            friendConnections[index].status = .accepted
            friendConnections[index].linkedAt = Date()
            friendConnections[index].sharedSchedules = buildPseudoFriendSchedules(for: employeeID)
            changed = true
        }
        if changed {
            saveFriendConnections()
        }
    }

    func syncTapped() async {
        guard isIdentityVerified else {
            errorMessage = verificationRequiredMessage
            return
        }
        guard !isSyncing else { return }
        errorMessage = nil
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
            bidproSchedules = result
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
            return try JSONDecoder().decode([FriendConnection].self, from: data)
        } catch {
            logNonFatal("Failed to decode friend connections: \(error.localizedDescription)")
            return []
        }
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
            return try JSONDecoder().decode(VerifiedIdentityProfile.self, from: data)
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

    private func loadVerifiedUsers() -> [VerifiedUserRecord] {
        guard let data = UserDefaults.standard.data(forKey: verifiedUsersKey) else { return [] }
        do {
            return try JSONDecoder().decode([VerifiedUserRecord].self, from: data)
        } catch {
            logNonFatal("Failed to decode verified users: \(error.localizedDescription)")
            return []
        }
    }

    private func saveVerifiedUsers() {
        do {
            let data = try JSONEncoder().encode(verifiedUsers)
            UserDefaults.standard.set(data, forKey: verifiedUsersKey)
        } catch {
            logNonFatal("Failed to save verified users: \(error.localizedDescription)")
        }
    }

    private func upsertVerifiedUser(_ record: VerifiedUserRecord) {
        if let index = verifiedUsers.firstIndex(where: { $0.id == record.id }) {
            verifiedUsers[index] = record
        } else {
            verifiedUsers.append(record)
        }
        verifiedUsers.sort { $0.verifiedAt > $1.verifiedAt }
        saveVerifiedUsers()
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
        let normalizedGems = gemsID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return adminPolicy.gemsIDAllowlist.contains(normalizedGems)
            && adminPolicy.dobAllowlist.contains(canonicalDOB)
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
        let gems = policy.gemsIDAllowlist.sorted().joined(separator: ",")
        let dobs = policy.dobAllowlist.sorted().joined(separator: ",")
        let payload = "gems:\(gems)|dobs:\(dobs)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadAdminPolicy() -> AdminPolicy {
        guard let url = Bundle.main.url(forResource: "AdminPolicy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(AdminPolicyRaw.self, from: data)
        else {
            return AdminPolicy(gemsIDAllowlist: [], dobAllowlist: [])
        }

        let gems = Set(raw.adminGemsIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
        let dobs = Set(raw.adminDOBs.compactMap(normalizeDOBStatic))
        return AdminPolicy(gemsIDAllowlist: gems, dobAllowlist: dobs)
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

    private func parseSeniorityCSV(_ text: String) -> [PilotSeniorityRecord] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { return [] }

        let headerFields = parseCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let headerMap = Dictionary(uniqueKeysWithValues: headerFields.enumerated().map { ($0.element, $0.offset) })
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
            let gems = fields[gemsIndex].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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

    private func buildPseudoFriendSchedules(for employeeID: String) -> [PayPeriodSchedule] {
        if !schedules.isEmpty {
            return schedules
        }
#if DEBUG
        if !Self.previewSchedules.isEmpty {
            return Self.previewSchedules
        }
#endif
        let syntheticLeg = TripLeg(
            payPeriod: "PP-SAMPLE",
            pairing: "F\(employeeID)",
            leg: 1,
            flight: "123",
            depAirport: "ANC",
            depLocal: "2026-02-18 08:00",
            arrAirport: "SEA",
            arrLocal: "2026-02-18 12:10",
            status: "-",
            block: "4:10"
        )
        let syntheticSchedule = PayPeriodSchedule(
            id: "PP-SAMPLE",
            label: "PP-SAMPLE",
            tripCount: 1,
            legCount: 1,
            openTimeCount: 0,
            updatedAt: Date(),
            legs: [syntheticLeg],
            openTimeTrips: []
        )
        return [syntheticSchedule]
    }
}

private struct AdminPolicy {
    let gemsIDAllowlist: Set<String>
    let dobAllowlist: Set<String>
}

private struct AdminPolicyRaw: Decodable {
    let adminGemsIDs: [String]
    let adminDOBs: [String]
}

#if DEBUG
extension AppViewModel {
    static func previewMock() -> AppViewModel {
        let vm = AppViewModel()
        vm.schedules = Self.previewSchedules
        vm.authStatus = .loggedIn
        return vm
    }
}
#endif
