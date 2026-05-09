import CoreGraphics
import XCTest
@testable import TripDataHub

final class CalendarBidPeriodGenerationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_generateBidPeriodDays_returns56Days() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        XCTAssertEqual(days.count, 56)
    }

    func test_generateBidPeriodDays_supportsShortBidPeriod() {
        let days = generateBidPeriodDays(
            startUTC: Self.iso.date(from: "2026-11-01T00:00:00Z")!,
            payPeriodCount: 1
        )
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(days[0].payPeriodIndex, 0)
        XCTAssertEqual(days[27].payPeriodIndex, 0)
    }

    func test_generateBidPeriodDays_usesSundayFirstIndexing() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        XCTAssertEqual(days[0].weekIndex, 0)
        XCTAssertEqual(days[0].weekdayIndex, 0)
        XCTAssertEqual(days[6].weekIndex, 0)
        XCTAssertEqual(days[6].weekdayIndex, 6)
        XCTAssertEqual(days[7].weekIndex, 1)
        XCTAssertEqual(days[7].weekdayIndex, 0)
    }

    func test_generateBidPeriodDays_assignsPayPeriodIndexAcross56DayWindow() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        XCTAssertEqual(days[0].payPeriodIndex, 0)
        XCTAssertEqual(days[27].payPeriodIndex, 0)
        XCTAssertEqual(days[28].payPeriodIndex, 1)
        XCTAssertEqual(days[55].payPeriodIndex, 1)
    }

    func test_generateBidPeriodDays_areConsecutiveUTCDays() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        for index in 1..<days.count {
            XCTAssertEqual(days[index - 1].dayEndUTC, days[index].dayStartUTC)
        }
    }

    func test_bidPeriod_endDateUTC_isExclusive() {
        let period = bidPeriod(for: Self.iso.date(from: "2026-03-22T12:00:00Z")!)
        XCTAssertNotNil(period)
        XCTAssertNotEqual(bidPeriod(for: period!.endDateUTC)?.id, period?.id)
    }

    func test_bidPeriod_forShortBidPeriod_uses28DayWindow() {
        let period = bidPeriod(for: Self.iso.date(from: "2026-11-15T12:00:00Z")!)
        XCTAssertEqual(period?.id, "BP26-07")
        XCTAssertEqual(period?.days.count, 28)
        XCTAssertEqual(period?.endDateUTC, Self.iso.date(from: "2026-11-29T12:00:00Z"))
        XCTAssertEqual(bidPeriod(for: period!.endDateUTC)?.id, "BP27-01")
    }

    func test_bidPeriod_matchesPayPeriodPairs() {
        let bp2604 = bidPeriod(for: Self.iso.date(from: "2026-05-17T12:00:00Z")!)
        XCTAssertEqual(bp2604?.id, "BP26-04")
        XCTAssertEqual(bp2604?.startDateUTC, Self.iso.date(from: "2026-05-17T11:00:00Z"))
        XCTAssertEqual(bp2604?.endDateUTC, Self.iso.date(from: "2026-07-12T11:00:00Z"))

        let bp2701 = bidPeriod(for: Self.iso.date(from: "2026-11-29T12:00:00Z")!)
        XCTAssertEqual(bp2701?.id, "BP27-01")
        XCTAssertEqual(bp2701?.startDateUTC, Self.iso.date(from: "2026-11-29T12:00:00Z"))
        XCTAssertEqual(bp2701?.endDateUTC, Self.iso.date(from: "2027-01-24T12:00:00Z"))

        let bp2707 = bidPeriod(for: Self.iso.date(from: "2027-11-28T12:00:00Z")!)
        XCTAssertEqual(bp2707?.id, "BP27-07")
        XCTAssertEqual(bp2707?.startDateUTC, Self.iso.date(from: "2027-10-31T11:00:00Z"))
        XCTAssertEqual(bp2707?.endDateUTC, Self.iso.date(from: "2027-12-26T12:00:00Z"))
    }

    func test_bidPeriod_usesAnchorage0300Boundary() {
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T10:59:59Z")!)?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T11:00:00Z")!)?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-07-12T10:59:59Z")!)?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-07-12T11:00:00Z")!)?.id,
            "BP26-05"
        )
    }

    func test_bidPeriod_usesDomicile0300Boundary() {
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T06:59:59Z")!, domicile: "SDF")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T07:00:00Z")!, domicile: "SDF")?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T06:59:59Z")!, domicile: "SDFZ")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T07:00:00Z")!, domicile: "SDFZ")?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T06:59:59Z")!, domicile: "MIA")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T07:00:00Z")!, domicile: "MIA")?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T09:59:59Z")!, domicile: "ONT")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T10:00:00Z")!, domicile: "ONT")?.id,
            "BP26-04"
        )
    }
}

final class OpenTimeSectionBuilderTests: XCTestCase {
    func test_openTimePPLabel_usesLegUTCBeforeDomicile0300Boundary() {
        let trip = openTimeTrip(
            payPeriod: "PP_TRIPBOARD_FALLBACK",
            pairing: "OT-early",
            startLocal: "2026-05-17 02:59",
            depUTC: "2026-05-17T06:59:00Z"
        )
        let sections = OpenTimeSectionBuilder.build(
            schedules: [schedule(id: "OT", label: "PP_TRIPBOARD_FALLBACK", legs: [], openTimeTrips: [trip])],
            domicile: "SDF"
        )

        XCTAssertEqual(sections.map { $0.label }, ["PP26-05"])
    }

    func test_openTimePPLabel_usesLegUTCAtDomicile0300Boundary() {
        let trip = openTimeTrip(
            payPeriod: "PP_TRIPBOARD_FALLBACK",
            pairing: "OT-boundary",
            startLocal: "2026-05-17 03:00",
            depUTC: "2026-05-17T07:00:00Z"
        )
        let sections = OpenTimeSectionBuilder.build(
            schedules: [schedule(id: "OT", label: "PP_TRIPBOARD_FALLBACK", legs: [], openTimeTrips: [trip])],
            domicile: "SDF"
        )

        XCTAssertEqual(sections.map { $0.label }, ["PP26-06"])
    }
}

final class CalendarNormalizationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_normalizeCalendarTrips_groupsByPayPeriodAndPairing() {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T02:00:00Z", arrUTC: "2026-03-22T05:00:00Z"),
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X2", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-03-22T07:00:00Z", arrUTC: "2026-03-22T10:00:00Z")
                ]
            ),
            schedule(
                id: "B",
                label: "PP26-05",
                legs: [
                    leg(payPeriod: "PP26-05", pairing: "1234", flight: "5X3", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-04-19T02:00:00Z", arrUTC: "2026-04-19T05:00:00Z")
                ],
                openTimeTrips: [openTimeTrip(payPeriod: "PP26-05", pairing: "OT100")]
            )
        ]

        let trips = normalizeCalendarTrips(from: schedules)
        XCTAssertEqual(trips.map(\.id), ["PP26-04|1234", "PP26-05|1234"])
    }

    func test_normalizeCalendarTrips_sortsLegsByUTCDeparture() throws {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X2", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-03-22T07:00:00Z", arrUTC: "2026-03-22T10:00:00Z", legNumber: 2),
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T02:00:00Z", arrUTC: "2026-03-22T05:00:00Z", legNumber: 1)
                ]
            )
        ]

        let trip = try XCTUnwrap(normalizeCalendarTrips(from: schedules).first)
        XCTAssertEqual(trip.legs.map(\.flight), ["5X1", "5X2"])
        XCTAssertEqual(trip.startUTC, Self.iso.date(from: "2026-03-22T02:00:00Z"))
        XCTAssertEqual(trip.endUTC, Self.iso.date(from: "2026-03-22T10:00:00Z"))
    }

    func test_normalizeCalendarTrips_excludesMalformedTrips() {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: nil, arrUTC: "2026-03-22T05:00:00Z")
                ]
            )
        ]

        XCTAssertTrue(normalizeCalendarTrips(from: schedules).isEmpty)
    }

    func test_normalizeCalendarTrips_excludesOpenTimeTrips() {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [],
                openTimeTrips: [openTimeTrip(payPeriod: "PP26-04", pairing: "OT100")]
            )
        ]

        XCTAssertTrue(normalizeCalendarTrips(from: schedules).isEmpty)
    }
}

final class CalendarVisibilityTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_visibleTrips_includesPartialOverlapAtStart() {
        let bidPeriod = makeBidPeriod(startUTC: "2026-03-22T00:00:00Z")
        let trip = calendarTrip(
            id: "PP26-04|1234",
            pairing: "1234",
            payPeriod: "PP26-04",
            legs: [],
            startUTC: "2026-03-21T23:00:00Z",
            endUTC: "2026-03-22T02:00:00Z"
        )

        XCTAssertEqual(visibleTrips(in: bidPeriod, trips: [trip]).map(\.id), [trip.id])
    }

    func test_visibleTrips_includesPartialOverlapAtEnd() {
        let bidPeriod = makeBidPeriod(startUTC: "2026-03-22T00:00:00Z")
        let trip = calendarTrip(
            id: "PP26-04|1234",
            pairing: "1234",
            payPeriod: "PP26-04",
            legs: [],
            startUTC: "2026-05-16T23:00:00Z",
            endUTC: "2026-05-17T02:00:00Z"
        )

        XCTAssertEqual(visibleTrips(in: bidPeriod, trips: [trip]).map(\.id), [trip.id])
    }

    func test_visibleTrips_excludesFullyOutsideTrips() {
        let bidPeriod = makeBidPeriod(startUTC: "2026-03-22T00:00:00Z")
        let trip = calendarTrip(
            id: "PP26-04|1234",
            pairing: "1234",
            payPeriod: "PP26-04",
            legs: [],
            startUTC: "2026-05-17T00:00:00Z",
            endUTC: "2026-05-17T02:00:00Z"
        )

        XCTAssertTrue(visibleTrips(in: bidPeriod, trips: [trip]).isEmpty)
    }
}

final class CalendarLocalHelperTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_resolveDayIndex_usesProvidedTimeZoneDeterministically() throws {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        let utcDate = Self.iso.date(from: "2026-03-22T01:00:00Z")!
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let anchorage = try XCTUnwrap(TimeZone(identifier: "America/Anchorage"))

        XCTAssertEqual(resolveDayIndex(for: utcDate, timeZone: tokyo, calendarDays: days), 0)
        XCTAssertEqual(resolveDayIndex(for: utcDate, timeZone: anchorage, calendarDays: days), 0)
        XCTAssertEqual(resolveDayIndex(for: utcDate, timeZone: tokyo, calendarDays: days), resolveDayIndex(for: utcDate, timeZone: tokyo, calendarDays: days))
    }

    func test_dayKey_and_fractionHelpers_useStructuredLocalTime() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let utcDate = Self.iso.date(from: "2026-03-22T12:30:45Z")!

        XCTAssertEqual(dayKey(from: utcDate, timeZone: tokyo), "2026-03-22")
        XCTAssertEqual(localComponents(for: utcDate, timeZone: tokyo).hour, 21)
        XCTAssertEqual(startFraction(for: utcDate, timeZone: tokyo), (21 + (30.0 / 60) + (45.0 / 3600)) / 24, accuracy: 0.000001)
        XCTAssertEqual(endFraction(for: utcDate, timeZone: tokyo), startFraction(for: utcDate, timeZone: tokyo), accuracy: 0.000001)
    }

    func test_fractionHelpers_clampToZeroThroughOne() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let utcDate = Self.iso.date(from: "2026-03-22T23:59:59Z")!
        XCTAssertLessThanOrEqual(startFraction(for: utcDate, timeZone: utc), 1)
        XCTAssertGreaterThanOrEqual(startFraction(for: utcDate, timeZone: utc), 0)
    }
}

final class CalendarRegressionMetadataTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_localRegressionMetadata_sameTimezoneNormalTrip_hasNoRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T14:00:00Z", arrUTC: "2026-03-22T20:00:00Z")
            ]
        )

        XCTAssertTrue(localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)).isEmpty)
    }

    func test_localRegressionMetadata_sameTimezoneOvernightTrip_isNotRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-22T03:00:00Z", arrUTC: "2026-03-22T10:00:00Z")
            ]
        )

        XCTAssertTrue(localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)).isEmpty)
    }

    func test_localRegressionMetadata_timezoneHeavyCase_detectsRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "CGN", arrAirport: "HKG", depUTC: "2026-03-22T18:00:00Z", arrUTC: "2026-03-22T21:00:00Z")
            ]
        )

        let metadata = localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertFalse(metadata.isEmpty)
    }

    func test_localRegressionMetadata_dateLineStyleCase_detectsRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "NRT", arrAirport: "ANC", depUTC: "2026-03-22T06:00:00Z", arrUTC: "2026-03-22T09:00:00Z")
            ]
        )

        let metadata = localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertFalse(metadata.isEmpty)
    }

    func test_localRegressionMetadata_dstBoundaryDoesNotBreakUTCOrdering() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-08T06:30:00Z", arrUTC: "2026-03-08T09:30:00Z")
            ]
        )

        XCTAssertTrue(localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-08T00:00:00Z")!)).isEmpty)
        XCTAssertLessThan(trip.startUTC, trip.endUTC)
    }
}

final class CalendarSegmentationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_buildSegments_oneDayTrip() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T18:00:00Z", arrUTC: "2026-03-22T23:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments[0].startFraction, segments[0].endFraction)
    }

    func test_buildSegments_overnightTrip() {
        // Calendar days are UTC-indexed. A flight crosses a calendar day boundary when it
        // spans a UTC midnight. dep at 23:00Z = UTC day 0, arr at 06:00Z next UTC day = UTC day 1.
        // SDF = EDT (UTC-4): dep = 19:00 local, arr = 02:00 local next day.
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-22T23:00:00Z", arrUTC: "2026-03-23T06:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].endFraction, 1, accuracy: 0.000001)
        XCTAssertEqual(segments[1].startFraction, 0, accuracy: 0.000001)
    }

    func test_buildSegments_multiDayTrip() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T18:00:00Z", arrUTC: "2026-03-24T12:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].startFraction, 0, accuracy: 0.000001)
        XCTAssertEqual(segments[1].endFraction, 1, accuracy: 0.000001)
    }

    func test_buildSegments_weekCrossingTrip() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-28T18:00:00Z", arrUTC: "2026-03-30T12:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.map(\.weekIndex), [0, 1, 1])
    }

    func test_buildSegments_tinySegmentNearMidnight() {
        // A 2-minute flight spanning a UTC midnight (23:59Z → 00:01Z) crosses a calendar day
        // boundary, producing two tiny segments even though the local duration is negligible.
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-22T23:59:00Z", arrUTC: "2026-03-23T00:01:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 2)
    }

    func test_buildSegments_singleSegmentRegression_becomesFullWidth() throws {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "NRT", arrAirport: "ANC", depUTC: "2026-03-22T06:00:00Z", arrUTC: "2026-03-22T09:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment.startFraction, 0, accuracy: 0.000001)
        XCTAssertEqual(segment.endFraction, 1, accuracy: 0.000001)
        XCTAssertTrue(segment.hasLocalTimeRegression)
        XCTAssertNotNil(segment.regressedRange)
    }

    // MARK: - Carry-in / carry-out across BP boundaries

    /// A trip whose departure is in the previous BP but whose arrival lands inside
    /// the displayed BP must produce a partial bar starting at the left edge of the
    /// first visible day, not be dropped entirely.
    func test_buildSegments_tripCarriesInFromPreviousBP() {
        // Displayed BP starts March 22 UTC; trip departed March 20 (2 days earlier)
        // and arrives March 23 12:00 UTC (well inside the displayed BP).
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-20T18:00:00Z", arrUTC: "2026-03-23T12:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertFalse(segments.isEmpty, "Carry-in trip must produce at least one segment")
        let first = segments.min { $0.dayIndex < $1.dayIndex }
        XCTAssertEqual(first?.dayIndex, 0)
        XCTAssertEqual(first?.startFraction ?? -1, 0, accuracy: 0.000001,
                       "First visible day for a carry-in trip starts at the cell's left edge")
    }

    /// A trip that starts inside the displayed BP but whose arrival is in the next
    /// BP must extend its final visible-day segment all the way to the right edge.
    func test_buildSegments_tripCarriesOutIntoNextBP() {
        // Displayed BP is the 28-day grid starting March 22 UTC (day index 0..27).
        // Trip departs April 17 12:00 UTC (day 26) and arrives April 22 (past end).
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-04-17T12:00:00Z", arrUTC: "2026-04-22T12:00:00Z")
            ]
        )

        let days = generateBidPeriodDays(
            startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!,
            payPeriodCount: 1
        )
        let segments = buildSegments(trip: trip, days: days)
        XCTAssertFalse(segments.isEmpty, "Carry-out trip must produce at least one segment")
        let last = segments.max { $0.dayIndex < $1.dayIndex }
        XCTAssertNotNil(last)
        // BP has 28 days (indices 0..27); trip extends past day 27 so the final
        // visible segment must reach the right edge.
        XCTAssertEqual(last?.dayIndex, 27)
        XCTAssertEqual(last?.endFraction ?? -1, 1, accuracy: 0.000001,
                       "Last visible day for a carry-out trip ends at the cell's right edge")
    }
}

final class CalendarLaneAllocationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_assignLanes_separatesOverlappingSegments() {
        let segments = assignLanes(to: [
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.5),
            segment(tripID: "B", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T02:00:00Z", startFraction: 0.2, endFraction: 0.6)
        ])

        XCTAssertNotEqual(segments[0].lane, segments[1].lane)
    }

    func test_assignLanes_handlesIdenticalStartTimesDeterministically() {
        let source = [
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.4),
            segment(tripID: "B", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.3)
        ]

        XCTAssertEqual(assignLanes(to: source), assignLanes(to: source))
    }

    func test_assignLanes_sameTripPrefersSameLane() {
        let segments = assignLanes(to: [
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.2),
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T03:00:00Z", startFraction: 0.3, endFraction: 0.4)
        ])

        XCTAssertEqual(segments[0].lane, segments[1].lane)
    }

    func test_assignLanes_isDeterministicAcrossRepeatedRuns() {
        let source = [
            segment(tripID: "B", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T02:00:00Z", startFraction: 0.2, endFraction: 0.4),
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.8, endFraction: 0.9),
            segment(tripID: "C", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T03:00:00Z", startFraction: 0.1, endFraction: 0.5)
        ]

        XCTAssertEqual(assignLanes(to: source), assignLanes(to: source))
    }

    func test_assignLanes_sortsBySegmentStartUTC_notStartFraction() {
        let assigned = assignLanes(to: [
            segment(tripID: "LateUTC", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T03:00:00Z", startFraction: 0.1, endFraction: 0.2),
            segment(tripID: "EarlyUTC", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.9, endFraction: 1.0)
        ])

        XCTAssertEqual(assigned.first?.tripID, "EarlyUTC")
    }
}

final class CalendarGeometryTests: XCTestCase {
    func test_frameForSegment_mapsHorizontalBoundsCorrectly() {
        let rect = frameForSegment(
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.25, endFraction: 0.75),
            dayFrame: CGRect(x: 10, y: 20, width: 200, height: 40),
            laneHeight: 12,
            laneSpacing: 4
        )

        XCTAssertEqual(rect.minX, 60, accuracy: 0.000001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.000001)
    }

    func test_frameForSegment_usesLaneSpacingInVerticalPosition() {
        let rect = frameForSegment(
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0, endFraction: 1, lane: 2),
            dayFrame: CGRect(x: 0, y: 20, width: 100, height: 40),
            laneHeight: 10,
            laneSpacing: 3
        )

        XCTAssertEqual(rect.minY, 46, accuracy: 0.000001)
    }
}

private func schedule(
    id: String,
    label: String,
    legs: [TripLeg],
    openTimeTrips: [OpenTimeTrip] = []
) -> PayPeriodSchedule {
    PayPeriodSchedule(
        id: id,
        label: label,
        tripCount: legs.isEmpty ? 0 : 1,
        legCount: legs.count,
        openTimeCount: openTimeTrips.count,
        updatedAt: Date(timeIntervalSince1970: 0),
        legs: legs,
        openTimeTrips: openTimeTrips
    )
}

private func leg(
    payPeriod: String,
    pairing: String,
    flight: String,
    depAirport: String,
    arrAirport: String,
    depUTC: String?,
    arrUTC: String?,
    legNumber: Int = 1
) -> TripLeg {
    TripLeg(
        payPeriod: payPeriod,
        pairing: pairing,
        leg: legNumber,
        flight: flight,
        depAirport: depAirport,
        depLocal: "",
        arrAirport: arrAirport,
        arrLocal: "",
        depUTC: depUTC,
        arrUTC: arrUTC,
        status: "-",
        block: ""
    )
}

private func openTimeTrip(payPeriod: String, pairing: String) -> OpenTimeTrip {
    OpenTimeTrip(
        payPeriod: payPeriod,
        pairing: pairing,
        startLocal: "",
        endLocal: "",
        route: "",
        credit: "",
        requestType: "",
        status: ""
    )
}

private func openTimeTrip(
    payPeriod: String,
    pairing: String,
    startLocal: String,
    depUTC: String
) -> OpenTimeTrip {
    OpenTimeTrip(
        payPeriod: payPeriod,
        pairing: pairing,
        startLocal: startLocal,
        endLocal: startLocal,
        route: "SDF-ANC",
        credit: "",
        requestType: "",
        status: "",
        legs: [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "5X1",
                depAirport: "SDF",
                depLocal: startLocal,
                arrAirport: "ANC",
                arrLocal: startLocal,
                depUTC: depUTC,
                arrUTC: depUTC,
                status: "-",
                block: ""
            )
        ]
    )
}

private func makeBidPeriod(startUTC: String) -> CalendarBidPeriod {
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: startUTC)!
    let days = generateBidPeriodDays(startUTC: start)
    return CalendarBidPeriod(
        id: "BP",
        startDateUTC: start,
        endDateUTC: days.last!.dayEndUTC,
        days: days
    )
}

private func calendarTrip(
    id: String,
    pairing: String,
    payPeriod: String,
    legs: [TripLeg],
    startUTC: String,
    endUTC: String
) -> CalendarTrip {
    let formatter = ISO8601DateFormatter()
    return CalendarTrip(
        id: id,
        pairing: pairing,
        payPeriod: payPeriod,
        legs: legs,
        startUTC: formatter.date(from: startUTC)!,
        endUTC: formatter.date(from: endUTC)!
    )
}

private func makeTrip(payPeriod: String, pairing: String, legs: [TripLeg]) -> CalendarTrip {
    let startUTC = legs.compactMap { LegConnectionTextBuilder.parseUTC($0.depUTC) }.min()!
    let endUTC = legs.compactMap { LegConnectionTextBuilder.parseUTC($0.arrUTC) }.max()!
    return CalendarTrip(
        id: "\(payPeriod)|\(pairing)",
        pairing: pairing,
        payPeriod: payPeriod,
        legs: legs,
        startUTC: startUTC,
        endUTC: endUTC
    )
}

private func segment(
    tripID: String,
    dayIndex: Int,
    weekIndex: Int,
    startUTC: String,
    startFraction: Double,
    endFraction: Double,
    lane: Int = 0
) -> CalendarSegment {
    let formatter = ISO8601DateFormatter()
    return CalendarSegment(
        tripID: tripID,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        segmentStartUTC: formatter.date(from: startUTC)!,
        startFraction: startFraction,
        endFraction: endFraction,
        lane: lane,
        hasLocalTimeRegression: false,
        regressedRange: nil
    )
}
