import XCTest
@testable import TripDataHub

/// Timeline row colouring contract (INV-012).
///
/// White = Original Scheduled, Amber = Revised Scheduled while still active or future,
/// Gray = completed or past.
///
/// The previous implementation evaluated "has a revision" before "is finished", so a leg that was
/// delayed once and has since been flown stayed amber forever. It also treated a leg with only an
/// ATD as finished, greying out a flight the pilot was still on. Both are pinned here as a table,
/// because the earlier tests only ever passed `legacyIsPast: false` and could not see either bug.
final class TimelineFlightVisualStateTests: XCTestCase {

    func test_visualStateMatrix() {
        let cases: [(name: String, leg: TripLeg, isPast: Bool, expected: TimelineFlightVisualState)] = [
            (
                "original schedule, still in the future",
                leg(std: "2026-08-05T23:34:00Z", original: "2026-08-05T23:34:00Z"),
                false,
                .originalScheduled
            ),
            (
                "revised schedule, still in the future",
                leg(std: "2026-08-06T01:00:00Z", original: "2026-08-05T23:34:00Z"),
                false,
                .revisedScheduled
            ),
            (
                "original schedule, now past, no actuals ever observed",
                leg(std: "2026-08-05T23:34:00Z", original: "2026-08-05T23:34:00Z"),
                true,
                .actual
            ),
            (
                "revised schedule, now past, no actuals ever observed",
                leg(std: "2026-08-06T01:00:00Z", original: "2026-08-05T23:34:00Z"),
                true,
                .actual
            ),
            (
                "completed with both ATD and ATA",
                leg(
                    std: "2026-08-05T23:34:00Z",
                    original: "2026-08-05T23:34:00Z",
                    atd: "2026-08-05T23:45:00Z",
                    ata: "2026-08-06T04:43:00Z"
                ),
                false,
                .actual
            ),
            (
                "revised and completed — completion outranks the revision",
                leg(
                    std: "2026-08-06T01:00:00Z",
                    original: "2026-08-05T23:34:00Z",
                    atd: "2026-08-06T01:10:00Z",
                    ata: "2026-08-06T06:00:00Z"
                ),
                false,
                .actual
            ),
            (
                "ATD only — airborne, not finished, keeps its scheduled colour",
                leg(
                    std: "2026-08-05T23:34:00Z",
                    original: "2026-08-05T23:34:00Z",
                    atd: "2026-08-05T23:45:00Z"
                ),
                false,
                .originalScheduled
            ),
            (
                "ATD only on a revised leg — airborne, still amber",
                leg(
                    std: "2026-08-06T01:00:00Z",
                    original: "2026-08-05T23:34:00Z",
                    atd: "2026-08-06T01:10:00Z"
                ),
                false,
                .revisedScheduled
            ),
            (
                "unknown original (legacy or actual-only source) is not a revision",
                leg(std: "2026-08-05T23:34:00Z", original: nil),
                false,
                .originalScheduled
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                TimelineFlightVisualState.resolve(for: testCase.leg, legacyIsPast: testCase.isPast),
                testCase.expected,
                testCase.name
            )
        }
    }

    /// A completed leg must be gray even when the clock says it is not yet past — for example a
    /// post-flight import confirmed while the scheduled arrival is still in the future.
    func test_completedLegIsGrayEvenWhenNotYetPastByClock() {
        let flown = leg(
            std: "2026-08-05T23:34:00Z",
            original: "2026-08-05T23:20:00Z",
            atd: "2026-08-05T23:45:00Z",
            ata: "2026-08-06T04:43:00Z"
        )
        XCTAssertTrue(flown.hasRevisedSchedule, "precondition: this leg was revised")
        XCTAssertEqual(TimelineFlightVisualState.resolve(for: flown, legacyIsPast: false), .actual)
    }

    private func leg(
        std: String?,
        original: String?,
        atd: String? = nil,
        ata: String? = nil
    ) -> TripLeg {
        TripLeg(
            payPeriod: "CA26-08-A70393R",
            pairing: "A70393R",
            leg: 1,
            flight: "5X059",
            depAirport: "ANC",
            depLocal: "2026-08-05 15:34",
            arrAirport: "ONT",
            arrLocal: "2026-08-05 21:36",
            depUTC: atd ?? std,
            arrUTC: ata ?? "2026-08-06T04:36:00Z",
            status: "-",
            block: "04:58",
            stdUTC: std,
            staUTC: "2026-08-06T04:36:00Z",
            atdUTC: atd,
            ataUTC: ata,
            originalSTDUTC: original,
            originalSTAUTC: "2026-08-06T04:36:00Z"
        )
    }
}
