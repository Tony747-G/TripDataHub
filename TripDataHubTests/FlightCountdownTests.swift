import XCTest
@testable import TripData_Hub

// MARK: - Phase boundary tests

final class FlightCountdownPhaseTests: XCTestCase {
    // Fixed reference departure: 2026-07-01T12:00:00Z (summer, no DST ambiguity at ref point)
    private let dep = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    private func phase(offset: TimeInterval) -> CountdownPresentationPhase {
        FlightCountdownSharedStore.phase(
            scheduledDepartureUTC: dep,
            now: dep.addingTimeInterval(offset)
        )
    }

    // MARK: .none region

    func test_phase_atT_minus_13h_isNone() {
        XCTAssertEqual(phase(offset: -(13 * 3600)), .none)
    }

    func test_phase_justBefore_widgetStart_isNone() {
        XCTAssertEqual(phase(offset: -(12 * 3600) - 1), .none)
    }

    // MARK: .widget region

    func test_phase_atExact_T_minus_12h_isWidget() {
        XCTAssertEqual(phase(offset: -(12 * 3600)), .widget)
    }

    func test_phase_atT_minus_11h_isWidget() {
        XCTAssertEqual(phase(offset: -(11 * 3600)), .widget)
    }

    func test_phase_atT_minus_7h_isWidget() {
        XCTAssertEqual(phase(offset: -(7 * 3600)), .widget)
    }

    func test_phase_justBefore_liveStart_isWidget() {
        XCTAssertEqual(phase(offset: -(6 * 3600) - 1), .widget)
    }

    // MARK: .liveCountdown region

    func test_phase_atExact_T_minus_6h_isLiveCountdown() {
        XCTAssertEqual(phase(offset: -(6 * 3600)), .liveCountdown)
    }

    func test_phase_atT_minus_5h_isLiveCountdown() {
        XCTAssertEqual(phase(offset: -(5 * 3600)), .liveCountdown)
    }

    func test_phase_atT_minus_1m_isLiveCountdown() {
        XCTAssertEqual(phase(offset: -60), .liveCountdown)
    }

    func test_phase_atT_minus_1s_isLiveCountdown() {
        XCTAssertEqual(phase(offset: -1), .liveCountdown)
    }

    // MARK: .liveDelayed region

    func test_phase_atExact_T0_isLiveDelayed() {
        XCTAssertEqual(phase(offset: 0), .liveDelayed)
    }

    func test_phase_atT_plus_1m_isLiveDelayed() {
        XCTAssertEqual(phase(offset: 60), .liveDelayed)
    }

    func test_phase_atT_plus_5h59m_isLiveDelayed() {
        XCTAssertEqual(phase(offset: 5 * 3600 + 59 * 60), .liveDelayed)
    }

    func test_phase_justBefore_finished_isLiveDelayed() {
        XCTAssertEqual(phase(offset: 6 * 3600 - 1), .liveDelayed)
    }

    // MARK: .finished region

    func test_phase_atExact_T_plus_6h_isFinished() {
        XCTAssertEqual(phase(offset: 6 * 3600), .finished)
    }

    func test_phase_atT_plus_6h01m_isFinished() {
        XCTAssertEqual(phase(offset: 6 * 3600 + 60), .finished)
    }
}

// MARK: - Duration text tests

final class FlightCountdownDurationTextTests: XCTestCase {
    private let anchor = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    private func dur(_ seconds: TimeInterval) -> String {
        FlightCountdownSharedStore.durationText(from: anchor, to: anchor.addingTimeInterval(seconds))
    }

    func test_durationText_2h11m() {
        XCTAssertEqual(dur(2 * 3600 + 11 * 60), "2h 11m")
    }

    func test_durationText_1h46m() {
        // From CLAUDE.md delayed example: "Delayed 1h 46m"
        XCTAssertEqual(dur(1 * 3600 + 46 * 60), "1h 46m")
    }

    func test_durationText_1h0m() {
        XCTAssertEqual(dur(3600), "1h 0m")
    }

    func test_durationText_0h45m() {
        XCTAssertEqual(dur(45 * 60), "0h 45m")
    }

    func test_durationText_0h0m_whenEqual() {
        XCTAssertEqual(FlightCountdownSharedStore.durationText(from: anchor, to: anchor), "0h 0m")
    }

    func test_durationText_0h0m_whenEndBeforeStart() {
        XCTAssertEqual(FlightCountdownSharedStore.durationText(from: anchor, to: anchor.addingTimeInterval(-100)), "0h 0m")
    }

    func test_durationText_truncatesSeconds_notRounds() {
        // 90 seconds = 1m 30s → truncated to 1m (not rounded to 2m)
        XCTAssertEqual(dur(90), "0h 1m")
    }

    func test_durationText_59seconds_isZeroMinutes() {
        XCTAssertEqual(dur(59), "0h 0m")
    }
}

// MARK: - Status text tests

final class FlightCountdownStatusTextTests: XCTestCase {
    private let dep = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    private func leg() -> FlightCountdownLeg {
        FlightCountdownLeg(
            id: "L1", flightNumber: "5X76", isDeadhead: false,
            departureAirportIATA: "ANC", arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: dep,
            scheduledArrivalUTC: dep.addingTimeInterval(8 * 3600),
            departureTimeZoneID: "America/Anchorage",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
    }

    func test_statusText_widgetPhase_showsCountdown() {
        let now = dep.addingTimeInterval(-(7 * 3600)) // T-7h
        XCTAssertEqual(FlightCountdownEngine.statusText(for: leg(), nowUTC: now), "Departure in 7h 0m")
    }

    func test_statusText_liveCountdown_showsCountdown() {
        let now = dep.addingTimeInterval(-(2 * 3600 + 11 * 60)) // T-2h11m
        XCTAssertEqual(FlightCountdownEngine.statusText(for: leg(), nowUTC: now), "Departure in 2h 11m")
    }

    func test_statusText_liveDelayed_showsDelayed() {
        let now = dep.addingTimeInterval(1 * 3600 + 46 * 60) // T+1h46m
        XCTAssertEqual(FlightCountdownEngine.statusText(for: leg(), nowUTC: now), "Delayed 1h 46m")
    }

    func test_statusText_nonePhase_isNil() {
        let now = dep.addingTimeInterval(-(13 * 3600)) // T-13h
        XCTAssertNil(FlightCountdownEngine.statusText(for: leg(), nowUTC: now))
    }

    func test_statusText_finishedPhase_isNil() {
        let now = dep.addingTimeInterval(7 * 3600) // T+7h
        XCTAssertNil(FlightCountdownEngine.statusText(for: leg(), nowUTC: now))
    }
}

// MARK: - Leg selection tests

final class FlightCountdownLegSelectionTests: XCTestCase {
    private let dep = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    private func makeLeg(
        id: String,
        depUTC: Date,
        isDeadhead: Bool = false
    ) -> FlightCountdownLeg {
        FlightCountdownLeg(
            id: id,
            flightNumber: "5X76",
            isDeadhead: isDeadhead,
            departureAirportIATA: "ANC",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: depUTC.addingTimeInterval(8 * 3600),
            departureTimeZoneID: "America/Anchorage",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
    }

    private func select(_ legs: [FlightCountdownLeg], nowOffset: TimeInterval) -> FlightCountdownLeg? {
        FlightCountdownEngine.selectRelevantLeg(from: legs, nowUTC: dep.addingTimeInterval(nowOffset))
    }

    func test_select_noLegs_returnsNil() {
        XCTAssertNil(select([], nowOffset: -(3 * 3600)))
    }

    func test_select_singleLeg_widgetPhase_returnsIt() {
        let leg = makeLeg(id: "L1", depUTC: dep)
        XCTAssertEqual(select([leg], nowOffset: -(9 * 3600)), leg)
    }

    func test_select_singleLeg_liveCountdown_returnsIt() {
        let leg = makeLeg(id: "L1", depUTC: dep)
        XCTAssertEqual(select([leg], nowOffset: -(3 * 3600)), leg)
    }

    func test_select_singleLeg_liveDelayed_returnsIt() {
        let leg = makeLeg(id: "L1", depUTC: dep)
        XCTAssertEqual(select([leg], nowOffset: 2 * 3600), leg)
    }

    func test_select_singleLeg_outsideAllWindows_returnsNil() {
        let leg = makeLeg(id: "L1", depUTC: dep)
        XCTAssertNil(select([leg], nowOffset: -(13 * 3600)))
    }

    func test_select_deadheadLeg_isReturned() {
        let dhLeg = makeLeg(id: "DH1", depUTC: dep, isDeadhead: true)
        XCTAssertEqual(select([dhLeg], nowOffset: -(3 * 3600))?.id, "DH1")
    }

    func test_select_liveCountdown_preferredOverWidget() {
        // now = T-3h for dep → liveLeg is liveCountdown
        // widgetLeg departs 6h later → now is T-9h for it → widget phase
        let now: TimeInterval = -(3 * 3600)
        let liveLeg = makeLeg(id: "live", depUTC: dep)
        let widgetLeg = makeLeg(id: "widget", depUTC: dep.addingTimeInterval(6 * 3600))
        XCTAssertEqual(select([widgetLeg, liveLeg], nowOffset: now)?.id, "live")
    }

    func test_select_widget_preferredOverDelayed() {
        // widgetLeg departs in 9h → now is T-9h → widget phase
        // delayedLeg departed 2h ago → liveDelayed phase
        let now: TimeInterval = 0
        let widgetLeg = makeLeg(id: "widget", depUTC: dep.addingTimeInterval(9 * 3600))
        let delayedLeg = makeLeg(id: "delayed", depUTC: dep.addingTimeInterval(-(2 * 3600)))
        XCTAssertEqual(select([delayedLeg, widgetLeg], nowOffset: now)?.id, "widget")
    }

    func test_select_multipleWidgetLegs_earliestDepartureWins() {
        // Both legs in widget phase; earlyLeg departs first
        let now: TimeInterval = -(9 * 3600)
        let earlyLeg = makeLeg(id: "early", depUTC: dep)
        let laterLeg = makeLeg(id: "later", depUTC: dep.addingTimeInterval(3600))
        XCTAssertEqual(select([laterLeg, earlyLeg], nowOffset: now)?.id, "early")
    }

    func test_select_previousLegFinished_nextLegPickedUp() {
        // finishedLeg departed 7h ago → finished phase
        // nextLeg departs in 9h → widget phase
        let finishedLeg = makeLeg(id: "finished", depUTC: dep.addingTimeInterval(-(7 * 3600)))
        let nextLeg = makeLeg(id: "next", depUTC: dep.addingTimeInterval(9 * 3600))
        XCTAssertEqual(select([finishedLeg, nextLeg], nowOffset: 0)?.id, "next")
    }

    func test_select_multiLegTrip_currentLegActive_nextIgnored() {
        // currentLeg is in liveCountdown (T-3h); nextLeg is outside window (T-20h from nextLeg)
        // Only currentLeg should be returned
        let now: TimeInterval = -(3 * 3600)
        let currentLeg = makeLeg(id: "current", depUTC: dep)
        let nextLeg = makeLeg(id: "next", depUTC: dep.addingTimeInterval(17 * 3600)) // T-20h from nextLeg
        XCTAssertEqual(select([currentLeg, nextLeg], nowOffset: now)?.id, "current")
    }
}

// MARK: - Display string / timezone tests

final class FlightCountdownDisplayStringsTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    func test_displayStrings_ANCtoNRT_correctLocalTimes() throws {
        // dep: 2026-07-01T23:00:00Z
        //   ANC (AKDT = UTC-8 in July): Jul 1, 15:00
        // arr: 2026-07-02T16:00:00Z
        //   NRT (JST = UTC+9): Jul 3, 01:00  ← crosses date line
        let depUTC = iso.date(from: "2026-07-01T23:00:00Z")!
        let arrUTC = iso.date(from: "2026-07-02T16:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "anc-nrt",
            flightNumber: "5X76",
            isDeadhead: false,
            departureAirportIATA: "ANC",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: arrUTC,
            departureTimeZoneID: "America/Anchorage",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
        let now = depUTC.addingTimeInterval(-(11 * 3600)) // T-11h, widget phase
        let strings = try XCTUnwrap(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))

        XCTAssertEqual(strings.departureDateText, "Jul 1")
        XCTAssertEqual(strings.departureTimeText, "15:00")
        XCTAssertEqual(strings.arrivalDateText, "Jul 3")   // date-line crossing
        XCTAssertEqual(strings.arrivalTimeText, "01:00")
    }

    func test_displayStrings_CGNtoHKG_correctLocalTimes() throws {
        // dep: 2026-07-15T06:00:00Z
        //   CGN (CEST = UTC+2 in July): Jul 15, 08:00
        // arr: 2026-07-16T02:00:00Z
        //   HKG (HKT = UTC+8): Jul 16, 10:00
        let depUTC = iso.date(from: "2026-07-15T06:00:00Z")!
        let arrUTC = iso.date(from: "2026-07-16T02:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "cgn-hkg",
            flightNumber: "5X218",
            isDeadhead: false,
            departureAirportIATA: "CGN",
            arrivalAirportIATA: "HKG",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: arrUTC,
            departureTimeZoneID: "Europe/Berlin",
            arrivalTimeZoneID: "Asia/Hong_Kong"
        )
        let now = depUTC.addingTimeInterval(-(9 * 3600)) // T-9h, widget phase
        let strings = try XCTUnwrap(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))

        XCTAssertEqual(strings.departureDateText, "Jul 15")
        XCTAssertEqual(strings.departureTimeText, "08:00")
        XCTAssertEqual(strings.arrivalDateText, "Jul 16")
        XCTAssertEqual(strings.arrivalTimeText, "10:00")
    }

    func test_displayStrings_ANCtoNRT_winter_DSToff() throws {
        // Alaska in January observes AKST (UTC-9), not AKDT (UTC-8)
        // dep: 2026-01-10T21:00:00Z → ANC AKST: Jan 10, 12:00
        // arr: 2026-01-11T14:00:00Z → NRT JST:  Jan 11, 23:00
        let depUTC = iso.date(from: "2026-01-10T21:00:00Z")!
        let arrUTC = iso.date(from: "2026-01-11T14:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "anc-nrt-winter",
            flightNumber: "5X76",
            isDeadhead: false,
            departureAirportIATA: "ANC",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: arrUTC,
            departureTimeZoneID: "America/Anchorage",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
        let now = depUTC.addingTimeInterval(-(9 * 3600)) // T-9h, widget phase
        let strings = try XCTUnwrap(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))

        XCTAssertEqual(strings.departureDateText, "Jan 10")
        XCTAssertEqual(strings.departureTimeText, "12:00") // AKST = UTC-9
        XCTAssertEqual(strings.arrivalDateText, "Jan 11")
        XCTAssertEqual(strings.arrivalTimeText, "23:00")   // JST = UTC+9
    }

    func test_displayStrings_SDF_summerDST_departureSide() throws {
        // SDF (Louisville) observes EDT (UTC-4) in summer
        // dep: 2026-07-20T16:00:00Z → SDF EDT: Jul 20, 12:00
        // arr: 2026-07-21T04:00:00Z → NRT JST: Jul 21, 13:00
        let depUTC = iso.date(from: "2026-07-20T16:00:00Z")!
        let arrUTC = iso.date(from: "2026-07-21T04:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "sdf-nrt",
            flightNumber: "5X100",
            isDeadhead: false,
            departureAirportIATA: "SDF",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: arrUTC,
            departureTimeZoneID: "America/Kentucky/Louisville",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
        let now = depUTC.addingTimeInterval(-(9 * 3600)) // T-9h, widget phase
        let strings = try XCTUnwrap(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))

        XCTAssertEqual(strings.departureDateText, "Jul 20")
        XCTAssertEqual(strings.departureTimeText, "12:00") // EDT = UTC-4
        XCTAssertEqual(strings.arrivalDateText, "Jul 21")
        XCTAssertEqual(strings.arrivalTimeText, "13:00")   // JST = UTC+9
    }

    func test_displayStrings_SDF_winterNoDST_departureSide() throws {
        // SDF in winter observes EST (UTC-5)
        // dep: 2026-01-20T17:00:00Z → SDF EST: Jan 20, 12:00
        // arr: 2026-01-21T05:00:00Z → NRT JST: Jan 21, 14:00
        let depUTC = iso.date(from: "2026-01-20T17:00:00Z")!
        let arrUTC = iso.date(from: "2026-01-21T05:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "sdf-nrt-winter",
            flightNumber: "5X100",
            isDeadhead: false,
            departureAirportIATA: "SDF",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: arrUTC,
            departureTimeZoneID: "America/Kentucky/Louisville",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
        let now = depUTC.addingTimeInterval(-(9 * 3600)) // T-9h, widget phase
        let strings = try XCTUnwrap(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))

        XCTAssertEqual(strings.departureDateText, "Jan 20")
        XCTAssertEqual(strings.departureTimeText, "12:00") // EST = UTC-5
        XCTAssertEqual(strings.arrivalDateText, "Jan 21")
        XCTAssertEqual(strings.arrivalTimeText, "14:00")   // JST = UTC+9
    }

    func test_displayStrings_arrivalDateAlwaysInRouteText() throws {
        // Verifies arrival date is always included in routeText, even when it appears same-day
        let depUTC = iso.date(from: "2026-07-01T23:00:00Z")!
        let arrUTC = iso.date(from: "2026-07-02T16:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "route-check",
            flightNumber: nil,
            isDeadhead: false,
            departureAirportIATA: "ANC",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: arrUTC,
            departureTimeZoneID: "America/Anchorage",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
        let now = depUTC.addingTimeInterval(-(9 * 3600))
        let strings = try XCTUnwrap(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))

        XCTAssertTrue(
            strings.routeText.contains(strings.arrivalDateText),
            "routeText '\(strings.routeText)' should contain arrivalDateText '\(strings.arrivalDateText)'"
        )
    }

    func test_displayStrings_nilWhenPhaseIsNone() {
        let depUTC = iso.date(from: "2026-07-01T12:00:00Z")!
        let leg = FlightCountdownLeg(
            id: "out-of-window",
            flightNumber: "5X76",
            isDeadhead: false,
            departureAirportIATA: "ANC",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: depUTC,
            scheduledArrivalUTC: depUTC.addingTimeInterval(8 * 3600),
            departureTimeZoneID: "America/Anchorage",
            arrivalTimeZoneID: "Asia/Tokyo"
        )
        let now = depUTC.addingTimeInterval(-(13 * 3600)) // T-13h, none phase
        XCTAssertNil(FlightCountdownEngine.displayStrings(for: leg, nowUTC: now))
    }
}
