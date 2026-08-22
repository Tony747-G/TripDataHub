import UserNotifications
import XCTest
@testable import TripDataHub

/// Covers the pure window-computation logic behind next-report notifications.
/// This area regressed before ("stale next report notifications") with no test
/// coverage; the builder decides which trips notify and at what report time.
final class NextReportWindowBuilderTests: XCTestCase {

    func test_notificationUsesAbsoluteTimeIntervalWithoutCalendarComponentOverconstraint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fireDate = now.addingTimeInterval(48 * 60 * 60 + 17)

        let trigger = NextReportNotificationService.notificationTrigger(
            fireDate: fireDate,
            now: now
        )

        XCTAssertEqual(trigger.timeInterval, 48 * 60 * 60 + 17)
        XCTAssertFalse(trigger.repeats)
    }

    private static let anchorageTimeZone = TimeZone(identifier: "America/Anchorage")!

    func test_build_reportTimeIsNinetyMinutesBeforeFirstDomicileDeparture() throws {
        let schedule = makeSchedule(legs: [
            makeLeg(
                pairing: "A00001", leg: 1,
                dep: "ANC", arr: "HKG",
                depUTC: "2026-06-14T13:00:00Z", arrUTC: "2026-06-15T05:00:00Z"
            ),
            makeLeg(
                pairing: "A00001", leg: 2,
                dep: "HKG", arr: "ANC",
                depUTC: "2026-06-17T01:00:00Z", arrUTC: "2026-06-17T12:00:00Z"
            )
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(window.pairing, "A00001")
        XCTAssertEqual(window.tripStartDomicile, iso("2026-06-14T13:00:00Z"))
        XCTAssertEqual(window.reportTime, iso("2026-06-14T11:30:00Z"), "Report is 90 minutes before domicile departure")
        XCTAssertEqual(window.tripEndDomicile, iso("2026-06-17T12:00:00Z"))
    }

    func test_T13_reportLeadUsesLower48RuleAndFallsBackToNinetyMinutes() throws {
        let departure = "2026-06-14T13:00:00Z"
        let arrival = "2026-06-14T17:00:00Z"
        let returnDeparture = "2026-06-15T13:00:00Z"
        let returnArrival = "2026-06-15T17:00:00Z"

        func reportTime(domicile: String, destination: String) throws -> Date {
            let schedule = makeSchedule(legs: [
                makeLeg(
                    pairing: "T13001", leg: 1,
                    dep: domicile, arr: destination,
                    depUTC: departure, arrUTC: arrival
                ),
                makeLeg(
                    pairing: "T13001", leg: 2,
                    dep: destination, arr: domicile,
                    depUTC: returnDeparture, arrUTC: returnArrival
                )
            ])
            return try XCTUnwrap(
                NextReportWindowBuilder.build(
                    schedules: [schedule],
                    domicileAirportCode: domicile,
                    domicileTimeZone: Self.anchorageTimeZone
                ).first
            ).reportTime
        }

        XCTAssertEqual(try reportTime(domicile: "SDF", destination: "MIA"), iso("2026-06-14T12:00:00Z"))
        XCTAssertEqual(try reportTime(domicile: "ANC", destination: "SDF"), iso("2026-06-14T11:30:00Z"))
        XCTAssertEqual(try reportTime(domicile: "SDF", destination: "HNL"), iso("2026-06-14T11:30:00Z"))
        XCTAssertEqual(try reportTime(domicile: "SDF", destination: "ZZZ"), iso("2026-06-14T11:30:00Z"))
    }

    func test_T24_reportWindowAndTimelineDutyStartShareOneLeadTimePolicy() throws {
        func observedLeadMinutes(
            origin: String,
            destination: String,
            domicileTimeZone: TimeZone
        ) throws -> (reportWindow: Int, timeline: Int) {
            let departure = iso("2026-06-14T13:00:00Z")
            let outbound = makeLeg(
                pairing: "T24001", leg: 1,
                dep: origin, arr: destination,
                depUTC: "2026-06-14T13:00:00Z", arrUTC: "2026-06-14T17:00:00Z"
            )
            let inbound = makeLeg(
                pairing: "T24001", leg: 2,
                dep: destination, arr: origin,
                depUTC: "2026-06-15T13:00:00Z", arrUTC: "2026-06-15T17:00:00Z"
            )
            let window = try XCTUnwrap(
                NextReportWindowBuilder.build(
                    schedules: [makeSchedule(legs: [outbound, inbound])],
                    domicileAirportCode: origin,
                    domicileTimeZone: domicileTimeZone
                ).first
            )
            let rest = try XCTUnwrap(
                TimelineLayoverSupport.restInfo(
                    arrDate: iso("2026-06-13T00:00:00Z"),
                    nextLeg: outbound
                )
            )
            return (
                Int(departure.timeIntervalSince(window.reportTime) / 60),
                Int(departure.timeIntervalSince(rest.dutyStartUTC) / 60)
            )
        }

        let asia = try observedLeadMinutes(
            origin: "ICN",
            destination: "CGO",
            domicileTimeZone: TimeZone(identifier: "Asia/Seoul")!
        )
        let europe = try observedLeadMinutes(
            origin: "FRA",
            destination: "AMS",
            domicileTimeZone: TimeZone(identifier: "Europe/Berlin")!
        )
        let lower48 = try observedLeadMinutes(
            origin: "SDF",
            destination: "MIA",
            domicileTimeZone: TimeZone(identifier: "America/Kentucky/Louisville")!
        )

        XCTAssertEqual(asia.reportWindow, 90)
        XCTAssertEqual(asia.timeline, asia.reportWindow)
        XCTAssertEqual(europe.reportWindow, 90)
        XCTAssertEqual(europe.timeline, europe.reportWindow)
        XCTAssertEqual(lower48.reportWindow, 60)
        XCTAssertEqual(lower48.timeline, lower48.reportWindow)
    }

    func test_build_skipsTripWithoutDomicileDeparture() {
        let schedule = makeSchedule(legs: [
            makeLeg(
                pairing: "B00001", leg: 1,
                dep: "HKG", arr: "HND",
                depUTC: "2026-06-14T13:00:00Z", arrUTC: "2026-06-14T17:00:00Z"
            )
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        XCTAssertTrue(windows.isEmpty, "Trips that never depart the domicile have no report window")
    }

    func test_build_skipsTripWithoutDomicileReturn() {
        let schedule = makeSchedule(legs: [
            makeLeg(
                pairing: "B00002", leg: 1,
                dep: "ANC", arr: "HKG",
                depUTC: "2026-06-14T13:00:00Z", arrUTC: "2026-06-15T05:00:00Z"
            )
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        XCTAssertTrue(windows.isEmpty, "Open-ended trips (no domicile arrival yet) are skipped")
    }

    func test_build_tripEndUsesLastDomicileArrival() throws {
        // ANC -> SDF -> ANC -> HKG -> ANC: the trip ends at the *final* ANC arrival.
        let schedule = makeSchedule(legs: [
            makeLeg(pairing: "C00001", leg: 1, dep: "ANC", arr: "SDF",
                    depUTC: "2026-06-10T08:00:00Z", arrUTC: "2026-06-10T14:00:00Z"),
            makeLeg(pairing: "C00001", leg: 2, dep: "SDF", arr: "ANC",
                    depUTC: "2026-06-11T08:00:00Z", arrUTC: "2026-06-11T14:00:00Z"),
            makeLeg(pairing: "C00001", leg: 3, dep: "ANC", arr: "HKG",
                    depUTC: "2026-06-12T08:00:00Z", arrUTC: "2026-06-13T01:00:00Z"),
            makeLeg(pairing: "C00001", leg: 4, dep: "HKG", arr: "ANC",
                    depUTC: "2026-06-14T08:00:00Z", arrUTC: "2026-06-14T18:00:00Z")
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.tripEndDomicile, iso("2026-06-14T18:00:00Z"))
        XCTAssertEqual(window.tripStartDomicile, iso("2026-06-10T08:00:00Z"), "Window anchors on the first domicile departure")
    }

    func test_build_picksChronologicallyFirstDomicileDepartureRegardlessOfArrayOrder() throws {
        // Legs arrive out of order (e.g. merged from two imports).
        let schedule = makeSchedule(legs: [
            makeLeg(pairing: "D00001", leg: 2, dep: "SDF", arr: "ANC",
                    depUTC: "2026-06-12T08:00:00Z", arrUTC: "2026-06-12T14:00:00Z"),
            makeLeg(pairing: "D00001", leg: 1, dep: "ANC", arr: "SDF",
                    depUTC: "2026-06-10T08:00:00Z", arrUTC: "2026-06-10T14:00:00Z")
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.tripStartDomicile, iso("2026-06-10T08:00:00Z"))
        XCTAssertEqual(window.reportTime, iso("2026-06-10T06:30:00Z"))
    }

    func test_build_samePairingInDifferentPayPeriodsYieldsSeparateWindows() {
        let june = makeSchedule(payPeriod: "PP26-06", legs: [
            makeLeg(payPeriod: "PP26-06", pairing: "E00001", leg: 1, dep: "ANC", arr: "SDF",
                    depUTC: "2026-06-01T08:00:00Z", arrUTC: "2026-06-01T14:00:00Z"),
            makeLeg(payPeriod: "PP26-06", pairing: "E00001", leg: 2, dep: "SDF", arr: "ANC",
                    depUTC: "2026-06-02T08:00:00Z", arrUTC: "2026-06-02T14:00:00Z")
        ])
        let july = makeSchedule(payPeriod: "PP26-07", legs: [
            makeLeg(payPeriod: "PP26-07", pairing: "E00001", leg: 1, dep: "ANC", arr: "SDF",
                    depUTC: "2026-07-01T08:00:00Z", arrUTC: "2026-07-01T14:00:00Z"),
            makeLeg(payPeriod: "PP26-07", pairing: "E00001", leg: 2, dep: "SDF", arr: "ANC",
                    depUTC: "2026-07-02T08:00:00Z", arrUTC: "2026-07-02T14:00:00Z")
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [june, july],
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        XCTAssertEqual(windows.count, 2, "Same pairing in different pay periods must not collapse into one window")
        XCTAssertEqual(Set(windows.map(\.key)).count, 2, "Window keys must stay unique per pay period")
    }

    func test_build_domicileMatchingIsCaseAndWhitespaceInsensitive() throws {
        let schedule = makeSchedule(legs: [
            makeLeg(pairing: "F00001", leg: 1, dep: "anc", arr: "SDF",
                    depUTC: "2026-06-10T08:00:00Z", arrUTC: "2026-06-10T14:00:00Z"),
            makeLeg(pairing: "F00001", leg: 2, dep: "SDF", arr: "ANC",
                    depUTC: "2026-06-11T08:00:00Z", arrUTC: "2026-06-11T14:00:00Z")
        ])

        let windows = NextReportWindowBuilder.build(
            schedules: [schedule],
            domicileAirportCode: " anc ",
            domicileTimeZone: Self.anchorageTimeZone
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(try XCTUnwrap(windows.first).tripStartDomicile, iso("2026-06-10T08:00:00Z"))
    }

    func test_nextReportCountdown_startsWhen40303ReturnsBeforeA70606() throws {
        let schedules = [
            makeSchedule(legs: [
                makeLeg(pairing: "40303", leg: 1, dep: "ANC", arr: "SDF",
                        depUTC: "2026-07-13T08:06:00Z", arrUTC: "2026-07-13T14:32:00Z"),
                makeLeg(pairing: "40303", leg: 2, dep: "SDF", arr: "ANC",
                        depUTC: "2026-07-14T07:15:00Z", arrUTC: "2026-07-14T13:56:00Z")
            ]),
            makeSchedule(legs: [
                makeLeg(pairing: "A70606", leg: 1, dep: "ANC", arr: "SDF",
                        depUTC: "2026-07-15T07:13:00Z", arrUTC: "2026-07-15T13:26:00Z"),
                makeLeg(pairing: "A70606", leg: 2, dep: "SDF", arr: "ANC",
                        depUTC: "2026-07-18T08:00:00Z", arrUTC: "2026-07-18T14:00:00Z")
            ])
        ]
        let windows = NextReportWindowBuilder.build(
            schedules: schedules,
            domicileAirportCode: "ANC",
            domicileTimeZone: Self.anchorageTimeZone
        )

        XCTAssertNil(
            NextReportWindowBuilder.nextReportWindow(
                from: windows,
                now: iso("2026-07-14T13:55:59Z")
            ),
            "A70606 countdown must stay hidden while DH 5X064 is still en route"
        )
        let next = try XCTUnwrap(
            NextReportWindowBuilder.nextReportWindow(
                from: windows,
                now: iso("2026-07-14T13:56:00Z")
            )
        )
        XCTAssertEqual(next.pairing, "A70606")
        XCTAssertEqual(next.reportTime, iso("2026-07-15T05:43:00Z"))
    }

    // MARK: - Helpers

    private func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func makeLeg(
        payPeriod: String = "PP26-06",
        pairing: String,
        leg: Int,
        dep: String,
        arr: String,
        depUTC: String,
        arrUTC: String
    ) -> TripLeg {
        TripLeg(
            payPeriod: payPeriod,
            pairing: pairing,
            leg: leg,
            flight: "XX\(100 + leg)",
            depAirport: dep,
            depLocal: String(depUTC.prefix(10)) + " 00:00",
            arrAirport: arr,
            arrLocal: String(arrUTC.prefix(10)) + " 00:00",
            depUTC: depUTC,
            arrUTC: arrUTC,
            status: "-",
            block: "6:00"
        )
    }

    private func makeSchedule(payPeriod: String = "PP26-06", legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "\(payPeriod)-test",
            label: payPeriod,
            tripCount: Set(legs.map(\.pairing)).count,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            legs: legs,
            openTimeTrips: []
        )
    }
}
