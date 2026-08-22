import CloudKit
import XCTest
@testable import TripDataHub

/// Trip deletion convergence across devices.
///
/// Two AppViewModels share one fake `TDHCrewAccessImportFile` collection but have their own
/// CrewAccessImports directory and their own `syncStateDefaults`, so each has genuinely private
/// local state — files, deletion outbox, observation set — exactly like two physical devices on one
/// GEMS account.
///
/// No `Task.sleep` anywhere: every wait is on observable fake-CloudKit state.
@MainActor
final class CrewAccessDeletionOutboxTests: XCTestCase {

    private let gemsID = "7793942"
    private var devices: [Device] = []

    override func tearDown() {
        for device in devices {
            try? FileManager.default.removeItem(at: device.importsDirectory)
            UserDefaults().removePersistentDomain(forName: device.defaultsSuiteName)
        }
        devices = []
        super.tearDown()
    }

    // MARK: - State 1: deletion not yet observed

    /// The outbox must tombstone every CloudKit record for the trip, including file names this
    /// device never held locally. 1.2.4 derived the tombstone list from locally deleted files, so
    /// a record under an unknown legacy name was left live and resurrected the trip.
    func test_unobservedDeletion_tombstonesUnknownLegacyAndDuplicateRecords() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        // Three records for one trip: the current name plus two the device never downloaded.
        let current = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: current)
        await cloud.seed(fileName: "A700004.json", payload: current)
        await cloud.seed(fileName: "legacy_A700004_v1.json", payload: current)

        try await deviceA.write(payload: current, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")

        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertTrue(live.isEmpty, "every record for the trip must be tombstoned, not just the local one")
    }

    /// Deleting a trip whose JSON is not on this device at all still has to tombstone CloudKit.
    func test_deletionWithNoLocalFile_stillTombstonesRemoteRecords() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")

        let ids = Set(deviceA.viewModel.crewAccessSchedules.map(\.id))
        // Simulate retention having pruned the JSON before the user deletes the trip.
        try deviceA.removeAllLocalFiles()

        await deviceA.viewModel.deleteCrewAccessTrips(ids: ids)
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertTrue(live.isEmpty)
    }

    // MARK: - Cross-device convergence

    func test_deletionOnDeviceA_removesTripOnDeviceB() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "seed")
        XCTAssertFalse(deviceB.viewModel.crewAccessSchedules.isEmpty, "precondition: B has the trip")

        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "after delete")
        XCTAssertTrue(deviceB.viewModel.crewAccessSchedules.isEmpty)
        XCTAssertTrue(deviceB.localFileNames().isEmpty, "B must drop the local JSON too")
    }

    /// Device B holds the pre-delete JSON and runs its recovery upload. Before the fix that path
    /// fell through whenever the remote record was tombstoned, clearing it and resurrecting the
    /// trip — repeatedly, because a sync-down refreshes local file mtimes.
    func test_staleDeviceAutoUpload_doesNotResurrectDeletedTrip() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        try await deviceB.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")

        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        // B still has the old JSON and syncs repeatedly.
        for pass in 1...3 {
            await deviceB.viewModel.syncCrewAccessDeviceData(reason: "stale pass \(pass)")
        }

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertTrue(live.isEmpty, "a stale device must never clear the tombstone")
        XCTAssertTrue(deviceB.viewModel.crewAccessSchedules.isEmpty)

        // And A must not see it come back.
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "verify")
        XCTAssertTrue(deviceA.viewModel.crewAccessSchedules.isEmpty)
    }

    /// After the deletion is observed complete, a re-upload of the *same* payload generation is a
    /// stale device, not a re-import, and must be tombstoned again.
    func test_observedDeletion_reTombstonesDeletedGeneration() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        // Reach the observed state.
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "observe")

        // An old device republishes the identical generation.
        await cloud.resurrect(fileName: "2026-07-01_A700004.json", payload: payload)
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "stale resurrect")
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        XCTAssertTrue(deviceA.viewModel.crewAccessSchedules.isEmpty)
    }

    /// A new import generation — different `generatedAt`, therefore a different payload
    /// fingerprint — must be accepted once the deletion has been observed.
    func test_observedDeletion_acceptsNewImportGeneration() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let original = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: original)
        try await deviceA.write(payload: original, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "observe")

        // Same PDF re-imported elsewhere: the parser re-stamps generatedAt every time.
        let reimported = tripPayload(tripID: "A700004", generatedAt: "2026-07-02T09:30:00Z")
        await cloud.resurrect(fileName: "2026-07-01_A700004.json", payload: reimported)

        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "new generation")

        XCTAssertFalse(
            deviceA.viewModel.crewAccessSchedules.isEmpty,
            "a new generatedAt is a new import generation and must be accepted"
        )
        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertEqual(live, ["2026-07-01_A700004.json"], "the new generation must not be re-tombstoned")
    }

    /// The receiving device has no local re-import flag. It must still accept the new generation
    /// on fingerprint evidence alone.
    func test_deviceWithoutLocalReimportFlag_acceptsNewGeneration() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let original = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: original)
        try await deviceA.write(payload: original, fileName: "2026-07-01_A700004.json")
        try await deviceB.write(payload: original, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "seed")

        // B is the device that deletes, so B is the one holding a deletion outbox entry.
        await deviceB.viewModel.deleteCrewAccessTrips(ids: Set(deviceB.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }
        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "observe")

        // A re-imports explicitly. B has no reimportedCrewAccessTripKeys entry for this trip.
        let reimported = tripPayload(tripID: "A700004", generatedAt: "2026-07-03T12:00:00Z")
        await cloud.resurrect(fileName: "2026-07-01_A700004.json", payload: reimported)

        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "receive new generation")

        XCTAssertFalse(
            deviceB.viewModel.crewAccessSchedules.isEmpty,
            "the receiving device must accept a generation it never deleted"
        )
    }

    /// Re-importing on the same device between the delete and the first observation.
    func test_reimportOnSameDeviceBeforeObservation_converges() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let original = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: original)
        try await deviceA.write(payload: original, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))

        // Explicit re-import before any observing sync, then the new generation appears remotely.
        let reimported = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T18:00:00Z")
        // Same entry point confirmPendingImport uses.
        let reimportedKey = try XCTUnwrap(deviceA.viewModel.crewAccessTripKey(
            tripID: "A700004",
            tripInformationDate: reimported.tripInformationDate
        ))
        deviceA.viewModel.recordExplicitCrewAccessReimport(tripKeys: [reimportedKey])
        await cloud.resurrect(fileName: "2026-07-01_A700004.json", payload: reimported)
        try await deviceA.write(payload: reimported, fileName: "2026-07-01_A700004.json")

        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "after same-device reimport")

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertEqual(live, ["2026-07-01_A700004.json"], "an explicit local re-import must survive")
    }

    /// An undecodable payload is never assumed to be a new generation.
    func test_undecodablePayload_isTreatedAsDeletionTarget() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "observe")

        // Garbage that still routes to the same trip key via the record's index fields.
        await cloud.resurrectRaw(
            fileName: "2026-07-01_A700004.json",
            jsonData: Data("not json".utf8),
            tripInformationDate: payload.tripInformationDate
        )
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "undecodable")

        XCTAssertTrue(
            deviceA.viewModel.crewAccessSchedules.isEmpty,
            "an undecodable payload must not be promoted to a new generation"
        )
    }

    // MARK: - Durability

    func test_failedTombstoneUploadIsRetriedOnNextSync() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")

        await cloud.setTombstonesFailing(true)
        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))

        let liveAfterFailure = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertEqual(liveAfterFailure.count, 1, "precondition: the tombstone did not reach CloudKit")

        await cloud.setTombstonesFailing(false)
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "retry")
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertTrue(live.isEmpty)
    }

    func test_outboxSurvivesRelaunchAndRetries() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")

        await cloud.setTombstonesFailing(true)
        await deviceA.viewModel.deleteCrewAccessTrips(ids: Set(deviceA.viewModel.crewAccessSchedules.map(\.id)))

        // Relaunch over the same directory and defaults suite.
        await cloud.setTombstonesFailing(false)
        let relaunched = try makeDevice(name: "A", cloud: cloud, reusing: deviceA)
        await relaunched.viewModel.syncCrewAccessDeviceData(reason: "post relaunch")
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertTrue(live.isEmpty, "an unsent deletion must survive termination")
    }

    /// Deleting from the file manager screen must behave exactly like deleting from the trip list.
    func test_fileManagerDeleteMatchesTripListDelete() async throws {
        let cloud = SharedCrewAccessImportCloud()
        let deviceA = try makeDevice(name: "A", cloud: cloud)
        let deviceB = try makeDevice(name: "B", cloud: cloud)

        let payload = tripPayload(tripID: "A700004", generatedAt: "2026-07-01T00:00:00Z")
        await cloud.seed(fileName: "2026-07-01_A700004.json", payload: payload)
        await cloud.seed(fileName: "legacy_A700004.json", payload: payload)
        let url = try await deviceA.write(payload: payload, fileName: "2026-07-01_A700004.json")
        await deviceA.viewModel.syncCrewAccessDeviceData(reason: "seed")
        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "seed")

        await deviceA.viewModel.deleteCrewAccessImportFiles(urls: [url])
        await awaitOrFail("all records for A700004 tombstoned") { await cloud.waitUntilAllTombstoned(tripID: "A700004") }

        let live = await cloud.liveFileNames(tripID: "A700004")
        XCTAssertTrue(live.isEmpty, "both the current and legacy records must be tombstoned")

        await deviceB.viewModel.syncCrewAccessDeviceData(reason: "after file delete")
        XCTAssertTrue(deviceB.viewModel.crewAccessSchedules.isEmpty)
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

    // MARK: - Device harness

    private struct Device {
        let viewModel: AppViewModel
        let importsDirectory: URL
        let defaultsSuiteName: String

        @discardableResult
        func write(payload: CrewAccessTripJSON, fileName: String) async throws -> URL {
            try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            let url = importsDirectory.appendingPathComponent(fileName)
            try JSONEncoder().encode(payload).write(to: url)
            return url
        }

        func localFileNames() -> [String] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: importsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            return urls.map(\.lastPathComponent).sorted()
        }

        func removeAllLocalFiles() throws {
            for url in (try? FileManager.default.contentsOfDirectory(
                at: importsDirectory,
                includingPropertiesForKeys: nil
            )) ?? [] {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func makeDevice(
        name: String,
        cloud: SharedCrewAccessImportCloud,
        reusing existing: Device? = nil
    ) throws -> Device {
        let directory: URL
        let suiteName: String
        if let existing {
            directory = existing.importsDirectory
            suiteName = existing.defaultsSuiteName
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CrewAccessOutboxTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suiteName = "CrewAccessOutboxTests.\(name).\(UUID().uuidString)"
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let viewModel = AppViewModel(
            cacheService: OutboxTestCacheService(),
            friendScheduleCloudKitService: OutboxTestFriendService(),
            deviceScheduleCloudKitService: OutboxTestDeviceScheduleService(),
            crewAccessImportCloudKitService: DeviceCrewAccessImportService(cloud: cloud),
            syncStateDefaults: defaults,
            crewAccessImportsDirectory: directory
        )
        viewModel.verifiedIdentity = VerifiedIdentityProfile(
            cloudKitRecordName: "_rec_\(gemsID)",
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
        viewModel.currentCloudKitRecordName = "_rec_\(gemsID)"

        let device = Device(viewModel: viewModel, importsDirectory: directory, defaultsSuiteName: suiteName)
        if existing == nil { devices.append(device) }
        return device
    }

    private func tripPayload(tripID: String, generatedAt: String) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "crewaccess_print_pdf",
            sourceVersion: "1",
            mappingVersion: "1",
            generatedAt: generatedAt,
            tripId: tripID,
            tripInformationDate: "2026-07-01",
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            dutyTotals: [],
            hotelDetails: [],
            crew: [],
            items: [
                CrewAccessTripItemJSON(
                    sequence: 1,
                    depAirport: "ANC",
                    arrAirport: "SDF",
                    deadhead: false,
                    flight: "100",
                    startUtc: "2026-07-01T06:00:00Z",
                    endUtc: "2026-07-01T10:00:00Z",
                    startLocalDisplay: "2026-06-30T22:00:00",
                    endLocalDisplay: "2026-07-01T06:00:00",
                    originTz: "America/Anchorage",
                    destinationTz: "America/Kentucky/Louisville",
                    timeDerivation: "utc",
                    aircraft: "B767",
                    block: "4:00",
                    stdUtc: nil,
                    staUtc: nil,
                    atdUtc: nil,
                    ataUtc: nil,
                    tailNumber: nil
                )
            ]
        )
    }
}

private actor OutboxTestDeviceScheduleService: DeviceScheduleCloudKitServicing {
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

// MARK: - Shared fake CloudKit collection

/// The account's `TDHCrewAccessImportFile` records. Tombstoning sets `deletedAt`; uploading clears
/// it, exactly like the real service.
private actor SharedCrewAccessImportCloud {
    private struct Stored {
        var jsonData: Data
        var tripInformationDate: String?
        var updatedAt: Date
        var deletedAt: Date?
    }

    private var records: [String: Stored] = [:]
    private var tombstonesFailing = false
    private var clientTick: TimeInterval = 0

    private struct Waiter {
        let predicate: ([String: Stored]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []

    func setTombstonesFailing(_ failing: Bool) { tombstonesFailing = failing }

    func seed(fileName: String, payload: CrewAccessTripJSON) {
        clientTick += 1
        records[fileName] = Stored(
            jsonData: (try? JSONEncoder().encode(payload)) ?? Data(),
            tripInformationDate: payload.tripInformationDate,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 + clientTick),
            deletedAt: nil
        )
        signal()
    }

    /// An old build republishing a payload, which clears the tombstone.
    func resurrect(fileName: String, payload: CrewAccessTripJSON) {
        seed(fileName: fileName, payload: payload)
    }

    func resurrectRaw(fileName: String, jsonData: Data, tripInformationDate: String?) {
        clientTick += 1
        records[fileName] = Stored(
            jsonData: jsonData,
            tripInformationDate: tripInformationDate,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 + clientTick),
            deletedAt: nil
        )
        signal()
    }

    func liveFileNames(tripID: String) -> [String] {
        records
            .filter { $0.value.deletedAt == nil && Self.tripID(in: $0.value.jsonData) == tripID }
            .keys
            .sorted()
    }

    func waitUntilAllTombstoned(tripID: String) async {
        let isDone: ([String: Stored]) -> Bool = { current in
            !current.contains { $0.value.deletedAt == nil && Self.tripID(in: $0.value.jsonData) == tripID }
        }
        if isDone(records) { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(predicate: isDone, continuation: continuation))
        }
    }

    private func signal() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(records) { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        waiters = remaining
    }

    private static func tripID(in jsonData: Data) -> String? {
        (try? JSONDecoder().decode(CrewAccessTripJSON.self, from: jsonData))?.tripId
    }

    // MARK: Service surface

    func upload(fileName: String, jsonData: Data, tripInformationDate: String?) {
        clientTick += 1
        records[fileName] = Stored(
            jsonData: jsonData,
            tripInformationDate: tripInformationDate,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 + clientTick),
            deletedAt: nil
        )
        signal()
    }

    func tombstone(fileName: String) throws {
        if tombstonesFailing { throw CKError(.networkFailure) }
        guard var record = records[fileName] else { return }
        clientTick += 1
        record.deletedAt = Date(timeIntervalSince1970: 1_000_000 + clientTick)
        records[fileName] = record
        signal()
    }

    func allRecords() -> [CrewAccessImportCloudKitRecord] {
        records.map { name, stored in
            CrewAccessImportCloudKitRecord(
                fileName: name,
                jsonData: stored.jsonData,
                tripInformationDate: stored.tripInformationDate,
                firstDepartureUTC: nil,
                updatedAt: stored.updatedAt,
                deletedAt: stored.deletedAt
            )
        }
    }
}

private struct DeviceCrewAccessImportService: CrewAccessImportCloudKitServicing {
    let cloud: SharedCrewAccessImportCloud

    func uploadImportFile(
        gemsID: String,
        fileName: String,
        jsonData: Data,
        tripInformationDate: String?,
        firstDepartureUTC: String?
    ) async throws {
        await cloud.upload(fileName: fileName, jsonData: jsonData, tripInformationDate: tripInformationDate)
    }

    func fetchImportFiles(gemsID: String) async throws -> [CrewAccessImportCloudKitRecord] {
        await cloud.allRecords()
    }

    func tombstoneImportFile(gemsID: String, fileName: String) async throws {
        try await cloud.tombstone(fileName: fileName)
    }
}

// MARK: - Stubs

private final class OutboxTestCacheService: ScheduleCacheServiceProtocol, @unchecked Sendable {
    private var snapshot: ScheduleCacheSnapshotV2?
    func load() -> ScheduleCacheSnapshotV2? { snapshot }
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private struct OutboxTestFriendService: FriendScheduleCloudKitServicing {
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
