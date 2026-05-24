import XCTest
@testable import TripDataHub

final class WatchSnapshotGeneratorTests: XCTestCase {

    // Fixed reference point for all tests
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000) // deterministic

    // MARK: - Trip mode

    func test_activeTripLeg_returnsTrip() throws {
        let sched = schedule(depOffset: -3600, arrOffset: 3600)
        let snap = generate(schedules: [sched])
        XCTAssertEqual(snap.mode, .trip)
        XCTAssertNotNil(snap.trip)
    }

    func test_upcomingTripWithin24h_returnsTrip() throws {
        let sched = schedule(depOffset: 20 * 3600, arrOffset: 25 * 3600)
        let snap = generate(schedules: [sched])
        XCTAssertEqual(snap.mode, .trip)
        XCTAssertNotNil(snap.trip)
    }

    func test_upcomingTripBeyond25h30m_returnsOffDuty() throws {
        // tripLeadWindow = 25.5h; 26h is outside
        let sched = schedule(depOffset: 26 * 3600, arrOffset: 31 * 3600)
        let snap = generate(schedules: [sched])
        XCTAssertEqual(snap.mode, .offDuty)
    }

    func test_upcomingDomicileTripAt25h30m_returnsTrip() throws {
        let sched = schedule(depOffset: WatchSnapshotGenerator.tripLeadWindow, arrOffset: 30 * 3600)
        let snap = generate(schedules: [sched])
        XCTAssertEqual(snap.mode, .trip)
    }

    func test_upcomingTripAt25h_returnsTrip() throws {
        // 25h < 25.5h window → Trip mode (report would be 23.5h away)
        let sched = schedule(depOffset: 25 * 3600, arrOffset: 30 * 3600)
        let snap = generate(schedules: [sched])
        XCTAssertEqual(snap.mode, .trip)
    }

    func test_legFinished_beyond6hAfterArr_returnsOffDuty() throws {
        let sched = schedule(depOffset: -10 * 3600, arrOffset: -7 * 3600)
        let snap = generate(schedules: [sched])
        XCTAssertEqual(snap.mode, .offDuty)
    }

    func test_tripPayload_iataAndTimezones() throws {
        let sched = schedule(depOffset: -1800, arrOffset: 7200)
        let snap = generate(schedules: [sched])
        let trip = try XCTUnwrap(snap.trip)
        XCTAssertEqual(trip.depIata, "ANC")
        XCTAssertEqual(trip.arrIata, "SDF")
        XCTAssertNotNil(TimeZone(identifier: trip.depTimeZoneIdentifier))
        XCTAssertNotNil(TimeZone(identifier: trip.arrTimeZoneIdentifier))
        XCTAssertLessThan(trip.depUtc, trip.arrUtc)
    }

    func test_tripDuringLongLayover_displaysNextFlightInSamePairing() throws {
        let sched = schedule(legs: [
            leg(number: 1, depOffset: -5 * 3600, arrOffset: -3600, dep: "ANC", arr: "SDF"),
            leg(number: 2, depOffset: 30 * 3600, arrOffset: 36 * 3600, dep: "SDF", arr: "ANC")
        ])
        let snap = generate(schedules: [sched])
        let trip = try XCTUnwrap(snap.trip)
        XCTAssertEqual(snap.mode, .trip)
        XCTAssertEqual(trip.depIata, "SDF")
        XCTAssertEqual(trip.arrIata, "ANC")
        XCTAssertNil(trip.reportUtc)
    }

    func test_sdfPairingContinuesAfterIntermediateReturnToDomicile() throws {
        let sched = schedule(legs: [
            leg(number: 1, depOffset: -8 * 3600, arrOffset: -7 * 3600, dep: "SDF", arr: "EWR"),
            leg(number: 2, depOffset: -6 * 3600, arrOffset: -5 * 3600, dep: "EWR", arr: "SDF"),
            leg(number: 3, depOffset: 2 * 3600, arrOffset: 5 * 3600, dep: "SDF", arr: "DFW"),
            leg(number: 4, depOffset: 32 * 3600, arrOffset: 35 * 3600, dep: "DFW", arr: "SDF"),
            leg(number: 5, depOffset: 38 * 3600, arrOffset: 40 * 3600, dep: "SDF", arr: "ATL"),
            leg(number: 6, depOffset: 42 * 3600, arrOffset: 44 * 3600, dep: "ATL", arr: "SDF")
        ])
        let snap = generate(schedules: [sched], crewBase: .sdf)
        let trip = try XCTUnwrap(snap.trip)
        XCTAssertEqual(snap.mode, .trip)
        XCTAssertEqual(trip.depIata, "SDF")
        XCTAssertEqual(trip.arrIata, "DFW")
        XCTAssertEqual(trip.reportUtc, now.addingTimeInterval(2 * 3600 - WatchSnapshotGenerator.reportLeadBeforeDep))
    }

    func test_duplicatePairingUsesLatestScheduleUpdatedAt() throws {
        let stale = schedule(
            id: "stale",
            updatedAt: now.addingTimeInterval(-3600),
            legs: [leg(number: 1, depOffset: 2 * 3600, arrOffset: 5 * 3600, dep: "ANC", arr: "SDF")]
        )
        let corrected = schedule(
            id: "corrected",
            updatedAt: now,
            legs: [leg(number: 1, depOffset: 3 * 3600, arrOffset: 6 * 3600, dep: "ANC", arr: "DFW")]
        )
        let snap = generate(schedules: [stale, corrected])
        let trip = try XCTUnwrap(snap.trip)
        XCTAssertEqual(trip.depIata, "ANC")
        XCTAssertEqual(trip.arrIata, "DFW")
        XCTAssertEqual(trip.depUtc, now.addingTimeInterval(3 * 3600))
    }

    // MARK: - Reserve mode

    func test_activeReserve_returnsReserve() throws {
        let event = try manualEvent(code: .reserveC, startOffset: -3600, endOffset: 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .reserve)
        XCTAssertNotNil(snap.reserve)
    }

    func test_activeLCO_returnsReserve() throws {
        let event = try manualEvent(code: .lco, startOffset: -1800, endOffset: 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .reserve)
    }

    func test_activeRCID_returnsReserve() throws {
        let event = try manualEvent(code: .rcid, startOffset: -1800, endOffset: 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .reserve)
    }

    func test_upcomingReserveNotStarted_returnsOffDuty() throws {
        let event = try manualEvent(code: .reserveC, startOffset: 3600, endOffset: 7200)
        let snap = generate(manualEvents: [event])
        // Reserve only shows for active windows
        XCTAssertEqual(snap.mode, .offDuty)
    }

    func test_hotIsNotWatchReserveMode() throws {
        let event = try manualEvent(code: .hot, startOffset: -3600, endOffset: 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .offDuty)
    }

    func test_reservePayload_fields() throws {
        let event = try manualEvent(code: .reserveC, startOffset: -3600, endOffset: 3600)
        let snap = generate(manualEvents: [event])
        let reserve = try XCTUnwrap(snap.reserve)
        XCTAssertEqual(reserve.reserveType, "RSV-C")
        XCTAssertEqual(reserve.domicile, "ANC")
        XCTAssertNotNil(TimeZone(identifier: reserve.ldtTimeZoneIdentifier))
        XCTAssertLessThan(reserve.windowStartUtc, reserve.windowEndUtc)
    }

    // MARK: - Training mode

    func test_activeCQ_returnsTraining() throws {
        let event = try manualEvent(code: .cq12, startOffset: -3600, endOffset: 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .training)
        XCTAssertNotNil(snap.training)
    }

    func test_upcomingCQWithin6h_returnsTraining() throws {
        let event = try manualEvent(code: .cq6, startOffset: 3 * 3600, endOffset: 7 * 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .training)
    }

    func test_upcomingCQBeyond6h_returnsOffDuty() throws {
        let event = try manualEvent(code: .cq12, startOffset: 8 * 3600, endOffset: 12 * 3600)
        let snap = generate(manualEvents: [event])
        XCTAssertEqual(snap.mode, .offDuty)
    }

    func test_trainingPayload_fields() throws {
        let event = try manualEvent(code: .cq12, startOffset: -1800, endOffset: 7200)
        let snap = generate(manualEvents: [event])
        let training = try XCTUnwrap(snap.training)
        XCTAssertEqual(training.eventName, "CQ12")
        XCTAssertFalse(training.startLdtFormatted.isEmpty)
        XCTAssertTrue(training.startLdtFormatted.hasSuffix(" LDT"))
        XCTAssertFalse(training.dateLabelFormatted.isEmpty)
    }

    // MARK: - Off-duty

    func test_noEvents_returnsOffDutyWithNilPayload() {
        let snap = generate()
        XCTAssertEqual(snap.mode, .offDuty)
        XCTAssertNil(snap.offDuty)
    }

    func test_offDuty_nextTripPopulated() throws {
        let sched = schedule(depOffset: 32 * 3600, arrOffset: 37 * 3600)
        let snap = generate(schedules: [sched])
        let od = try XCTUnwrap(snap.offDuty)
        XCTAssertEqual(od.nextDutyType, "TRIP")
        XCTAssertEqual(od.dutyTimeLabel, "Report")
        XCTAssertEqual(od.nextDutyStartUtc, now.addingTimeInterval(32 * 3600 - WatchSnapshotGenerator.reportLeadBeforeDep))
        XCTAssertFalse(od.dateLabelFormatted.isEmpty)
        XCTAssertFalse(od.dayOfWeekFormatted.isEmpty)
        XCTAssertTrue(od.reportLdtFormatted.hasSuffix(" LDT"))
    }

    func test_offDuty_nonDomicileOriginUsesDepartureLabel() throws {
        let sched = schedule(depOffset: 32 * 3600, arrOffset: 37 * 3600, dep: "EWR", arr: "SDF")
        let snap = generate(schedules: [sched])
        let od = try XCTUnwrap(snap.offDuty)
        XCTAssertEqual(od.nextDutyType, "TRIP")
        XCTAssertEqual(od.dutyTimeLabel, "Departure")
        XCTAssertEqual(od.nextDutyStartUtc, now.addingTimeInterval(32 * 3600))
    }

    func test_offDuty_nextReservePopulated() throws {
        let event = try manualEvent(code: .reserveC, startOffset: 25 * 3600, endOffset: 32 * 3600)
        let snap = generate(manualEvents: [event])
        let od = try XCTUnwrap(snap.offDuty)
        XCTAssertEqual(od.nextDutyType, "RSV")
    }

    func test_offDuty_nextCQPopulated() throws {
        let event = try manualEvent(code: .cq6, startOffset: 10 * 3600, endOffset: 16 * 3600)
        let snap = generate(manualEvents: [event])
        let od = try XCTUnwrap(snap.offDuty)
        XCTAssertEqual(od.nextDutyType, "CQ")
    }

    func test_offDuty_picksEarlierOf_tripVsManual() throws {
        // Reserve starts in 10h, trip departs in 32h (outside 30h window) → reserve is next duty
        let event = try manualEvent(code: .reserveC, startOffset: 10 * 3600, endOffset: 18 * 3600)
        let sched = schedule(depOffset: 32 * 3600, arrOffset: 37 * 3600)
        let snap = generate(schedules: [sched], manualEvents: [event])
        let od = try XCTUnwrap(snap.offDuty)
        XCTAssertEqual(od.nextDutyType, "RSV")
    }

    // MARK: - Priority

    func test_priority_activeReserveBeatsActiveTripLeg() throws {
        let event = try manualEvent(code: .reserveC, startOffset: -3600, endOffset: 3600)
        let sched = schedule(depOffset: -1800, arrOffset: 3600)
        let snap = generate(schedules: [sched], manualEvents: [event])
        XCTAssertEqual(snap.mode, .reserve)
    }

    func test_priority_activeReserveBeatsUpcomingTrip() throws {
        let event = try manualEvent(code: .reserveC, startOffset: -3600, endOffset: 3600)
        let sched = schedule(depOffset: 12 * 3600, arrOffset: 16 * 3600)
        let snap = generate(schedules: [sched], manualEvents: [event])
        XCTAssertEqual(snap.mode, .reserve)
    }

    func test_priority_upcomingTripBeatsCQ_whenTripIsWithinWindow() throws {
        let event = try manualEvent(code: .cq12, startOffset: 3 * 3600, endOffset: 7 * 3600)
        let sched = schedule(depOffset: 5 * 3600, arrOffset: 10 * 3600)
        let snap = generate(schedules: [sched], manualEvents: [event])
        // Trip is within T-24h window and has higher priority than upcoming CQ
        XCTAssertEqual(snap.mode, .trip)
    }

    // MARK: - generateAtUTC

    func test_generatedAtUTC_matchesNow() {
        let snap = generate()
        XCTAssertEqual(snap.generatedAtUTC.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
    }

    // MARK: - Helpers

    private func generate(
        schedules: [PayPeriodSchedule] = [],
        manualEvents: [ManualOperationalEvent] = [],
        crewBase: CrewBase = .anc
    ) -> WatchOperationalSnapshot {
        WatchSnapshotGenerator.generate(
            schedules: schedules,
            manualEvents: manualEvents,
            crewBase: crewBase,
            now: now,
            tzResolver: FakeWatchTZResolver()
        )
    }

    private func schedule(depOffset: TimeInterval, arrOffset: TimeInterval,
                          dep: String = "ANC", arr: String = "SDF") -> PayPeriodSchedule {
        schedule(legs: [leg(number: 1, depOffset: depOffset, arrOffset: arrOffset, dep: dep, arr: arr)])
    }

    private func schedule(id: String = "TEST", updatedAt: Date? = nil, legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: id,
            label: "Test",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: updatedAt ?? now,
            legs: legs,
            openTimeTrips: []
        )
    }

    private func leg(number: Int, depOffset: TimeInterval, arrOffset: TimeInterval,
                     dep: String = "ANC", arr: String = "SDF", pairing: String = "TST01") -> TripLeg {
        TripLeg(
            payPeriod: "PP26-01",
            pairing: pairing,
            leg: number,
            flight: "5X101",
            depAirport: dep,
            depLocal: "07:30",
            arrAirport: arr,
            arrLocal: "11:30",
            depUTC: iso8601(now.addingTimeInterval(depOffset)),
            arrUTC: iso8601(now.addingTimeInterval(arrOffset)),
            status: "-",
            block: "4:00"
        )
    }

    private func manualEvent(
        code: ManualOperationalCode,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        crewBase: CrewBase = .anc
    ) throws -> ManualOperationalEvent {
        try ManualOperationalEvent(
            code: code,
            crewBase: crewBase,
            startUTC: now.addingTimeInterval(startOffset),
            endUTC: now.addingTimeInterval(endOffset)
        )
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - Fake TZ resolver with real identifiers for ANC / SDF

private final class FakeWatchTZResolver: IATATimeZoneResolving, @unchecked Sendable {
    var mappingVersion: String { "fake-watch" }
    private let map: [String: String] = [
        "ANC": "America/Anchorage",
        "SDF": "America/Kentucky/Louisville",
        "EWR": "America/New_York",
        "DFW": "America/Chicago",
        "ATL": "America/New_York"
    ]
    func resolve(_ iata: String) -> String? { map[iata] }
    func airportName(_ iata: String) -> String? { nil }
    func cityName(_ iata: String) -> String? { nil }
    func setOverride(iata: String, tzID: String?) {}
    func currentOverrides() -> [String: String] { [:] }
}
