import XCTest
@testable import TripData_Hub

final class FriendScheduleMatchingTests: XCTestCase {
    func test_restWindow_usesArrivalPlus60AndDepartureMinus120() {
        let arrivalLeg = makeLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            leg: 1,
            flight: "100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-01T06:00:00Z",
            arrUTC: "2026-05-01T10:00:00Z"
        )
        let departureLeg = makeLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            leg: 2,
            flight: "101",
            depAirport: "SDF",
            arrAirport: "ANC",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )

        let snapshot = SharedScheduleExporter.snapshot(
            ownerGEMSID: "123456",
            schedules: [makeSchedule(legs: [arrivalLeg, departureLeg])]
        )

        XCTAssertEqual(snapshot.restWindows.count, 1)
        XCTAssertEqual(snapshot.restWindows[0].station, "SDF")
        XCTAssertEqual(snapshot.restWindows[0].startUTC, iso("2026-05-01T11:00:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].endUTC, iso("2026-05-01T20:00:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].durationMinutes, 540)
    }

    func test_restOverlap_matchesAtOneHour() {
        let mySchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z"),
            makeLeg(leg: 2, flight: "101", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-05-01T22:00:00Z", arrUTC: "2026-05-02T02:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "200", depAirport: "ONT", arrAirport: "SDF", depUTC: "2026-05-01T13:00:00Z", arrUTC: "2026-05-01T18:00:00Z"),
            makeLeg(leg: 2, flight: "201", depAirport: "SDF", arrAirport: "ONT", depUTC: "2026-05-01T23:00:00Z", arrUTC: "2026-05-02T03:00:00Z")
        ])]

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "654321", schedules: friendSchedules)]
        )

        let overlapCount = matches.restOverlapsByArrivalLegID.values.flatMap { $0 }.count
        XCTAssertEqual(overlapCount, 1)
        XCTAssertEqual(matches.restOverlapsByArrivalLegID.values.flatMap { $0 }[0].overlapMinutes, 60)
    }

    func test_restOverlap_doesNotMatchBelowOneHour() {
        let mySchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z"),
            makeLeg(leg: 2, flight: "101", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-05-01T22:00:00Z", arrUTC: "2026-05-02T02:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "200", depAirport: "ONT", arrAirport: "SDF", depUTC: "2026-05-01T13:01:00Z", arrUTC: "2026-05-01T18:01:00Z"),
            makeLeg(leg: 2, flight: "201", depAirport: "SDF", arrAirport: "ONT", depUTC: "2026-05-01T23:00:00Z", arrUTC: "2026-05-02T03:00:00Z")
        ])]

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "654321", schedules: friendSchedules)]
        )

        XCTAssertTrue(matches.restOverlapsByArrivalLegID.isEmpty)
    }

    func test_flightMatch_allowsThirtyMinuteDepartureTolerance() {
        let myLegID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let mySchedules = [makeSchedule(legs: [
            makeLeg(id: myLegID, leg: 1, flight: "123", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "5X123", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:30:00Z", arrUTC: "2026-05-01T10:30:00Z")
        ])]

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "654321", schedules: friendSchedules)]
        )

        XCTAssertEqual(matches.flightMatchesByLegID[myLegID]?.count, 1)
    }

    private func makeSchedule(legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "PP26-05",
            label: "PP26-05",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 0),
            legs: legs,
            openTimeTrips: []
        )
    }

    private func makeLeg(
        id: UUID = UUID(),
        leg: Int,
        flight: String,
        depAirport: String,
        arrAirport: String,
        depUTC: String,
        arrUTC: String
    ) -> TripLeg {
        TripLeg(
            id: id,
            payPeriod: "PP26-05",
            pairing: "A123",
            leg: leg,
            flight: flight,
            depAirport: depAirport,
            depLocal: depUTC.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ":00Z", with: ""),
            arrAirport: arrAirport,
            arrLocal: arrUTC.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ":00Z", with: ""),
            depUTC: depUTC,
            arrUTC: arrUTC,
            status: "-",
            block: "4:00"
        )
    }

    private func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
