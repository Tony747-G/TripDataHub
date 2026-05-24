import XCTest
@testable import TripDataHub

@MainActor
final class WatchTransportTests: XCTestCase {

    // MARK: - contentEquals

    func test_contentEquals_sameContent_differentTimestamp_returnsTrue() {
        let base = WatchOperationalSnapshot.mockTrip
        let later = WatchOperationalSnapshot(
            mode: base.mode,
            generatedAtUTC: base.generatedAtUTC.addingTimeInterval(300),
            trip: base.trip,
            reserve: base.reserve,
            training: base.training,
            offDuty: base.offDuty
        )
        XCTAssertTrue(base.contentEquals(later))
        XCTAssertNotEqual(base, later) // Equatable includes timestamp
    }

    func test_contentEquals_differentMode_returnsFalse() {
        let trip = WatchOperationalSnapshot.mockTrip
        let reserve = WatchOperationalSnapshot.mockReserve
        XCTAssertFalse(trip.contentEquals(reserve))
    }

    func test_contentEquals_sameSnapshot_returnsTrue() {
        let snap = WatchOperationalSnapshot.mockOffDuty
        XCTAssertTrue(snap.contentEquals(snap))
    }

    // MARK: - WatchSnapshotCoordinator (mock transport)

    func test_coordinator_sendsSnapshot_whenCalledDirectly() {
        let mock = MockWatchTransport()
        let coord = WatchSnapshotCoordinator(transport: mock)
        coord.sendSnapshot(schedules: [], events: [], crewBase: .anc)
        XCTAssertEqual(mock.sentSnapshots.count, 1)
        XCTAssertEqual(mock.sentSnapshots.first?.mode, .offDuty)
    }

    func test_coordinator_sendsTrip_whenActiveLegExists() throws {
        let mock = MockWatchTransport()
        let coord = WatchSnapshotCoordinator(transport: mock)
        let now = Date()
        let leg = TripLeg(
            payPeriod: "PP26-01", pairing: "T01", leg: 1, flight: "5X1",
            depAirport: "ANC", depLocal: "07:30",
            arrAirport: "SDF", arrLocal: "11:30",
            depUTC: iso8601(now.addingTimeInterval(-1800)),
            arrUTC: iso8601(now.addingTimeInterval(3600)),
            status: "-", block: "4:00"
        )
        let sched = PayPeriodSchedule(
            id: "T", label: "T", tripCount: 1, legCount: 1, openTimeCount: 0,
            updatedAt: now, legs: [leg], openTimeTrips: []
        )
        coord.sendSnapshot(schedules: [sched], events: [], crewBase: .anc)
        XCTAssertEqual(mock.sentSnapshots.first?.mode, .trip)
    }

    func test_coordinator_doesNotCrash_whenTransportThrows() {
        let mock = MockWatchTransport(shouldThrow: true)
        let coord = WatchSnapshotCoordinator(transport: mock)
        XCTAssertNoThrow(coord.sendSnapshot(schedules: [], events: [], crewBase: .anc))
    }

    func test_coordinator_sendsReserve_whenActiveEvent() throws {
        let mock = MockWatchTransport()
        let coord = WatchSnapshotCoordinator(transport: mock)
        let now = Date()
        let event = try ManualOperationalEvent(
            code: .reserveC, crewBase: .anc,
            startUTC: now.addingTimeInterval(-3600),
            endUTC: now.addingTimeInterval(3600)
        )
        coord.sendSnapshot(schedules: [], events: [event], crewBase: .anc)
        XCTAssertEqual(mock.sentSnapshots.first?.mode, .reserve)
    }

    // MARK: - Helpers

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - Mock transport

final class MockWatchTransport: WatchSnapshotSending {
    private(set) var sentSnapshots: [WatchOperationalSnapshot] = []
    var shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func sendSnapshot(_ snapshot: WatchOperationalSnapshot) throws {
        if shouldThrow { throw WatchSendError.notActivated }
        sentSnapshots.append(snapshot)
    }
}
