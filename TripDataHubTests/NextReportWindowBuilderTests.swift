import XCTest
@testable import TripDataHub

/// Covers the pure window-computation logic behind next-report notifications.
/// This area regressed before ("stale next report notifications") with no test
/// coverage; the builder decides which trips notify and at what report time.
final class NextReportWindowBuilderTests: XCTestCase {

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
