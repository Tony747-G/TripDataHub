import CloudKit
import XCTest
@testable import TripDataHub

/// Two AppViewModels sharing one fake CloudKit record, standing in for an iPad and an iPhone on
/// the same GEMS account.
///
/// Mutating an event spawns an unstructured upload Task inside AppViewModel, so "call upload, then
/// assert" is inherently racy — the explicit call can coalesce into the background one and return
/// before anything is written. Every test here instead waits on the fake record reaching the
/// expected state. No `Task.sleep`, no guessing at attempt counts.
@MainActor
final class ManualEventDeletionSyncTests: XCTestCase {

    // MARK: - Device A deletes, Device B converges

    func test_personalEventDeletedOnDeviceA_isRemovedOnDeviceB() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let event = try makePersonalEvent()
        try deviceA.viewModel.saveManualPersonalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }

        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")
        XCTAssertEqual(deviceB.viewModel.manualPersonalEvents.map(\.id), [event.id], "precondition")

        try deviceA.viewModel.deleteManualPersonalEvent(id: event.id)
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }

        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "after delete")

        XCTAssertTrue(deviceB.viewModel.manualPersonalEvents.isEmpty)
    }

    func test_operationalEventDeletedOnDeviceA_isRemovedOnDeviceB() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let event = try makeOperationalEvent()
        try deviceA.viewModel.saveManualOperationalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")
        XCTAssertEqual(deviceB.viewModel.manualOperationalEvents.map(\.id), [event.id], "precondition")

        try deviceA.viewModel.deleteManualOperationalEvent(id: event.id)
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "after delete")

        XCTAssertTrue(deviceB.viewModel.manualOperationalEvents.isEmpty)
    }

    // MARK: - A stale device must not resurrect a deleted event

    func test_deviceBUploadingPreDeleteEvent_doesNotResurrectIt() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let event = try makePersonalEvent()
        try deviceA.viewModel.saveManualPersonalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")
        XCTAssertEqual(deviceB.viewModel.manualPersonalEvents.count, 1, "precondition")

        // A deletes and publishes. B has not fetched yet, so it still holds the event.
        try deviceA.viewModel.deleteManualPersonalEvent(id: event.id)
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }

        // Simulate B relaunching from its stale local store before it has fetched A's delete.
        // Clear only the upload fingerprint so this is a real upload attempt rather than the
        // normal unchanged-content fast path.
        let deviceBDefaults = try XCTUnwrap(UserDefaults(suiteName: deviceB.defaultsSuiteName))
        deviceBDefaults.removeObject(forKey: "manual_event_last_upload_fingerprint_v1")
        let relaunchedB = try makeDevice(name: "B", cloud: cloud, reusing: deviceB)
        XCTAssertEqual(relaunchedB.viewModel.manualPersonalEvents.map(\.id), [event.id], "precondition")

        // B pushes its stale state. The service merges against the server copy, so the newer
        // tombstone must survive and B must adopt the merged (deleted) result.
        await relaunchedB.viewModel.uploadManualEventsIfNeeded(reason: "stale push after relaunch")

        XCTAssertTrue(
            relaunchedB.viewModel.manualPersonalEvents.isEmpty,
            "the uploading device must adopt the merged result rather than keep its stale event"
        )
        let published = await cloud.storedSnapshot()
        let snapshot = try XCTUnwrap(published)
        XCTAssertTrue(snapshot.personalEvents.isEmpty, "the delete must survive in CloudKit")

        await deviceA.viewModel.fetchManualEventsIfNeeded(reason: "verify")
        XCTAssertTrue(deviceA.viewModel.manualPersonalEvents.isEmpty)
    }

    // MARK: - Durability of an unsent delete

    func test_failedUploadIsRetriedAndDeletePropagates() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let event = try makePersonalEvent()
        try deviceA.viewModel.saveManualPersonalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")

        let attemptsBeforeDelete = await cloud.uploadAttempts
        await cloud.setUploadsFailing(true)
        try deviceA.viewModel.deleteManualPersonalEvent(id: event.id)
        await awaitOrFail("upload attempted") { await cloud.waitUntilUploadAttempted(atLeast: attemptsBeforeDelete + 1) }

        let afterFailure = await cloud.storedSnapshot()
        let failedSnapshot = try XCTUnwrap(afterFailure)
        XCTAssertEqual(
            failedSnapshot.personalEvents.count,
            1,
            "precondition: the failed upload really did not reach CloudKit"
        )

        // Connectivity returns; the next sync must retry because a failed upload never advanced
        // the fingerprint.
        await cloud.setUploadsFailing(false)
        await deviceA.viewModel.uploadManualEventsIfNeeded(reason: "retry")
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }

        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "after retry")
        XCTAssertTrue(deviceB.viewModel.manualPersonalEvents.isEmpty)
    }

    func test_unsentTombstoneSurvivesRelaunch() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let event = try makePersonalEvent()
        try deviceA.viewModel.saveManualPersonalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")

        // Delete while offline; every upload attempt fails.
        let attemptsBeforeDelete = await cloud.uploadAttempts
        await cloud.setUploadsFailing(true)
        try deviceA.viewModel.deleteManualPersonalEvent(id: event.id)
        await awaitOrFail("upload attempted") { await cloud.waitUntilUploadAttempted(atLeast: attemptsBeforeDelete + 1) }

        // Relaunch: a brand new view model over the same on-disk store and defaults suite.
        await cloud.setUploadsFailing(false)
        let relaunchedA = try makeDevice(name: "A", cloud: cloud, reusing: deviceA)
        XCTAssertTrue(
            relaunchedA.viewModel.manualPersonalEvents.isEmpty,
            "the delete must still be applied locally after relaunch"
        )

        await relaunchedA.viewModel.uploadManualEventsIfNeeded(reason: "post relaunch")
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }

        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "after relaunch upload")
        XCTAssertTrue(deviceB.viewModel.manualPersonalEvents.isEmpty)
    }

    // MARK: - Clock skew

    /// The deleting device's clock runs behind the device that created the event.
    func test_deleteWinsWhenDeletingDeviceClockRunsBehind() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        // Event stamped an hour ahead of the deleting device's "now".
        let event = try makePersonalEvent(updatedAt: Date().addingTimeInterval(3600))
        try deviceA.viewModel.saveManualPersonalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")
        XCTAssertEqual(deviceB.viewModel.manualPersonalEvents.count, 1, "precondition")

        try deviceB.viewModel.deleteManualPersonalEvent(id: event.id)
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }

        await deviceA.viewModel.fetchManualEventsIfNeeded(reason: "after skewed delete")
        XCTAssertTrue(
            deviceA.viewModel.manualPersonalEvents.isEmpty,
            "a tombstone must outrank the local copy of the event it deletes"
        )
    }

    /// A local delete must not poison the CloudKit watermark. Before the fix the delete wrote a
    /// client `Date()` into the "last accepted record modification date", so the deleting device
    /// ignored every later remote update.
    func test_localDeleteDoesNotBlockLaterRemoteUpdates() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let first = try makePersonalEvent()
        try deviceA.viewModel.saveManualPersonalEvent(first)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: first.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")

        try deviceA.viewModel.deleteManualPersonalEvent(id: first.id)
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: first.id) }

        // B adds a genuinely new event and publishes it.
        let second = try makePersonalEvent()
        try deviceB.viewModel.saveManualPersonalEvent(second)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: second.id) }

        await deviceA.viewModel.fetchManualEventsIfNeeded(reason: "should see B's new event")

        XCTAssertEqual(
            deviceA.viewModel.manualPersonalEvents.map(\.id),
            [second.id],
            "the deleting device must still accept later remote updates"
        )
    }

    /// A delete is permanent until the id is explicitly recreated. The re-created event is lifted
    /// above the tombstone by `bumpedUpdatedAtIfTombstoned`.
    func test_recreatingEventAfterDeleteBringsItBack() async throws {
        let cloud = SharedManualEventCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let event = try makePersonalEvent()
        try deviceA.viewModel.saveManualPersonalEvent(event)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "initial")

        try deviceA.viewModel.deleteManualPersonalEvent(id: event.id)
        await awaitOrFail("tombstone stored in CloudKit") { await cloud.waitUntilTombstoneStored(id: event.id) }
        await deviceB.viewModel.fetchManualEventsIfNeeded(reason: "after delete")
        XCTAssertTrue(deviceB.viewModel.manualPersonalEvents.isEmpty, "precondition")

        let recreated = try makePersonalEvent(id: event.id)
        try deviceB.viewModel.saveManualPersonalEvent(recreated)
        await awaitOrFail("event stored in CloudKit") { await cloud.waitUntilEventStored(id: event.id) }

        await deviceA.viewModel.fetchManualEventsIfNeeded(reason: "after recreate")
        XCTAssertEqual(deviceA.viewModel.manualPersonalEvents.map(\.id), [event.id])
    }


    /// Safety net so a never-satisfied continuation fails the test instead of hanging CI.
    /// This is a failure guard, not ordering control — ordering comes from the awaited condition.
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

    // MARK: - Helpers

    private struct Device {
        let viewModel: AppViewModel
        let storeDirectory: URL
        let defaultsSuiteName: String
    }

    private var createdSuiteNames: [String] = []
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for suite in createdSuiteNames {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdSuiteNames = []
        createdDirectories = []
        super.tearDown()
    }

    private func makeDevice(
        name: String,
        cloud: SharedManualEventCloud,
        reusing existing: Device? = nil
    ) throws -> Device {
        let directory: URL
        let suiteName: String
        if let existing {
            directory = existing.storeDirectory
            suiteName = existing.defaultsSuiteName
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ManualEventSyncTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suiteName = "ManualEventSyncTests.\(name).\(UUID().uuidString)"
            createdDirectories.append(directory)
            createdSuiteNames.append(suiteName)
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let viewModel = AppViewModel(
            cacheService: InMemoryManualEventCacheService(),
            friendScheduleCloudKitService: NoopManualEventFriendService(),
            manualEventCloudKitService: DeviceManualEventService(cloud: cloud, deviceID: name),
            manualEventStore: ManualEventStore(defaults: defaults, directory: directory),
            syncStateDefaults: defaults
        )
        setVerifiedIdentity(on: viewModel)
        return Device(viewModel: viewModel, storeDirectory: directory, defaultsSuiteName: suiteName)
    }

    private func setVerifiedIdentity(on vm: AppViewModel, gemsID: String = "7793942") {
        let recordName = "_cloudkit_record_\(gemsID)"
        vm.verifiedIdentity = VerifiedIdentityProfile(
            cloudKitRecordName: recordName,
            name: "Test Pilot",
            gemsID: gemsID,
            domicile: "ANC",
            equipment: "747",
            seat: "CA",
            dateOfHire: "2000-01-01",
            isAdminEligible: false,
            adminPolicyFingerprint: nil,
            verifiedAt: Date()
        )
        vm.currentCloudKitRecordName = recordName
    }

    private func makePersonalEvent(
        id: UUID = UUID(),
        updatedAt: Date = Date()
    ) throws -> ManualPersonalEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return try ManualPersonalEvent(
            id: id,
            code: .commute,
            startUTC: start,
            endUTC: start.addingTimeInterval(3600),
            notes: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private func makeOperationalEvent() throws -> ManualOperationalEvent {
        try ManualOperationalEvent(
            code: .reserveA,
            crewBase: .anc,
            localStartDate: DateComponents(year: 2026, month: 8, day: 3)
        )
    }
}

// MARK: - Shared fake CloudKit record

/// One `TDHManualEventSnapshot` record shared by every device in a test.
///
/// Mirrors the real service in the two ways that matter: writes merge against the stored snapshot,
/// and the record's modification date comes from a monotonic *server* clock that is deliberately
/// unrelated to any device's `Date()`. That is what lets a test exercise clock skew honestly.
private actor SharedManualEventCloud {
    private var stored: ManualEventStoreSnapshot?
    private var lastDeviceID = ""
    private var serverTick: TimeInterval = 0
    private var uploadsFailing = false
    private(set) var uploadAttempts = 0

    private struct Waiter {
        let predicate: (ManualEventStoreSnapshot?, Int) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []

    /// Far behind any real device clock, so a device that wrongly compares a local `Date()`
    /// against this value will visibly reject updates.
    private let serverEpoch = Date(timeIntervalSince1970: 1_000_000)

    /// A latch rather than a countdown: mutating the store spawns a background upload Task of its
    /// own, so any test that budgeted a fixed number of failures would race with it.
    func setUploadsFailing(_ failing: Bool) {
        uploadsFailing = failing
    }

    func storedSnapshot() -> ManualEventStoreSnapshot? {
        stored
    }

    // MARK: - Deterministic waiting
    //
    // Mutating an event spawns an unstructured upload Task inside AppViewModel, and an explicit
    // `uploadManualEventsIfNeeded` may simply coalesce into it and return before the write lands.
    // Tests therefore wait on the observable end state — what is actually stored in the record —
    // rather than on a call returning or on elapsed time.

    private func wait(
        until predicate: @escaping (ManualEventStoreSnapshot?, Int) -> Bool
    ) async {
        if predicate(stored, uploadAttempts) { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(predicate: predicate, continuation: continuation))
        }
    }

    /// Resolves once the stored snapshot contains a personal or operational event with this id.
    func waitUntilEventStored(id: UUID) async {
        await wait { snapshot, _ in
            guard let snapshot else { return false }
            return snapshot.personalEvents.contains { $0.id == id }
                || snapshot.operationalEvents.contains { $0.id == id }
        }
    }

    /// Resolves once the stored snapshot carries a tombstone for this id *and* no live event for it.
    func waitUntilTombstoneStored(id: UUID) async {
        await wait { snapshot, _ in
            guard let snapshot else { return false }
            let hasTombstone = snapshot.tombstones.contains { $0.id == id }
            let stillLive = snapshot.personalEvents.contains { $0.id == id }
                || snapshot.operationalEvents.contains { $0.id == id }
            return hasTombstone && !stillLive
        }
    }

    /// Resolves once at least `count` upload attempts have been made, successful or not.
    func waitUntilUploadAttempted(atLeast count: Int) async {
        await wait { _, attempts in attempts >= count }
    }

    private func signalWaiters() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(stored, uploadAttempts) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func upload(snapshot: ManualEventStoreSnapshot, deviceID: String) throws -> ManualEventStoreSnapshot {
        uploadAttempts += 1
        if uploadsFailing {
            // Attempt-count waiters still need to observe the failed try.
            signalWaiters()
            throw CKError(.networkFailure)
        }
        let merged = stored.map { mergeManualEventSnapshots(local: snapshot, remote: $0) } ?? snapshot
        stored = merged
        lastDeviceID = deviceID
        serverTick += 1
        signalWaiters()
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
            source: .iphone
        )
    }
}

private struct DeviceManualEventService: ManualEventCloudKitServicing {
    let cloud: SharedManualEventCloud
    let deviceID: String

    @discardableResult
    func uploadManualEvents(
        gemsID: String,
        cloudKitRecordName: String,
        snapshot: ManualEventStoreSnapshot,
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws -> ManualEventStoreSnapshot {
        try await cloud.upload(snapshot: snapshot, deviceID: self.deviceID)
    }

    func fetchManualEvents(gemsID: String) async throws -> ManualEventCloudKitSnapshot? {
        await cloud.fetch()
    }
}

// MARK: - Minimal stubs for the collaborators this suite does not exercise

private final class InMemoryManualEventCacheService: ScheduleCacheServiceProtocol, @unchecked Sendable {
    private var snapshot: ScheduleCacheSnapshotV2?
    func load() -> ScheduleCacheSnapshotV2? { snapshot }
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private struct NoopManualEventFriendService: FriendScheduleCloudKitServicing {
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
