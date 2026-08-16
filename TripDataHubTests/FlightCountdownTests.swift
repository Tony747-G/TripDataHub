import SwiftUI
import UIKit
import XCTest
@testable import TripDataHub

private enum FlightCountdownFixture {
    static let isoFormatter = ISO8601DateFormatter()
    static let departure = date("2026-07-01T12:00:00Z")
    static let arrival = date("2026-07-01T20:00:00Z")

    static func date(_ value: String) -> Date {
        isoFormatter.date(from: value)!
    }

    static func leg(
        id: String = "L1",
        departure: Date = departure,
        arrival: Date = arrival,
        atd: Date? = nil,
        ata: Date? = nil,
        report: Date? = nil,
        isDeadhead: Bool = false,
        departureAirport: String = "ANC",
        arrivalAirport: String = "NRT",
        departureTimeZoneID: String = "America/Anchorage",
        arrivalTimeZoneID: String = "Asia/Tokyo"
    ) -> FlightCountdownLeg {
        FlightCountdownLeg(
            id: id,
            flightNumber: "5X76",
            isDeadhead: isDeadhead,
            departureAirportIATA: departureAirport,
            arrivalAirportIATA: arrivalAirport,
            plannedDepartureUTC: departure,
            plannedArrivalUTC: arrival,
            atdUTC: atd,
            ataUTC: ata,
            reportTimeUTC: report,
            departureTimeZoneID: departureTimeZoneID,
            arrivalTimeZoneID: arrivalTimeZoneID
        )
    }

    static func state(
        now: Date,
        atd: Date? = nil,
        ata: Date? = nil,
        report: Date? = nil
    ) -> FlightOperationalState {
        FlightOperationalState.evaluate(
            plannedDepartureUTC: departure,
            plannedArrivalUTC: arrival,
            atdUTC: atd,
            ataUTC: ata,
            reportTimeUTC: report,
            nowUTC: now
        )
    }
}

final class Phase4LayoutTests: XCTestCase {
    @MainActor
    func test_T14_narrowRouteAndConnectionViewsKeepFixedLineCounts() throws {
        let routeText = FlightCountdownRouteLine.text(
            departureAirport: "ANC",
            departureTime: "23:24",
            arrivalAirport: "SGN",
            arrivalTime: "02:45"
        )
        XCTAssertEqual(routeText, "ANC 23:24 → SGN 02:45")
        XCTAssertFalse(routeText.contains("✈"))
        XCTAssertFalse(routeText.contains("\n"))

        let leg = connectionLeg
        let nextLeg = nextConnectionLeg
        let display = LegConnectionTextBuilder.blockAndConnectionDisplay(
            for: leg,
            nextLegByID: [leg.id: nextLeg]
        )
        XCTAssertEqual(display.lines, ["Block: 02:44", "Connection at CGO: 2:31"])
        XCTAssertFalse(display.lines.contains { $0.contains(" / ") || $0.contains("\n") })

        let routeHeights = [240.0, 320.0, 430.0].map { width in
            measuredHeight(
                FlightCountdownRouteLineView(
                    departureAirport: "ANC",
                    departureTime: "23:24",
                    arrivalAirport: "SGN",
                    arrivalTime: "02:45"
                ),
                width: width
            )
        }
        assertEqualHeights(routeHeights)

        let connectionHeights = [160.0, 220.0, 420.0].map { width in
            measuredHeight(
                BlockConnectionDisplayView(
                    display: display,
                    fontScale: 1,
                    foregroundColor: .primary
                ),
                width: width
            )
        }
        assertEqualHeights(connectionHeights)
    }

    @MainActor
    func test_T15_iPhoneAndIPadUseTheSameTwoLineConnectionComponent() {
        let display = BlockConnectionDisplay(
            blockText: "Block: 02:44",
            connectionText: "Connection at CGO: 2:31"
        )
        let targetContentWidths = [
            "iPhone": 160.0,
            "iPhone Pro Max": 220.0,
            "iPad": 420.0
        ]
        let heights = targetContentWidths.mapValues { width in
            measuredHeight(
                BlockConnectionDisplayView(
                    display: display,
                    fontScale: 1,
                    foregroundColor: .primary
                ),
                width: width
            )
        }

        XCTAssertEqual(display.lines.count, 2)
        assertEqualHeights(Array(heights.values))
    }

    @MainActor
    private func measuredHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let controller = UIHostingController(rootView: view)
        return controller.sizeThatFits(
            in: CGSize(width: width, height: 1_000)
        ).height
    }

    private func assertEqualHeights(
        _ heights: [CGFloat],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expected = heights.first else {
            return XCTFail("Expected at least one rendered height", file: file, line: line)
        }
        for height in heights.dropFirst() {
            XCTAssertEqual(height, expected, accuracy: 0.5, file: file, line: line)
        }
    }

    private var connectionLeg: TripLeg {
        TripLeg(
            payPeriod: "PP26-08",
            pairing: "T14001",
            leg: 1,
            flight: "5X61",
            depAirport: "ICN",
            depLocal: "07:16",
            arrAirport: "CGO",
            arrLocal: "10:00",
            depUTC: "2026-08-20T07:16:00Z",
            arrUTC: "2026-08-20T10:00:00Z",
            status: "-",
            block: "02:44"
        )
    }

    private var nextConnectionLeg: TripLeg {
        TripLeg(
            payPeriod: "PP26-08",
            pairing: "T14001",
            leg: 2,
            flight: "5X62",
            depAirport: "CGO",
            depLocal: "12:31",
            arrAirport: "ICN",
            arrLocal: "15:00",
            depUTC: "2026-08-20T12:31:00Z",
            arrUTC: "2026-08-20T15:00:00Z",
            status: "-",
            block: "02:29"
        )
    }
}

// Replaces the legacy STD-relative `.liveDelayed` / `.finished` phase tests. ADR-004 records
// their removal as an intentional specification change, not a loss of regression coverage.
final class FlightOperationalStateTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_stateHasExactlySevenCasesAndNoPresentationWindowInput() {
        XCTAssertEqual(FlightOperationalState.allCases.count, 7)
        let evaluator: (Date, Date, Date?, Date?, Date?, Date) -> FlightOperationalState = {
            FlightOperationalState.evaluate(
                plannedDepartureUTC: $0,
                plannedArrivalUTC: $1,
                atdUTC: $2,
                ataUTC: $3,
                reportTimeUTC: $4,
                nowUTC: $5
            )
        }
        XCTAssertEqual(evaluator(F.departure, F.arrival, nil, nil, nil, F.departure), .scheduledDeparturePassed)
    }

    func test_T23_stateExistsOutsidePresentationWindowAndDoesNotChangeWithVisibility() {
        let now = F.departure.addingTimeInterval(-30 * 60 * 60)
        let report = F.departure.addingTimeInterval(-90 * 60)
        let leg = F.leg(report: report)

        let stateBeforePolicy = FlightCountdownEngine.state(for: leg, nowUTC: now)
        let visibility = FlightPresentationPolicy.visibility(
            for: stateBeforePolicy,
            plannedDepartureUTC: leg.plannedDepartureUTC,
            nowUTC: now
        )
        let stateAfterPolicy = FlightCountdownEngine.state(for: leg, nowUTC: now)

        XCTAssertEqual(stateBeforePolicy, .preReport)
        XCTAssertEqual(visibility, .hidden)
        XCTAssertEqual(stateAfterPolicy, stateBeforePolicy)
    }

    func test_T17_ATDAbsentNeverBecomesInFlightBeforeSTA() {
        let checkpoints: [Date] = [
            F.departure,
            F.departure.addingTimeInterval(60),
            F.departure.addingTimeInterval(4 * 60 * 60),
            F.arrival.addingTimeInterval(-1)
        ]
        for now in checkpoints {
            XCTAssertEqual(F.state(now: now), .scheduledDeparturePassed)
        }
        XCTAssertEqual(
            F.state(now: F.departure.addingTimeInterval(-60), report: nil),
            .postReportPreDeparture
        )
    }

    func test_T20_ATDKnownATAUnknownFollowsCompleteTransitionSequence() throws {
        let atd = F.departure.addingTimeInterval(10 * 60)
        let checkpoints: [(TimeInterval, FlightOperationalState, String?)] = [
            (-60 * 60, .inFlight, "Arriving in 1hr 00min"),
            (-60, .inFlight, "Arriving in 0hr 01min"),
            (0, .scheduledArrivalPassed, "Scheduled Arrival Time Passed 0hr 00min"),
            (12 * 60, .scheduledArrivalPassed, "Scheduled Arrival Time Passed 0hr 12min"),
            (59 * 60, .scheduledArrivalPassed, "Scheduled Arrival Time Passed 0hr 59min"),
            (60 * 60, .stale, nil),
            (3 * 60 * 60, .stale, nil)
        ]

        for (offset, expectedState, expectedStatus) in checkpoints {
            let now = F.arrival.addingTimeInterval(offset)
            let leg = F.leg(atd: atd)
            let state = FlightCountdownEngine.state(for: leg, nowUTC: now)
            XCTAssertEqual(state, expectedState, "offset=\(offset)")
            XCTAssertEqual(
                FlightCountdownEngine.statusText(for: leg, state: state, nowUTC: now),
                expectedStatus,
                "offset=\(offset)"
            )
            XCTAssertNotEqual(state, .completed)
            XCTAssertFalse(expectedStatus?.contains("Delayed") ?? false)
        }
    }

    func test_T21_STABoundariesOverrideATDKnownInFlightBranch() {
        let atd = F.departure.addingTimeInterval(10 * 60)
        XCTAssertEqual(F.state(now: F.arrival, atd: atd), .scheduledArrivalPassed)
        XCTAssertEqual(F.state(now: F.arrival.addingTimeInterval(60 * 60), atd: atd), .stale)
    }

    func test_ATAIsTheOnlyCompletionEvidenceAndHasHighestPriority() {
        let ata = F.arrival.addingTimeInterval(5 * 60)
        XCTAssertEqual(F.state(now: F.departure, ata: ata), .completed)
        XCTAssertNotEqual(F.state(now: F.arrival.addingTimeInterval(8 * 60 * 60)), .completed)
    }
}

final class FlightCountdownPresentationTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_T1_durationIsAbsoluteTargetMinusNow() {
        let now = F.departure.addingTimeInterval(-(2 * 60 * 60 + 11 * 60))
        let leg = F.leg()
        let state = FlightCountdownEngine.state(for: leg, nowUTC: now)

        XCTAssertEqual(F.departure.timeIntervalSince(now), 2 * 60 * 60 + 11 * 60)
        XCTAssertEqual(
            FlightCountdownEngine.statusText(for: leg, state: state, nowUTC: now),
            "Dep in 2hr 11min"
        )
    }

    func test_T2_deviceTimezoneChangesDoNotAlterStateOrDuration() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let now = F.departure.addingTimeInterval(-45 * 60)
        let leg = F.leg()
        var observations: [(FlightOperationalState, String?)] = []

        for identifier in ["America/Anchorage", "Asia/Ho_Chi_Minh", "Asia/Tokyo", "Asia/Seoul"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            let state = FlightCountdownEngine.state(for: leg, nowUTC: now)
            observations.append((state, FlightCountdownEngine.statusText(for: leg, state: state, nowUTC: now)))
        }

        XCTAssertTrue(observations.allSatisfy { $0.0 == .postReportPreDeparture })
        XCTAssertTrue(observations.allSatisfy { $0.1 == "Dep in 0hr 45min" })
    }

    func test_T9_operatingAndDeadheadUseIdenticalStateAndDuration() {
        let now = F.departure.addingTimeInterval(-30 * 60)
        let operating = F.leg(isDeadhead: false)
        let deadhead = F.leg(id: "DH", isDeadhead: true)
        let operatingState = FlightCountdownEngine.state(for: operating, nowUTC: now)
        let deadheadState = FlightCountdownEngine.state(for: deadhead, nowUTC: now)

        XCTAssertEqual(operatingState, deadheadState)
        XCTAssertEqual(
            FlightCountdownEngine.statusText(for: operating, state: operatingState, nowUTC: now),
            FlightCountdownEngine.statusText(for: deadhead, state: deadheadState, nowUTC: now)
        )
    }

    func test_T10_STDPassedWithoutATDNeverProducesDelayed() throws {
        let now = F.departure.addingTimeInterval(2 * 60 * 60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now,
            referenceTimeDisplay: .lcl
        ))
        XCTAssertEqual(output.state, .scheduledDeparturePassed)
        XCTAssertEqual(output.display.statusText, "Scheduled Departure Time Passed")
        XCTAssertFalse(output.display.statusText.contains("Delayed"))
    }

    func test_T11_STAPassedWithoutATAUsesNeutralTwoLineDisplayWithOrWithoutATD() throws {
        let now = F.arrival.addingTimeInterval(12 * 60)
        for atd in [nil, F.departure.addingTimeInterval(10 * 60)] {
            let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
                from: [F.leg(atd: atd)],
                nowUTC: now,
                referenceTimeDisplay: .lcl
            ))
            XCTAssertEqual(output.state, .scheduledArrivalPassed)
            XCTAssertEqual(output.display.statusText, "Scheduled Arrival Time Passed 0hr 12min")
            XCTAssertEqual(output.display.referenceText, "Scheduled Arrival: 05:00 LCL")
            XCTAssertFalse(output.display.statusText.contains("Completed"))
        }
    }

    func test_T12_STAPlusOneHourIsStaleAndProducesNoPayloadWithOrWithoutATD() {
        let now = F.arrival.addingTimeInterval(60 * 60)
        for atd in [nil, F.departure.addingTimeInterval(10 * 60)] {
            let leg = F.leg(atd: atd)
            XCTAssertEqual(FlightCountdownEngine.state(for: leg, nowUTC: now), .stale)
            XCTAssertNil(FlightCountdownEngine.buildCountdownOutput(
                from: [leg],
                nowUTC: now,
                referenceTimeDisplay: .lcl
            ))
        }
    }

    func test_T16_LCLUTCModeChangesOnlyReferenceTimestamp() throws {
        let now = F.arrival.addingTimeInterval(12 * 60)
        let leg = F.leg()
        let local = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [leg], nowUTC: now, referenceTimeDisplay: .lcl
        ))
        let utc = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [leg], nowUTC: now, referenceTimeDisplay: .utc
        ))

        XCTAssertEqual(local.display.statusText, utc.display.statusText)
        XCTAssertEqual(local.display.referenceText, "Scheduled Arrival: 05:00 LCL")
        XCTAssertEqual(utc.display.referenceText, "Scheduled Arrival: 20:00 UTC")
    }

    func test_T3_ICNToANCUsesExplicitAirportTimezonesAcrossDateLine() throws {
        let departure = F.date("2026-07-01T16:00:00Z")
        let arrival = F.date("2026-07-02T02:00:00Z")
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg(
                departure: departure,
                arrival: arrival,
                departureAirport: "ICN",
                arrivalAirport: "ANC",
                departureTimeZoneID: "Asia/Seoul",
                arrivalTimeZoneID: "America/Anchorage"
            )],
            nowUTC: departure.addingTimeInterval(-9 * 60 * 60),
            referenceTimeDisplay: .lcl
        ))
        XCTAssertEqual(output.display.departureDateText, "Jul 2")
        XCTAssertEqual(output.display.departureTimeText, "01:00")
        XCTAssertEqual(output.display.arrivalDateText, "Jul 1")
        XCTAssertEqual(output.display.arrivalTimeText, "18:00")
    }
}

final class FlightCountdownCoordinatorLifecycleTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_T18_sameLegStateTransitionsOnlyUpdateExistingActivity() async throws {
        let activityClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "activity-L1", legID: "L1")]
        )
        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: snapshotClient
        )
        let report = F.departure.addingTimeInterval(-90 * 60)
        let leg = F.leg(report: report)
        let checkpoints = [
            F.departure.addingTimeInterval(-2 * 60 * 60),
            F.departure.addingTimeInterval(-60 * 60),
            F.departure
        ]

        for now in checkpoints {
            let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
                from: [leg],
                nowUTC: now,
                referenceTimeDisplay: .lcl
            ))
            await coordinator.refresh(output: output, mode: .reconcile, nowUTC: now)
        }

        let counts = await activityClient.counts()
        XCTAssertEqual(counts.update, 3)
        XCTAssertEqual(counts.end, 0)
        XCTAssertEqual(counts.request, 0)
        let updatedStates = await activityClient.updatedStates()
        XCTAssertEqual(
            updatedStates,
            [.preReport, .postReportPreDeparture, .scheduledDeparturePassed]
        )
    }

    func test_T19_legChangeEndsAndCreatesButReplacementAlwaysRebuilds() async throws {
        let now = F.departure.addingTimeInterval(-30 * 60)
        let nextLeg = F.leg(id: "L2")
        let nextOutput = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [nextLeg],
            nowUTC: now,
            referenceTimeDisplay: .lcl
        ))
        let reconcileClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "old", legID: "L1")]
        )
        let reconcileCoordinator = FlightCountdownCoordinator(
            activityClient: reconcileClient,
            snapshotClient: FlightCountdownSnapshotSpy()
        )

        await reconcileCoordinator.refresh(output: nextOutput, mode: .reconcile, nowUTC: now)

        let reconcileCounts = await reconcileClient.counts()
        XCTAssertEqual(reconcileCounts.end, 1)
        XCTAssertEqual(reconcileCounts.request, 1)
        XCTAssertEqual(reconcileCounts.update, 0)

        let sameLegOutput = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg(id: "L1")],
            nowUTC: now,
            referenceTimeDisplay: .lcl
        ))
        let rebuildClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "same", legID: "L1")]
        )
        let rebuildCoordinator = FlightCountdownCoordinator(
            activityClient: rebuildClient,
            snapshotClient: FlightCountdownSnapshotSpy()
        )

        await rebuildCoordinator.refresh(
            output: sameLegOutput,
            mode: .destructiveRebuild,
            nowUTC: now
        )

        let rebuildCounts = await rebuildClient.counts()
        XCTAssertEqual(rebuildCounts.end, 1)
        XCTAssertEqual(rebuildCounts.request, 1)
        XCTAssertEqual(rebuildCounts.update, 0)
    }

    func test_initialPopulationBarrierBlocksConcurrentRefreshAndRunsOnlyOnce() async throws {
        let populationGate = FlightCountdownPopulationGate()
        let activityClient = FlightCountdownActivitySpy(
            activities: [],
            populationGate: populationGate
        )
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: FlightCountdownSnapshotSpy()
        )
        let now = F.departure.addingTimeInterval(-30 * 60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now,
            referenceTimeDisplay: .lcl
        ))

        let launchRefresh = Task {
            await coordinator.refresh(output: output, mode: .reconcile, nowUTC: now)
        }
        await populationGate.waitUntilStarted()
        let sceneRefresh = Task {
            await coordinator.refresh(output: output, mode: .reconcile, nowUTC: now)
        }

        await Task.yield()
        let eventsBeforePopulation = await activityClient.events()
        XCTAssertEqual(eventsBeforePopulation, ["wait"])

        await populationGate.release()
        await launchRefresh.value
        await sceneRefresh.value

        let events = await activityClient.events()
        XCTAssertEqual(events.first, "wait")
        XCTAssertEqual(events.filter { $0 == "wait" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "activities" }.count, 2)
    }

    func test_staleStateEndsActivityAndDeletesSnapshot() async throws {
        let activityClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "stale", legID: "L1")]
        )
        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: snapshotClient
        )
        let now = F.arrival.addingTimeInterval(60 * 60)
        let staleOutput = CountdownEngineOutput(
            leg: F.leg(),
            state: .stale,
            visibility: .hidden,
            display: CountdownDisplayStrings(
                departureDateText: "",
                departureTimeText: "",
                arrivalDateText: "",
                arrivalTimeText: "",
                routeText: "ANC → NRT",
                statusText: "",
                referenceText: nil
            )
        )

        await coordinator.refresh(output: staleOutput, mode: .reconcile, nowUTC: now)

        let counts = await activityClient.counts()
        let persistedLegIDs = await snapshotClient.persistedLegIDs()
        XCTAssertEqual(counts.end, 1)
        XCTAssertEqual(persistedLegIDs, [nil])
    }

    @MainActor
    func test_boundarySchedulingUsesReportSTDSTAAndStaleBoundaries() throws {
        let report = F.departure.addingTimeInterval(-90 * 60)
        let leg = F.leg(report: report)
        let preReportNow = report.addingTimeInterval(-60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [leg],
            nowUTC: preReportNow,
            referenceTimeDisplay: .lcl
        ))

        XCTAssertEqual(
            AppViewModel.nextFlightCountdownEvaluationBoundary(for: output, after: preReportNow),
            report
        )
        XCTAssertEqual(
            AppViewModel.nextFlightCountdownEvaluationBoundary(for: output, after: report),
            F.departure
        )
        XCTAssertEqual(
            AppViewModel.nextFlightCountdownEvaluationBoundary(for: output, after: F.departure),
            F.arrival
        )
        XCTAssertEqual(
            AppViewModel.nextFlightCountdownEvaluationBoundary(for: output, after: F.arrival),
            F.arrival.addingTimeInterval(60 * 60)
        )
    }
}

private actor FlightCountdownActivitySpy: FlightCountdownActivityClient {
    private var currentActivities: [FlightCountdownActivityRecord]
    private let populationGate: FlightCountdownPopulationGate?
    private var updateSnapshots: [FlightCountdownSnapshot] = []
    private var endCount = 0
    private var requestCount = 0
    private var eventLog: [String] = []

    init(
        activities: [FlightCountdownActivityRecord],
        populationGate: FlightCountdownPopulationGate? = nil
    ) {
        currentActivities = activities
        self.populationGate = populationGate
    }

    func waitForInitialActivityPopulation() async {
        eventLog.append("wait")
        await populationGate?.wait()
    }

    func activitiesEnabled() async -> Bool { true }

    func activities() async -> [FlightCountdownActivityRecord] {
        eventLog.append("activities")
        return currentActivities
    }

    func update(activityID: String, snapshot: FlightCountdownSnapshot) async {
        updateSnapshots.append(snapshot)
    }

    func request(snapshot: FlightCountdownSnapshot) async throws {
        requestCount += 1
        currentActivities.append(
            FlightCountdownActivityRecord(id: "requested-\(requestCount)", legID: snapshot.legID)
        )
    }

    func end(activityID: String) async {
        endCount += 1
        currentActivities.removeAll { $0.id == activityID }
    }

    func counts() -> (update: Int, end: Int, request: Int) {
        (updateSnapshots.count, endCount, requestCount)
    }

    func updatedStates() -> [FlightOperationalState] {
        updateSnapshots.map(\.state)
    }

    func events() -> [String] { eventLog }
}

private actor FlightCountdownPopulationGate {
    private var isReleased = false
    private var didStart = false
    private var populationContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didStart = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            populationContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        populationContinuation?.resume()
        populationContinuation = nil
    }
}

private actor FlightCountdownSnapshotSpy: FlightCountdownSnapshotClient {
    private var persisted: [FlightCountdownSnapshot?] = []

    func persist(_ snapshot: FlightCountdownSnapshot?) async {
        persisted.append(snapshot)
    }

    func reloadWidgets() async {}

    func persistedLegIDs() -> [String?] {
        persisted.map { $0?.legID }
    }
}

final class FlightCountdownSelectionTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_T6_completedLegIsExcludedAndNextLegIsSelectedAfterRelaunchReconstruction() throws {
        let completed = F.leg(
            id: "completed",
            atd: F.departure.addingTimeInterval(10 * 60),
            ata: F.arrival.addingTimeInterval(5 * 60)
        )
        let nextDeparture = F.arrival.addingTimeInterval(4 * 60 * 60)
        let next = F.leg(
            id: "next",
            departure: nextDeparture,
            arrival: nextDeparture.addingTimeInterval(2 * 60 * 60)
        )
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [completed, next],
            nowUTC: F.arrival.addingTimeInterval(30 * 60),
            referenceTimeDisplay: .lcl
        ))
        XCTAssertEqual(output.leg.id, "next")
        XCTAssertEqual(output.state, .postReportPreDeparture)
    }

    func test_arrivalSideCurrentLegOutranksFutureDepartureLeg() throws {
        let current = F.leg(atd: F.departure.addingTimeInterval(10 * 60))
        let next = F.leg(
            id: "next",
            departure: F.arrival.addingTimeInterval(2 * 60 * 60),
            arrival: F.arrival.addingTimeInterval(4 * 60 * 60)
        )
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [next, current],
            nowUTC: F.arrival.addingTimeInterval(-30 * 60),
            referenceTimeDisplay: .lcl
        ))
        XCTAssertEqual(output.leg.id, current.id)
        XCTAssertEqual(output.state, .inFlight)
    }
}

final class FlightCountdownConversionAndBuilderTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_countdownLegUsesPlanningInsteadOfResolvedDisplayTimes() throws {
        let leg = makeTripLeg(
            sequence: 1,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: "2026-07-01T12:30:00Z",
            displayArrival: "2026-07-01T20:20:00Z",
            plannedDeparture: "2026-07-01T12:00:00Z",
            plannedArrival: "2026-07-01T20:00:00Z",
            atd: "2026-07-01T12:30:00Z"
        )
        let converted = try leg.countdownLegResult().get()
        XCTAssertEqual(converted.plannedDepartureUTC, F.departure)
        XCTAssertEqual(converted.plannedArrivalUTC, F.arrival)
        XCTAssertEqual(converted.atdUTC, F.date("2026-07-01T12:30:00Z"))
    }

    func test_reportTimeAppliesOnlyToFirstDomicileDeparture() throws {
        let first = makeTripLeg(
            sequence: 1,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: "2026-07-01T12:00:00Z",
            displayArrival: "2026-07-01T20:00:00Z",
            plannedDeparture: "2026-07-01T12:00:00Z",
            plannedArrival: "2026-07-01T20:00:00Z"
        )
        let second = makeTripLeg(
            sequence: 2,
            dep: "NRT",
            arr: "ANC",
            displayDeparture: "2026-07-02T12:00:00Z",
            displayArrival: "2026-07-02T20:00:00Z",
            plannedDeparture: "2026-07-02T12:00:00Z",
            plannedArrival: "2026-07-02T20:00:00Z"
        )
        let schedule = makeSchedule(legs: [first, second])

        let preReport = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            domicileTimeZone: TimeZone(identifier: "America/Anchorage")!,
            nowUTC: F.date("2026-07-01T10:00:00Z"),
            referenceTimeDisplay: .lcl
        ))
        XCTAssertEqual(preReport.state, .preReport)
        XCTAssertEqual(preReport.leg.reportTimeUTC, F.date("2026-07-01T10:30:00Z"))

        var completedFirst = first
        completedFirst.atdUTC = "2026-07-01T12:10:00Z"
        completedFirst.ataUTC = "2026-07-01T20:05:00Z"
        let afterFirst = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [completedFirst, second])],
            domicileAirportCode: "ANC",
            domicileTimeZone: TimeZone(identifier: "America/Anchorage")!,
            nowUTC: F.date("2026-07-02T10:00:00Z"),
            referenceTimeDisplay: .lcl
        ))
        XCTAssertEqual(afterFirst.leg.id, second.id.uuidString)
        XCTAssertNil(afterFirst.leg.reportTimeUTC)
        XCTAssertEqual(afterFirst.state, .postReportPreDeparture)
    }

    @MainActor
    func test_T22_inputInsufficientLegIsLoggedAndNextValidLegIsSelected() throws {
        let invalid = makeTripLeg(
            sequence: 1,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: nil,
            displayArrival: "2026-07-01T20:00:00Z",
            plannedDeparture: nil,
            plannedArrival: "2026-07-01T20:00:00Z"
        )
        let valid = makeTripLeg(
            sequence: 2,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: "2026-07-02T12:00:00Z",
            displayArrival: "2026-07-02T20:00:00Z",
            plannedDeparture: "2026-07-02T12:00:00Z",
            plannedArrival: "2026-07-02T20:00:00Z"
        )
        let diagnostics = SyncDiagnosticsLog(directory: nil, capacity: 10)
        let output = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [invalid, valid])],
            domicileAirportCode: "ANC",
            domicileTimeZone: TimeZone(identifier: "America/Anchorage")!,
            nowUTC: F.date("2026-07-02T10:00:00Z"),
            referenceTimeDisplay: .lcl
        ) { exclusion in
            diagnostics.record(
                .flightStateInputExcluded,
                ["leg": SyncDiagnosticsLog.tag(exclusion.legID), "reason": exclusion.reason.rawValue]
            )
        })

        XCTAssertEqual(output.leg.id, valid.id.uuidString)
        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertEqual(diagnostics.entries.first?.code, SyncDiagnosticCode.flightStateInputExcluded.rawValue)
        XCTAssertEqual(diagnostics.entries.first?.fields["reason"], FlightCountdownLegExclusionReason.missingPlannedDeparture.rawValue)
    }

    func test_T3_PDFDateRolloverIsIndependentOfDeviceTimezone() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        var results: [String] = []
        for identifier in ["America/Anchorage", "Asia/Seoul"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            results.append(PDFTripParser.addDays(1, to: "31 Dec 2026"))
        }
        XCTAssertEqual(results, ["01 Jan 2027", "01 Jan 2027"])
    }

    private func makeSchedule(legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "PP26-07",
            label: "PP26-07",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: F.date("2026-06-01T00:00:00Z"),
            legs: legs,
            openTimeTrips: []
        )
    }

    private func makeTripLeg(
        sequence: Int,
        dep: String,
        arr: String,
        displayDeparture: String?,
        displayArrival: String?,
        plannedDeparture: String?,
        plannedArrival: String?,
        atd: String? = nil,
        ata: String? = nil
    ) -> TripLeg {
        TripLeg(
            payPeriod: "PP26-07",
            pairing: "A00001",
            leg: sequence,
            flight: "5X76",
            depAirport: dep,
            depLocal: "00:00",
            arrAirport: arr,
            arrLocal: "00:00",
            depUTC: displayDeparture,
            arrUTC: displayArrival,
            status: "-",
            block: "8:00",
            stdUTC: plannedDeparture,
            staUTC: plannedArrival,
            atdUTC: atd,
            ataUTC: ata
        )
    }
}
