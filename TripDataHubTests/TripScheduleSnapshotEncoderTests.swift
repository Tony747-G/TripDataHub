import XCTest
@testable import TripDataHub

final class TripScheduleSnapshotEncoderTests: XCTestCase {
    func test_scheduleItems_mapsLegsWithUTCTimes() {
        let leg = makeLeg(
            flight: "5X123",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-05T10:00:00Z",
            arrUTC: "2026-05-05T17:30:00Z"
        )

        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.owner.displayName, "0554744")
        XCTAssertEqual(payload.scheduleItems.count, 1)
        XCTAssertEqual(payload.scheduleItems[0].type, "flight")
        XCTAssertEqual(payload.scheduleItems[0].label, "5X123 ANC-SDF")
        XCTAssertEqual(payload.scheduleItems[0].startUTC, "2026-05-05T10:00:00Z")
        XCTAssertEqual(payload.scheduleItems[0].endUTC, "2026-05-05T17:30:00Z")
    }

    func test_scheduleItems_fallsBackToScheduledTimes() {
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
            ownerDisplayName: "0554744",
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
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertTrue(payload.scheduleItems.isEmpty)
    }

    func test_scheduleItems_sortedByStartUTC() {
        let later = makeLeg(
            flight: "5X100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-06T10:00:00Z",
            arrUTC: "2026-05-06T17:00:00Z"
        )
        let earlier = makeLeg(
            flight: "5X050",
            depAirport: "SDF",
            arrAirport: "ONT",
            depUTC: "2026-05-05T08:00:00Z",
            arrUTC: "2026-05-05T14:00:00Z"
        )

        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [later, earlier])],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.scheduleItems.map(\.label), ["5X050 SDF-ONT", "5X100 ANC-SDF"])
    }

    func test_currentTrip_setWhenNowIsWithinTrip() {
        let leg1 = makeLeg(
            pairing: "B456",
            flight: "5X100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-05T10:00:00Z",
            arrUTC: "2026-05-05T17:00:00Z"
        )
        let leg2 = makeLeg(
            pairing: "B456",
            flight: "5X101",
            depAirport: "SDF",
            arrAirport: "ONT",
            depUTC: "2026-05-06T08:00:00Z",
            arrUTC: "2026-05-06T14:00:00Z"
        )

        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg1, leg2])],
            now: iso("2026-05-05T20:00:00Z")
        )

        XCTAssertEqual(payload.currentTrip?.tripId, "B456")
        XCTAssertEqual(payload.currentTrip?.displayLabel, "ANC-SDF-ONT")
    }

    func test_currentTrip_nilOutsideTripWindow() {
        let leg = makeLeg(
            flight: "5X100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-05T10:00:00Z",
            arrUTC: "2026-05-05T17:00:00Z"
        )

        let before = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )
        let after = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-05T18:00:00Z")
        )

        XCTAssertNil(before.currentTrip)
        XCTAssertNil(after.currentTrip)
    }

    func test_nextFlight_setToFirstFutureLeg() {
        let past = makeLeg(
            flight: "5X001",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-04T06:00:00Z",
            arrUTC: "2026-05-04T12:00:00Z"
        )
        let future = makeLeg(
            flight: "5X002",
            depAirport: "SDF",
            arrAirport: "ONT",
            depUTC: "2026-05-05T10:00:00Z",
            arrUTC: "2026-05-05T16:00:00Z"
        )

        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [past, future])],
            now: iso("2026-05-04T20:00:00Z")
        )

        XCTAssertEqual(payload.nextFlight?.flightNumber, "5X002")
        XCTAssertEqual(payload.nextFlight?.departureAirport, "SDF")
        XCTAssertEqual(payload.nextFlight?.arrivalAirport, "ONT")
    }

    func test_nextFlight_nilWhenAllLegsArePast() {
        let leg = makeLeg(
            flight: "5X100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-01T10:00:00Z",
            arrUTC: "2026-05-01T17:00:00Z"
        )

        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-05T00:00:00Z")
        )

        XCTAssertNil(payload.nextFlight)
    }

    func test_json_isValidAndContainsRequiredFields() throws {
        let leg = makeLeg(
            flight: "5X123",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-05T10:00:00Z",
            arrUTC: "2026-05-05T17:30:00Z"
        )

        let jsonString = try TripScheduleSnapshotEncoder.json(
            ownerDisplayName: "0554744",
            schedules: [makeSchedule(legs: [leg])],
            now: iso("2026-05-04T00:00:00Z")
        )
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(parsed["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(parsed["generatedAtUTC"])
        XCTAssertNotNil(parsed["owner"])
        XCTAssertNotNil(parsed["scheduleItems"])
    }

    func test_emptySchedules_producesEmptyItems() {
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "0554744",
            schedules: [],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertTrue(payload.scheduleItems.isEmpty)
        XCTAssertNil(payload.currentTrip)
        XCTAssertNil(payload.nextFlight)
    }

    func test_crewAccessTrips_preserveHotelAndDutyDetails() {
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "7793942",
            crewAccessTrips: [makeCrewAccessTrip()],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.schemaVersion, 3)
        XCTAssertEqual(payload.trips.count, 1)
        XCTAssertEqual(payload.trips[0].tripId, "A70628")
        XCTAssertEqual(payload.trips[0].route, "ANC-SDF-ONT")
        XCTAssertEqual(payload.trips[0].hotelDetails, ["Hotel details SDF: Test Hotel / +1 555 0100"])
        XCTAssertEqual(payload.trips[0].dutyTotals, ["Duty 1 Time 12:30 Block 9:00 Rest 24:00"])
        XCTAssertEqual(payload.scheduleItems.map(\.label), ["5X100 ANC-SDF", "5X101 SDF-ONT"])
    }

    func test_crewAccessTrips_buildsTimelineCardsWithLayover() {
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "7793942",
            crewAccessTrips: [makeCrewAccessTrip()],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.timelineCards.map(\.type), ["flight", "layover", "flight"])
        XCTAssertEqual(payload.timelineCards[0].title, "ANC - SDF")
        XCTAssertEqual(payload.timelineCards[0].subtitle, "5X100")
        XCTAssertEqual(payload.timelineCards[0].detail, "Block: 4:00")
        XCTAssertEqual(payload.timelineCards[1].title, "Layover at SDF")
        XCTAssertEqual(payload.timelineCards[1].hotelName, "Test Hotel")
        XCTAssertEqual(payload.timelineCards[1].trailing, "Rest: 26:00")
    }

    func test_crewAccessTrips_layoverRequiresAtLeast180Minutes() {
        let belowThreshold = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "7793942",
            crewAccessTrips: [
                makeCrewAccessTrip(
                    firstEndUTC: "2026-04-27T19:45:00Z",
                    secondStartUTC: "2026-04-27T22:44:00Z"
                )
            ],
            now: iso("2026-05-04T00:00:00Z")
        )
        let atThreshold = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "7793942",
            crewAccessTrips: [
                makeCrewAccessTrip(
                    firstEndUTC: "2026-04-27T19:45:00Z",
                    secondStartUTC: "2026-04-27T22:45:00Z"
                )
            ],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(belowThreshold.timelineCards.map(\.type), ["flight", "flight"])
        XCTAssertEqual(atThreshold.timelineCards.map(\.type), ["flight", "layover", "flight"])
    }

    func test_crewAccessTrips_formatsDeadheadAnd5XFlightText() {
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "7793942",
            crewAccessTrips: [
                makeCrewAccessTrip(
                    firstFlight: "5X100",
                    firstDeadhead: true,
                    secondFlight: "101",
                    secondDeadhead: false
                )
            ],
            now: iso("2026-05-04T00:00:00Z")
        )

        let flightCards = payload.timelineCards.filter { $0.type == "flight" }
        XCTAssertEqual(flightCards[0].subtitle, "DH 5X100")
        XCTAssertEqual(flightCards[0].icon, "paperplane")
        XCTAssertEqual(flightCards[1].subtitle, "5X101")
        XCTAssertEqual(flightCards[1].icon, "airplane")
    }

    func test_crewAccessTrips_parsesModernHotelDetailFormat() {
        let payload = TripScheduleSnapshotEncoder.encode(
            ownerDisplayName: "7793942",
            crewAccessTrips: [
                makeCrewAccessTrip(hotelDetails: ["SDF: Brown Hotel +1 555 0100 (CrewAccess)"])
            ],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertEqual(payload.timelineCards.first(where: { $0.type == "layover" })?.hotelName, "Brown Hotel")
    }

    func test_crewAccessTrips_jsonExcludesCrewList() throws {
        let jsonString = try TripScheduleSnapshotEncoder.json(
            ownerDisplayName: "7793942",
            crewAccessTrips: [makeCrewAccessTrip()],
            now: iso("2026-05-04T00:00:00Z")
        )

        XCTAssertFalse(jsonString.contains("Captain Example"))
        XCTAssertFalse(jsonString.contains("crewID"))
        XCTAssertTrue(jsonString.contains("Test Hotel"))
        XCTAssertTrue(jsonString.contains(#""schemaVersion":3"#))
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func makeCrewAccessTrip(
        hotelDetails: [String] = ["Hotel details SDF: Test Hotel / +1 555 0100"],
        firstFlight: String = "5X100",
        firstDeadhead: Bool = false,
        firstEndUTC: String = "2026-04-27T19:45:00Z",
        secondFlight: String = "5X101",
        secondDeadhead: Bool = false,
        secondStartUTC: String = "2026-04-28T21:45:00Z"
    ) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "crewaccess-pdf",
            sourceVersion: "test",
            mappingVersion: "test",
            generatedAt: "2026-05-04T00:00:00Z",
            tripId: "A70628",
            tripInformationDate: "2026-04-27",
            creditTime: "15:00",
            tripDays: "2",
            tafb: "36:00",
            dutyTotals: ["Duty 1 Time 12:30 Block 9:00 Rest 24:00"],
            hotelDetails: hotelDetails,
            crew: [
                CrewAccessCrewJSON(
                    position: "CA",
                    seniority: "1",
                    crewID: "1234567",
                    name: "Captain Example"
                )
            ],
            items: [
                makeCrewAccessItem(
                    sequence: 1,
                    flight: firstFlight,
                    deadhead: firstDeadhead,
                    depAirport: "ANC",
                    arrAirport: "SDF",
                    startUTC: "2026-04-27T07:24:00Z",
                    endUTC: firstEndUTC
                ),
                makeCrewAccessItem(
                    sequence: 2,
                    flight: secondFlight,
                    deadhead: secondDeadhead,
                    depAirport: "SDF",
                    arrAirport: "ONT",
                    startUTC: secondStartUTC,
                    endUTC: "2026-04-29T00:15:00Z"
                )
            ]
        )
    }

    private func makeCrewAccessItem(
        sequence: Int,
        flight: String,
        deadhead: Bool = false,
        depAirport: String,
        arrAirport: String,
        startUTC: String,
        endUTC: String
    ) -> CrewAccessTripItemJSON {
        CrewAccessTripItemJSON(
            sequence: sequence,
            depAirport: depAirport,
            arrAirport: arrAirport,
            deadhead: deadhead,
            flight: flight,
            startUtc: startUTC,
            endUtc: endUTC,
            startLocalDisplay: startUTC,
            endLocalDisplay: endUTC,
            originTz: "America/Anchorage",
            destinationTz: "America/New_York",
            timeDerivation: "pdf",
            aircraft: "747",
            block: "4:00",
            stdUtc: startUTC,
            staUtc: endUTC,
            atdUtc: nil,
            ataUtc: nil,
            tailNumber: nil
        )
    }
}
