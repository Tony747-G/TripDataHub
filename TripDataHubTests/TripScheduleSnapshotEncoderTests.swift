import XCTest
@testable import TripData_Hub

final class TripScheduleSnapshotEncoderTests: XCTestCase {

    // MARK: - scheduleItems

    func test_scheduleItems_mapsLegsWithUTCTimes() {
        let leg = makeLeg(
            flight: "5X123",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-05T10:00:00Z",
            arrUTC: "2026-05-05T17:30:00Z"
        )
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.scheduleItems.count, 1)
        let item = payload.scheduleItems[0]
        XCTAssertEqual(item.type, "flight")
        XCTAssertEqual(item.label, "5X123 ANC-SDF")
        XCTAssertEqual(item.startUTC, "2026-05-05T10:00:00Z")
        XCTAssertEqual(item.endUTC, "2026-05-05T17:30:00Z")
        XCTAssertEqual(item.departureAirport, "ANC")
        XCTAssertEqual(item.arrivalAirport, "SDF")
    }

    func test_scheduleItems_fallsBackToScheduledTimes() {
        // leg has no depUTC/arrUTC, only stdUTC/staUTC
        let leg = TripLeg(
            payPeriod: "PP26-05",
            pairing: "A123",
            leg: 1,
            flight: "5X200",
            depAirport: "ANC",
            depLocal: "2026-05-05 02:00",
            arrAirport: "ONT",
            arrLocal: "2026-05-05 09:00",
            status: "-",
            block: "7:00",
            stdUTC: "2026-05-05T10:00:00Z",
            staUTC: "2026-05-05T17:00:00Z"
        )
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.scheduleItems.count, 1)
        XCTAssertEqual(payload.scheduleItems[0].startUTC, "2026-05-05T10:00:00Z")
        XCTAssertEqual(payload.scheduleItems[0].endUTC, "2026-05-05T17:00:00Z")
    }

    func test_scheduleItems_skipsLegsWithNoUTCTimes() {
        let leg = TripLeg(
            payPeriod: "PP26-05",
            pairing: "A123",
            leg: 1,
            flight: "5X999",
            depAirport: "ANC",
            depLocal: "local only",
            arrAirport: "SDF",
            arrLocal: "local only",
            status: "-",
            block: "4:00"
        )
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertTrue(payload.scheduleItems.isEmpty)
    }

    func test_scheduleItems_sortedByStartUTC() {
        let leg1 = makeLeg(flight: "5X100", depAirport: "ANC", arrAirport: "SDF",
                           depUTC: "2026-05-06T10:00:00Z", arrUTC: "2026-05-06T17:00:00Z")
        let leg2 = makeLeg(flight: "5X050", depAirport: "SDF", arrAirport: "ONT",
                           depUTC: "2026-05-05T08:00:00Z", arrUTC: "2026-05-05T14:00:00Z")
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg1, leg2])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.scheduleItems[0].label, "5X050 SDF-ONT")
        XCTAssertEqual(payload.scheduleItems[1].label, "5X100 ANC-SDF")
    }

    // MARK: - currentTrip

    func test_currentTrip_setWhenNowIsWithinTrip() {
        let leg1 = makeLeg(pairing: "B456", flight: "5X100", depAirport: "ANC", arrAirport: "SDF",
                           depUTC: "2026-05-05T10:00:00Z", arrUTC: "2026-05-05T17:00:00Z")
        let leg2 = makeLeg(pairing: "B456", flight: "5X101", depAirport: "SDF", arrAirport: "ONT",
                           depUTC: "2026-05-06T08:00:00Z", arrUTC: "2026-05-06T14:00:00Z")
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(pairing: "B456", legs: [leg1, leg2])],
            now: iso("2026-05-05T20:00:00Z") // between legs, still within trip window
        )

        XCTAssertNotNil(payload.currentTrip)
        XCTAssertEqual(payload.currentTrip?.tripId, "B456")
        XCTAssertEqual(payload.currentTrip?.displayLabel, "ANC-SDF-ONT")
    }

    func test_currentTrip_nilWhenNowIsBeforeTrip() {
        let leg = makeLeg(flight: "5X100", depAirport: "ANC", arrAirport: "SDF",
                          depUTC: "2026-05-05T10:00:00Z", arrUTC: "2026-05-05T17:00:00Z")
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertNil(payload.currentTrip)
    }

    func test_currentTrip_nilWhenNowIsAfterTrip() {
        let leg = makeLeg(flight: "5X100", depAirport: "ANC", arrAirport: "SDF",
                          depUTC: "2026-05-05T10:00:00Z", arrUTC: "2026-05-05T17:00:00Z")
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-05T18:00:00Z")
        )

        XCTAssertNil(payload.currentTrip)
    }

    // MARK: - nextFlight

    func test_nextFlight_setToFirstFutureleg() {
        let past = makeLeg(flight: "5X001", depAirport: "ANC", arrAirport: "SDF",
                           depUTC: "2026-05-04T06:00:00Z", arrUTC: "2026-05-04T12:00:00Z")
        let future = makeLeg(flight: "5X002", depAirport: "SDF", arrAirport: "ONT",
                             depUTC: "2026-05-05T10:00:00Z", arrUTC: "2026-05-05T16:00:00Z")
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [past, future])],
            now: iso("2026-05-04T20:00:00Z")
        )

        XCTAssertNotNil(payload.nextFlight)
        XCTAssertEqual(payload.nextFlight?.flightNumber, "5X002")
        XCTAssertEqual(payload.nextFlight?.departureAirport, "SDF")
        XCTAssertEqual(payload.nextFlight?.arrivalAirport, "ONT")
    }

    func test_nextFlight_nilWhenAllLegsAreInThePast() {
        let leg = makeLeg(flight: "5X100", depAirport: "ANC", arrAirport: "SDF",
                          depUTC: "2026-05-01T10:00:00Z", arrUTC: "2026-05-01T17:00:00Z")
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-05T00:00:00Z")
        )

        XCTAssertNil(payload.nextFlight)
    }

    // MARK: - JSON output

    func test_json_isValidAndContainsRequiredFields() throws {
        let leg = makeLeg(flight: "5X123", depAirport: "ANC", arrAirport: "SDF",
                          depUTC: "2026-05-05T10:00:00Z", arrUTC: "2026-05-05T17:30:00Z")
        let jsonString = try TripScheduleSnapshotEncoder.json(
            ownerDisplayName: "Tony",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(parsed?["generatedAtUTC"])
        XCTAssertNotNil(parsed?["scheduleItems"])
    }

    func test_emptySchedules_producesEmptyItems() {
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "Tony",
            schedules: [],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertTrue(payload.scheduleItems.isEmpty)
        XCTAssertNil(payload.currentTrip)
        XCTAssertNil(payload.nextFlight)
    }

    // MARK: - Helpers

    private func makeSchedule(pairing: String = "A123", legs: [TripLeg]) -> PayPeriodSchedule {
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
        pairing: String = "A123",
        flight: String,
        depAirport: String,
        arrAirport: String,
        depUTC: String,
        arrUTC: String
    ) -> TripLeg {
        TripLeg(
            payPeriod: "PP26-05",
            pairing: pairing,
            leg: 1,
            flight: flight,
            depAirport: depAirport,
            depLocal: depUTC,
            arrAirport: arrAirport,
            arrLocal: arrUTC,
            depUTC: depUTC,
            arrUTC: arrUTC,
            status: "-",
            block: "4:00"
        )
    }

    private func iso(_ value: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)!
    }
}
