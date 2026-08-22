import CloudKit
import XCTest
@testable import TripDataHub

/// The reported failure survives a relaunch of both devices, so the interesting window is startup
/// recovery — local load → remote fetch → merge → persist → fingerprint → upload.
///
/// These tests reproduce that window without any fixed `Task.sleep`: a device is torn down while
/// its save-triggered upload Task is still unstarted, then a fresh AppViewModel is built over the
/// same on-disk store and defaults suite.
@MainActor
final class ManualEventStartupRecoveryTests: XCTestCase {

    private var suiteNames: [String] = []
    private var directories: [URL] = []

    override func tearDown() {
        for suite in suiteNames { UserDefaults().removePersistentDomain(forName: suite) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        suiteNames = []
        directories = []
        super.tearDown()
    }

    // MARK: - Unsent event survives a relaunch

    /// Save, discard the view model before its upload Task can run, relaunch: startup recovery must
    /// publish the event.
    func test_unsentEventIsUploadedByStartupRecovery() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")

        // Offline at save time, so the save-triggered upload cannot succeed even if it runs.
        await cloud.setUploadsFailing(true)
        var device: Device? = try makeDevice(context: context, cloud: cloud)
        let event = try makePersonalEvent()
        try device?.viewModel.saveManualPersonalEvent(event)
        XCTAssertEqual(device?.viewModel.manualPersonalEvents.count, 1, "precondition: saved locally")
        device = nil // relaunch

        await cloud.setUploadsFailing(false)
        let relaunched = try makeDevice(context: context, cloud: cloud)
        XCTAssertEqual(
            relaunched.viewModel.manualPersonalEvents.map(\.id),
            [event.id],
            "the unsent event must still be in the local store after relaunch"
        )

        await relaunched.viewModel.recoverCloudSyncForTesting(reason: "startup")
        await awaitOrFail("event reaches CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
    }

    /// Startup fetch returns an older remote snapshot that does not contain the unsent event. The
    /// merge must not drop it, and the subsequent upload must still publish it.
    func test_startupFetchWithStaleRemote_keepsAndUploadsUnsentEvent() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")

        // Remote already holds an unrelated event from another device.
        let otherDeviceEvent = try makePersonalEvent()
        await cloud.seed(ManualEventStoreSnapshot(
            operationalEvents: [],
            personalEvents: [otherDeviceEvent],
            tombstones: []
        ))

        await cloud.setUploadsFailing(true)
        var device: Device? = try makeDevice(context: context, cloud: cloud)
        let unsent = try makePersonalEvent()
        try device?.viewModel.saveManualPersonalEvent(unsent)
        device = nil

        await cloud.setUploadsFailing(false)
        let relaunched = try makeDevice(context: context, cloud: cloud)
        await relaunched.viewModel.recoverCloudSyncForTesting(reason: "startup")

        await awaitOrFail("unsent event reaches CloudKit") {
            await cloud.waitUntilEventStored(id: unsent.id)
        }
        let storedSnapshot = await cloud.storedSnapshot()
        let stored = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(
            Set(stored.personalEvents.map(\.id)),
            Set([unsent.id, otherDeviceEvent.id]),
            "the merge must keep both the unsent local event and the remote one"
        )
    }

    // MARK: - Fingerprint must not suppress an unsent change

    func test_fingerprintIsNotAdvancedWhenUploadFails() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        await cloud.setUploadsFailing(true)

        let device = try makeDevice(context: context, cloud: cloud)
        let event = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(event)
        await device.viewModel.uploadManualEventsIfNeeded(reason: "will fail")

        let stored = context.defaults.string(forKey: "manual_event_last_upload_fingerprint_v1")
        XCTAssertNil(
            stored,
            "a failed upload must not record a fingerprint, otherwise the retry is suppressed"
        )

        await cloud.setUploadsFailing(false)
        await device.viewModel.uploadManualEventsIfNeeded(reason: "retry")
        await awaitOrFail("event reaches CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
    }

    /// A fingerprint left over from a build that encoded snapshots differently must not be mistaken
    /// for "already uploaded".
    func test_legacyFingerprintDoesNotSuppressFirstUpload() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        context.defaults.set("legacy-unsorted-key-fingerprint", forKey: "manual_event_last_upload_fingerprint_v1")

        let device = try makeDevice(context: context, cloud: cloud)
        let event = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(event)

        await awaitOrFail("event reaches CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
    }

    /// The fingerprint recorded after a successful upload must describe what actually landed, so a
    /// following no-op sync is correctly suppressed but a real change is not.
    func test_fingerprintAfterSuccessSuppressesOnlyUnchangedState() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        let device = try makeDevice(context: context, cloud: cloud)

        let first = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(first)
        await awaitOrFail("first event stored") { await cloud.waitUntilEventStored(id: first.id) }
        let attemptsAfterFirst = await cloud.uploadAttempts

        await device.viewModel.uploadManualEventsIfNeeded(reason: "no change")
        let attemptsAfterNoChange = await cloud.uploadAttempts
        XCTAssertEqual(attemptsAfterNoChange, attemptsAfterFirst, "unchanged state must not re-upload")

        let second = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(second)
        await awaitOrFail("second event stored") { await cloud.waitUntilEventStored(id: second.id) }
    }

    // MARK: - Identity

    /// `isIdentityVerified` requires the record name to match, so a nil record name blocks upload.
    /// This is the state a managed device is suspected of reaching.
    func test_missingRecordNameBlocksUploadAndIsDiagnosed() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        let device = try makeDevice(context: context, cloud: cloud, resolveIdentity: false)

        let event = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(event)
        await device.viewModel.uploadManualEventsIfNeeded(reason: "identity unresolved")

        let stored = await cloud.storedSnapshot()
        XCTAssertNil(stored, "precondition: nothing was uploaded")
        XCTAssertTrue(
            device.viewModel.diagnostics.entries.contains { $0.code == SyncDiagnosticCode.identityNotVerified.rawValue },
            "the silent guard must be visible in diagnostics"
        )
        XCTAssertTrue(
            device.viewModel.diagnostics.entries.contains { $0.code == SyncDiagnosticCode.recordNameMissing.rawValue },
            "the missing record-name reason must be distinguishable from other identity failures"
        )
    }

    /// Once identity resolves, the previously blocked event must be published.
    func test_uploadResumesAfterIdentityBecomesAvailable() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        let device = try makeDevice(context: context, cloud: cloud, resolveIdentity: false)

        let event = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(event)
        await device.viewModel.uploadManualEventsIfNeeded(reason: "identity unresolved")
        let blockedSnapshot = await cloud.storedSnapshot()
        XCTAssertNil(blockedSnapshot, "precondition: blocked")

        device.viewModel.currentCloudKitRecordName = context.recordName
        XCTAssertTrue(device.viewModel.isIdentityVerified, "precondition: identity now resolves")

        await device.viewModel.recoverCloudSyncForTesting(reason: "identity resolved")
        await awaitOrFail("event reaches CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
    }

    // MARK: - Tombstone vs new event

    /// A tombstone must not remove an unrelated newly created event.
    func test_remoteTombstoneDoesNotDropUnrelatedNewEvent() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")

        let deletedElsewhere = try makePersonalEvent()
        await cloud.seed(ManualEventStoreSnapshot(
            operationalEvents: [],
            personalEvents: [],
            tombstones: [ManualEventTombstone(id: deletedElsewhere.id, deletedAt: Date())]
        ))

        let device = try makeDevice(context: context, cloud: cloud)
        let fresh = try makePersonalEvent()
        try device.viewModel.saveManualPersonalEvent(fresh)
        await device.viewModel.recoverCloudSyncForTesting(reason: "startup")

        XCTAssertEqual(
            device.viewModel.manualPersonalEvents.map(\.id),
            [fresh.id],
            "an unrelated tombstone must not drop a newly created event"
        )
        await awaitOrFail("fresh event stored") { await cloud.waitUntilEventStored(id: fresh.id) }
    }

    // MARK: - Diagnostics content

    func test_startupRecoveryIsBracketedInDiagnostics() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        let device = try makeDevice(context: context, cloud: cloud)

        await device.viewModel.recoverCloudSyncForTesting(reason: "startup")

        let codes = device.viewModel.diagnostics.entries.map(\.code)
        XCTAssertTrue(codes.contains(SyncDiagnosticCode.startupRecoveryBegan.rawValue))
        XCTAssertTrue(codes.contains(SyncDiagnosticCode.startupRecoveryEnded.rawValue))
        XCTAssertTrue(codes.contains(SyncDiagnosticCode.fetchStarted.rawValue))
    }

    func test_diagnosticsNeverContainEventContent() async throws {
        let cloud = SharedRecoveryCloud()
        let context = try makeContext(name: "UPS")
        let device = try makeDevice(context: context, cloud: cloud)

        let event = try makePersonalEvent(notes: "SECRET-NOTE-STRING")
        try device.viewModel.saveManualPersonalEvent(event)
        await device.viewModel.recoverCloudSyncForTesting(reason: "startup")

        let text = device.viewModel.diagnostics.exportText()
        XCTAssertFalse(text.contains("SECRET-NOTE-STRING"), "notes must never be recorded")
        XCTAssertFalse(text.contains(event.id.uuidString), "raw event ids must never be recorded")
        XCTAssertFalse(text.contains(context.gemsID), "the full GEMS ID must never be recorded")
        XCTAssertFalse(text.contains(context.recordName), "the full record name must never be recorded")
    }

    func test_diagnosticsRingBufferIsBounded() {
        let log = SyncDiagnosticsLog(directory: nil, capacity: 5)
        for index in 0..<20 {
            log.record(.uploadRequested, ["i": String(index)])
        }
        XCTAssertEqual(log.entries.count, 5)
        XCTAssertEqual(log.entries.last?.fields["i"], "19", "the newest entries are kept")
    }

    func test_clearDiagnosticsEmptiesTheBuffer() {
        let log = SyncDiagnosticsLog(directory: nil, capacity: 10)
        log.record(.uploadStarted, [:])
        XCTAssertFalse(log.entries.isEmpty)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    // MARK: - Harness

    private struct Context {
        let directory: URL
        let suiteName: String
        let defaults: UserDefaults
        let gemsID: String
        var recordName: String { "_cloudkit_record_\(gemsID)" }
    }

    private struct Device {
        let viewModel: AppViewModel
    }

    private func makeContext(name: String, gemsID: String = "7793942") throws -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualEventRecovery-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "ManualEventRecovery.\(name).\(UUID().uuidString)"
        directories.append(directory)
        suiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return Context(directory: directory, suiteName: suiteName, defaults: defaults, gemsID: gemsID)
    }

    private func makeDevice(
        context: Context,
        cloud: SharedRecoveryCloud,
        resolveIdentity: Bool = true
    ) throws -> Device {
        let viewModel = AppViewModel(
            cacheService: RecoveryCacheService(),
            friendScheduleCloudKitService: RecoveryFriendService(),
            deviceScheduleCloudKitService: RecoveryDeviceScheduleService(),
            manualEventCloudKitService: RecoveryManualEventService(cloud: cloud),
            crewAccessImportCloudKitService: RecoveryCrewAccessImportService(),
            manualEventStore: ManualEventStore(defaults: context.defaults, directory: context.directory),
            syncStateDefaults: context.defaults,
            crewAccessImportsDirectory: context.directory.appendingPathComponent(
                "CrewAccessImports",
                isDirectory: true
            ),
            diagnostics: SyncDiagnosticsLog(directory: nil, capacity: 500)
        )
        viewModel.verifiedIdentity = VerifiedIdentityProfile(
            cloudKitRecordName: context.recordName,
            name: "Test Pilot",
            gemsID: context.gemsID,
            domicile: "ANC",
            equipment: "747",
            seat: "CA",
            dateOfHire: "2000-01-01",
            isAdminEligible: false,
            adminPolicyFingerprint: nil,
            verifiedAt: Date()
        )
        // resolveIdentity == false models a device where CloudKit never produced a user record
        // name, so isIdentityVerified stays false.
        viewModel.currentCloudKitRecordName = resolveIdentity ? context.recordName : nil
        return Device(viewModel: viewModel)
    }

    private func makePersonalEvent(notes: String? = nil) throws -> ManualPersonalEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return try ManualPersonalEvent(
            id: UUID(),
            code: .commute,
            startUTC: start,
            endUTC: start.addingTimeInterval(3600),
            notes: notes,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Failure guard only; ordering comes from the awaited condition.
    private func awaitOrFail(
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            XCTFail("Timed out after \(timeout)s waiting for \(description)", file: file, line: line)
        }
    }
}

// MARK: - Shared fake record

private actor SharedRecoveryCloud {
    private var stored: ManualEventStoreSnapshot?
    private var lastDeviceID = ""
    private var serverTick: TimeInterval = 0
    private var uploadsFailing = false
    private(set) var uploadAttempts = 0

    private struct Waiter {
        let predicate: (ManualEventStoreSnapshot?) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []

    private let serverEpoch = Date(timeIntervalSince1970: 1_000_000)

    func setUploadsFailing(_ failing: Bool) { uploadsFailing = failing }
    func storedSnapshot() -> ManualEventStoreSnapshot? { stored }

    func seed(_ snapshot: ManualEventStoreSnapshot) {
        stored = snapshot
        serverTick += 1
        signal()
    }

    func waitUntilEventStored(id: UUID) async {
        let isDone: (ManualEventStoreSnapshot?) -> Bool = { snapshot in
            guard let snapshot else { return false }
            return snapshot.personalEvents.contains { $0.id == id }
                || snapshot.operationalEvents.contains { $0.id == id }
        }
        if isDone(stored) { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(predicate: isDone, continuation: continuation))
        }
    }

    private func signal() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(stored) { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        waiters = remaining
    }

    func upload(snapshot: ManualEventStoreSnapshot, deviceID: String) throws -> ManualEventStoreSnapshot {
        uploadAttempts += 1
        if uploadsFailing { throw CKError(.networkFailure) }
        let merged = stored.map { mergeManualEventSnapshots(local: snapshot, remote: $0) } ?? snapshot
        stored = merged
        lastDeviceID = deviceID
        serverTick += 1
        signal()
        return merged
    }

    func fetch() -> ManualEventCloudKitSnapshot? {
        guard let stored else { return nil }
        return ManualEventCloudKitSnapshot(
            ownerGEMSID: "7793942",
            ownerRecordName: "_rec",
            manualEvents: stored,
            schemaVersion: 1,
            updatedAt: serverEpoch.addingTimeInterval(serverTick),
            deviceID: lastDeviceID,
            source: .ipad
        )
    }
}

private struct RecoveryManualEventService: ManualEventCloudKitServicing {
    let cloud: SharedRecoveryCloud

    @discardableResult
    func uploadManualEvents(
        gemsID: String,
        cloudKitRecordName: String,
        snapshot: ManualEventStoreSnapshot,
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws -> ManualEventStoreSnapshot {
        try await cloud.upload(snapshot: snapshot, deviceID: deviceID)
    }

    func fetchManualEvents(gemsID: String) async throws -> ManualEventCloudKitSnapshot? {
        await cloud.fetch()
    }
}

private struct RecoveryDeviceScheduleService: DeviceScheduleCloudKitServicing {
    func uploadDeviceSchedule(
        gemsID: String,
        cloudKitRecordName: String,
        schedules: [PayPeriodSchedule],
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws {}

    func fetchDeviceSchedule(gemsID: String) async throws -> DeviceScheduleSnapshot? {
        nil
    }
}

private struct RecoveryCrewAccessImportService: CrewAccessImportCloudKitServicing {
    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {}

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        []
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {}
}

private final class RecoveryCacheService: ScheduleCacheServiceProtocol, @unchecked Sendable {
    private var snapshot: ScheduleCacheSnapshotV2?
    func load() -> ScheduleCacheSnapshotV2? { snapshot }
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private struct RecoveryFriendService: FriendScheduleCloudKitServicing {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {}
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}
    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date?) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(friendGEMSID: friendGEMSID, isAccepted: false, linkedAt: nil, requestedAt: Date())
    }
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func deleteSharedScheduleData(gemsID: String) async throws {}
    func deleteFriendSharingData(gemsID: String) async throws {}
    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date?) async throws -> FriendConnectionRefreshResult {
        FriendConnectionRefreshResult(connections: connections)
    }
}
