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
            reportTimeUTC: report,
            departureTimeZoneID: departureTimeZoneID,
            arrivalTimeZoneID: arrivalTimeZoneID
        )
    }

    static func state(
        now: Date,
        report: Date? = nil
    ) -> FlightOperationalState {
        FlightOperationalState.evaluate(
            plannedDepartureUTC: departure,
            reportTimeUTC: report,
            nowUTC: now
        )
    }
}

final class Phase4LayoutTests: XCTestCase {
    @MainActor
    func test_T14_expandedLiveActivityKeepsFourRowsAtAllTargetWidths() throws {
        XCTAssertEqual(FlightCountdownExpandedLayoutContract.rowCount, 4)
        XCTAssertEqual(FlightCountdownExpandedLayoutContract.airplaneSymbolName, "airplane")

        let targetContentWidths = [
            "iPhone": 240.0,
            "iPhone Pro Max": 320.0,
            "iPad": 430.0
        ]
        let renderedHeights = targetContentWidths.mapValues { width in
            measuredHeight(expandedLiveActivityLayout, width: width)
        }
        assertEqualHeights(Array(renderedHeights.values))

        for (deviceName, width) in targetContentWidths.sorted(by: { $0.key < $1.key }) {
            let attachment = XCTAttachment(image: renderedImage(
                expandedLiveActivityLayout,
                width: width
            ))
            attachment.name = "T-14 \(deviceName) width-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func test_liveActivityTimerContractConstants() {
        let targetUTC = Date(timeIntervalSince1970: 1_786_909_800)
        let expirationUTC = targetUTC.addingTimeInterval(FlightOperationalState.expirationInterval)

        XCTAssertEqual(FlightCountdownLiveActivityTimerContract.maxFieldCount, 2)
        XCTAssertEqual(FlightCountdownLiveActivityTimerContract.maxPrecision, .seconds(60))
        XCTAssertEqual(
            FlightCountdownLiveActivityTimerContract.countdownInterval(endingAt: targetUTC).upperBound,
            targetUTC
        )
        XCTAssertEqual(
            FlightCountdownLiveActivityTimerContract.countUpInterval(
                startingAt: targetUTC,
                expirationUTC: expirationUTC
            ),
            targetUTC..<expirationUTC
        )

        // Dates are absolute instants. Presentation timezone changes must not move either timer
        // boundary. WidgetKit rendering remains a separate device acceptance requirement.
        for timeZoneID in ["America/Anchorage", "UTC", "Asia/Tokyo"] {
            XCTAssertNotNil(TimeZone(identifier: timeZoneID))
            XCTAssertEqual(
                FlightCountdownLiveActivityTimerContract.countdownInterval(
                    endingAt: targetUTC
                ).upperBound,
                targetUTC
            )
        }

        let plannedDeparture = Date(timeIntervalSince1970: 0).addingTimeInterval(8 * 60 * 60)
        XCTAssertEqual(
            FlightCountdownActivityLifecyclePolicy.staleDate(plannedDepartureUTC: plannedDeparture),
            plannedDeparture.addingTimeInterval(61 * 60)
        )
    }

    /// T-50S is a syntax guard, not a rendering test. WidgetKit renders Live Activities in a
    /// separate process, so device-only D-7 remains authoritative for pixels and redaction.
    /// This test prevents the Live Activity path from returning to APIs known to redact there.
    func test_T50S_liveActivityUsesSystemTimerSyntaxAndRejectsKnownRedactionPaths() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
            ),
            encoding: .utf8
        )
        let liveActivityStart = try XCTUnwrap(
            source.range(of: "private struct LiveActivityOperationalStatusView")
        ).lowerBound
        let liveActivityEnd = try XCTUnwrap(
            source.range(
                of: "private struct FlightCountdownEntry",
                range: liveActivityStart..<source.endIndex
            )
        ).lowerBound
        let liveActivitySource = String(source[liveActivityStart..<liveActivityEnd])
        let compactSource = liveActivitySource.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )

        for forbiddenSyntax in [
            "Text(timerInterval:",
            ".components(style:",
            ".dateRange(",
            "style:.relative",
            "style:.timer"
        ] {
            XCTAssertFalse(
                compactSource.contains(forbiddenSyntax),
                "Live Activity restored known-redacting syntax: \(forbiddenSyntax)"
            )
        }

        let sharedSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "TripDataHub/Models/FlightCountdownSharedModels.swift"
            ),
            encoding: .utf8
        )
        let compactSharedSource = compactSyntax(sharedSource)
        XCTAssertTrue(compactSharedSource.contains(".timer(countingDownIn:"))
        XCTAssertTrue(compactSharedSource.contains(".timer(countingUpIn:"))
        for forbiddenSyntax in [
            "Text(timerInterval:",
            ".components(style:",
            ".dateRange(",
            "style:.relative",
            "style:.timer"
        ] {
            XCTAssertFalse(compactSharedSource.contains(forbiddenSyntax))
        }
        XCTAssertFalse(compactSharedSource.contains("Arrivingin"))
        XCTAssertFalse(compactSharedSource.contains("ScheduledArrivalTimePassed"))
    }

    func test_T16_operationalSurfacesConsumeTheSharedDescriptorWithoutTimelineReevaluation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surfacePaths = [
            "TripDataHub/Views/TimelineTabView.swift",
            "TripDataHub/Views/iPad/iPadTimelineSidebarView.swift",
            "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
        ]

        for path in surfacePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("OperationalCountdownStatusView"), path)
            XCTAssertFalse(source.contains("NextReportWindowBuilder"), path)
            XCTAssertFalse(source.contains("countdownText("), path)
            XCTAssertFalse(source.contains("(-05d"), path)
        }
    }

    func test_T17_operationalSourcesExcludeRetiredArrivalSemanticsAndSTABoundaries() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let operationalPaths = [
            "TripDataHub/Models/FlightCountdownSupport.swift",
            "TripDataHub/Models/FlightCountdownSharedModels.swift",
            "TripDataHub/Services/OperationalStateBuilder.swift",
            "TripDataHub/Services/FlightCountdownCoordinator.swift",
            "TripDataHub/Views/TimelineTabView.swift",
            "TripDataHub/Views/iPad/iPadTimelineSidebarView.swift",
            "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
        ]
        let retiredTokens = [
            ".inFlight",
            ".scheduledArrivalPassed",
            "Arriving in",
            "Scheduled Arrival Time Passed",
            "STA+1h"
        ]

        for path in operationalPaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            for token in retiredTokens {
                XCTAssertFalse(source.contains(token), "\(path) restored retired token \(token)")
            }
        }

        let appViewModelSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("TripDataHub/ViewModels/AppViewModel.swift"),
            encoding: .utf8
        )
        let boundaryStart = try XCTUnwrap(
            appViewModelSource.range(of: "static func nextFlightCountdownEvaluationBoundary")
        ).lowerBound
        let boundaryEnd = try XCTUnwrap(
            appViewModelSource.range(
                of: "private func scheduleFlightCountdownBoundary",
                range: boundaryStart..<appViewModelSource.endIndex
            )
        ).lowerBound
        let boundarySource = String(appViewModelSource[boundaryStart..<boundaryEnd])
        XCTAssertFalse(boundarySource.contains("plannedArrivalUTC"))
        XCTAssertFalse(boundarySource.contains("STA"))
    }

    /// T-51S guards the source-level foreground/background ownership contract. It does not
    /// inspect rendered pixels; Light/Dark acceptance remains a device verification step.
    func test_T51S_customBackgroundSurfacesDeclareMatchingForegroundEnvironment() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
            ),
            encoding: .utf8
        )

        let widgetViewStart = try XCTUnwrap(
            source.range(of: "private struct FlightCountdownWidgetEntryView")
        ).lowerBound
        let widgetActiveStart = try XCTUnwrap(
            source.range(
                of: "if let snapshot = entry.snapshot",
                range: widgetViewStart..<source.endIndex
            )
        ).lowerBound
        let widgetInactiveStart = try XCTUnwrap(
            source.range(
                of: "} else {",
                range: widgetActiveStart..<source.endIndex
            )
        ).lowerBound
        let widgetActiveSource = compactSyntax(
            String(source[widgetActiveStart..<widgetInactiveStart])
        )

        XCTAssertTrue(widgetActiveSource.contains(".environment(\\.colorScheme,.dark)"))
        XCTAssertTrue(widgetActiveSource.contains(".containerBackground(for:.widget)"))
        XCTAssertTrue(widgetActiveSource.contains("LinearGradient("))

        let activityStart = try XCTUnwrap(
            source.range(of: "struct FlightCountdownLiveActivityWidget")
        ).lowerBound
        let activityEnd = try XCTUnwrap(
            source.range(
                of: "@main",
                range: activityStart..<source.endIndex
            )
        ).lowerBound
        let activitySource = compactSyntax(String(source[activityStart..<activityEnd]))

        XCTAssertTrue(activitySource.contains(".environment(\\.colorScheme,.dark)"))
        XCTAssertTrue(activitySource.contains(".activityBackgroundTint(Color.black)"))
    }

    private func compactSyntax(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
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

    @MainActor
    private func renderedImage<V: View>(_ view: V, width: CGFloat) -> UIImage {
        let controller = UIHostingController(rootView: view)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 1_000))
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .black
        controller.view.overrideUserInterfaceStyle = .dark
        controller.view.layoutIfNeeded()

        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
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

    private var expandedLiveActivityLayout: some View {
        FlightCountdownExpandedLayoutView(
            flightText: "Flight: D901",
            departureDateText: "Aug 16 (Sun)",
            departureAirportTimeText: "ANC 16:13",
            arrivalDateText: "Aug 17 (Mon)",
            arrivalAirportTimeText: "ICN 17:33"
        ) {
            Text("Report in 3hr 15min")
                .foregroundStyle(.green)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

}

// Replaces the legacy STD-relative `.liveDelayed` / `.finished` phase tests. ADR-004 records
// their removal as an intentional specification change, not a loss of regression coverage.
final class FlightOperationalStateTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_T17_stateHasExactlyFourCasesAndEvaluatorHasNoActualArrivalOrWindowInput() {
        XCTAssertEqual(FlightOperationalState.allCases, [.preReport, .preDeparture, .departureTimePassed, .expired])
        let evaluator: (Date, Date?, Date) -> FlightOperationalState = {
            FlightOperationalState.evaluate(
                plannedDepartureUTC: $0,
                reportTimeUTC: $1,
                nowUTC: $2
            )
        }
        XCTAssertEqual(evaluator(F.departure, nil, F.departure), .departureTimePassed)
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

    func test_T20_exactFourStateBoundarySequence() throws {
        let report = F.departure.addingTimeInterval(-90 * 60)
        let checkpoints: [(Date, FlightOperationalState, String?, Date?)] = [
            (report.addingTimeInterval(-60), .preReport, "Report in", report),
            (report, .preDeparture, "Dep in", F.departure),
            (F.departure.addingTimeInterval(-60), .preDeparture, "Dep in", F.departure),
            (F.departure, .departureTimePassed, "Departure time passed", F.departure),
            (F.departure.addingTimeInterval(60), .departureTimePassed, "Departure time passed", F.departure),
            (F.departure.addingTimeInterval(60 * 60), .departureTimePassed, "Departure time passed", F.departure),
            (F.departure.addingTimeInterval(60 * 60 + 59), .departureTimePassed, "Departure time passed", F.departure),
            (F.departure.addingTimeInterval(61 * 60), .expired, nil, nil)
        ]

        for (now, expectedState, expectedPrefix, expectedAnchor) in checkpoints {
            let state = F.state(now: now, report: report)
            XCTAssertEqual(state, expectedState)
            let presentation = OperationalCountdownPresentation.make(
                state: state,
                plannedDepartureUTC: F.departure,
                reportTimeUTC: report
            )
            XCTAssertEqual(presentation?.prefix, expectedPrefix)
            XCTAssertEqual(presentation?.anchorUTC, expectedAnchor)
        }
    }

    func test_T21_evaluationOrderAndElapsedFloorAtSixtyMinuteBoundary() {
        let report = F.departure.addingTimeInterval(-90 * 60)
        XCTAssertEqual(F.state(now: report, report: report), .preDeparture)
        XCTAssertEqual(F.state(now: F.departure, report: report), .departureTimePassed)
        XCTAssertEqual(F.state(now: F.departure.addingTimeInterval(60 * 60 + 59), report: report), .departureTimePassed)
        XCTAssertEqual(F.state(now: F.departure.addingTimeInterval(61 * 60), report: report), .expired)
        XCTAssertEqual(Int(F.departure.addingTimeInterval(60 * 60 + 59).timeIntervalSince(F.departure)) / 60, 60)
    }

    func test_legacyActualAndArrivalStatesDecodeFailClosedToExpired() throws {
        for raw in ["inFlight", "scheduledArrivalPassed", "completed", "stale", "scheduledDeparturePassed"] {
            let data = try JSONEncoder().encode(raw)
            XCTAssertEqual(try JSONDecoder().decode(FlightOperationalState.self, from: data), .expired)
        }
    }
}

final class FlightCountdownPresentationTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_T1_sharedDescriptorUsesAbsoluteTargetAndAnchor() throws {
        let now = F.departure.addingTimeInterval(-(2 * 60 * 60 + 11 * 60))
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now
        ))

        XCTAssertEqual(F.departure.timeIntervalSince(now), 2 * 60 * 60 + 11 * 60)
        XCTAssertEqual(output.presentation.state, .preDeparture)
        XCTAssertEqual(output.presentation.prefix, "Dep in")
        XCTAssertEqual(output.presentation.anchorUTC, F.departure)
        XCTAssertEqual(output.presentation.direction, .countingDown)
    }

    func test_T2_deviceTimezoneChangesDoNotAlterStateOrDuration() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let now = F.departure.addingTimeInterval(-45 * 60)
        let leg = F.leg()
        var observations: [(FlightOperationalState, OperationalCountdownPresentation?)] = []

        for identifier in ["America/Anchorage", "Asia/Ho_Chi_Minh", "Asia/Tokyo", "Asia/Seoul"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            let state = FlightCountdownEngine.state(for: leg, nowUTC: now)
            observations.append((state, OperationalCountdownPresentation.make(
                state: state,
                plannedDepartureUTC: leg.plannedDepartureUTC,
                reportTimeUTC: leg.reportTimeUTC
            )))
        }

        XCTAssertTrue(observations.allSatisfy { $0.0 == .preDeparture })
        XCTAssertTrue(observations.allSatisfy { $0.1?.anchorUTC == F.departure })
    }

    func test_T9_operatingAndDeadheadUseIdenticalStateAndDuration() {
        let now = F.departure.addingTimeInterval(-30 * 60)
        let operating = F.leg(isDeadhead: false)
        let deadhead = F.leg(id: "DH", isDeadhead: true)
        let operatingState = FlightCountdownEngine.state(for: operating, nowUTC: now)
        let deadheadState = FlightCountdownEngine.state(for: deadhead, nowUTC: now)

        XCTAssertEqual(operatingState, deadheadState)
        XCTAssertEqual(
            OperationalCountdownPresentation.make(state: operatingState, plannedDepartureUTC: operating.plannedDepartureUTC, reportTimeUTC: nil),
            OperationalCountdownPresentation.make(state: deadheadState, plannedDepartureUTC: deadhead.plannedDepartureUTC, reportTimeUTC: nil)
        )
    }

    func test_T10_STDPassedProducesOnlyDepartureTimePassedUntilMinuteSixty() throws {
        let now = F.departure.addingTimeInterval(60 * 60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now
        ))
        XCTAssertEqual(output.state, .departureTimePassed)
        XCTAssertEqual(output.presentation.prefix, "Departure time passed")
        XCTAssertEqual(output.presentation.anchorUTC, F.departure)
        XCTAssertEqual(output.presentation.direction, .countingUp)
    }

    func test_T12_STDPlusSixtyOneExpiresAndProducesNoPayload() {
        let now = F.departure.addingTimeInterval(61 * 60)
        let leg = F.leg()
        XCTAssertEqual(FlightCountdownEngine.state(for: leg, nowUTC: now), .expired)
        XCTAssertNil(FlightCountdownEngine.buildCountdownOutput(from: [leg], nowUTC: now))
    }

    func test_T16_outputCarriesOneDescriptorForEverySurface() throws {
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()], nowUTC: F.departure.addingTimeInterval(-30 * 60)
        ))
        let snapshot = FlightCountdownSnapshot(
            updatedAtUTC: F.departure,
            state: output.state,
            visibility: output.visibility,
            legID: output.leg.id,
            flightNumber: output.leg.flightNumber,
            isDeadhead: output.leg.isDeadhead,
            departureAirportIATA: output.leg.departureAirportIATA,
            arrivalAirportIATA: output.leg.arrivalAirportIATA,
            plannedDepartureUTC: output.leg.plannedDepartureUTC,
            plannedArrivalUTC: output.leg.plannedArrivalUTC,
            reportTimeUTC: output.leg.reportTimeUTC,
            presentation: output.presentation,
            departureTimeZoneID: output.leg.departureTimeZoneID,
            arrivalTimeZoneID: output.leg.arrivalTimeZoneID,
            departureDateText: output.display.departureDateText,
            departureTimeText: output.display.departureTimeText,
            arrivalDateText: output.display.arrivalDateText,
            arrivalTimeText: output.display.arrivalTimeText
        )
        XCTAssertEqual(snapshot.presentation, output.presentation)
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
            nowUTC: departure.addingTimeInterval(-9 * 60 * 60)
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
                nowUTC: now
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
            [.preReport, .preDeparture, .departureTimePassed]
        )
    }

    func test_T52_reconcileWithSameLegUpdatesInPlaceWithoutRecreating() async throws {
        let activityClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "same", legID: "L1")]
        )
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: FlightCountdownSnapshotSpy()
        )
        let now = F.departure.addingTimeInterval(-30 * 60)
        let firstOutput = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg(id: "L1")],
            nowUTC: now
        ))
        let revisedDeparture = F.departure.addingTimeInterval(10 * 60)
        let revisedOutput = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg(
                id: "L1",
                departure: revisedDeparture,
                arrival: F.arrival.addingTimeInterval(10 * 60)
            )],
            nowUTC: now
        ))

        await coordinator.refresh(output: firstOutput, mode: .reconcile, nowUTC: now)
        await coordinator.refresh(output: revisedOutput, mode: .reconcile, nowUTC: now)

        let counts = await activityClient.counts()
        XCTAssertEqual(counts.update, 2)
        XCTAssertEqual(counts.end, 0)
        XCTAssertEqual(counts.request, 0)
        let updatedDepartures = await activityClient.updatedPlannedDepartureUTCs()
        XCTAssertEqual(updatedDepartures, [F.departure, revisedDeparture])
        XCTAssertEqual(updatedDepartures.last, revisedDeparture)
    }

    func test_T19_legChangeEndsAndCreatesButReplacementAlwaysRebuilds() async throws {
        let now = F.departure.addingTimeInterval(-30 * 60)
        let nextLeg = F.leg(id: "L2")
        let nextOutput = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [nextLeg],
            nowUTC: now
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
            nowUTC: now
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
            nowUTC: now
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

    func test_T18_expiredStateEndsActivityAndDeletesSnapshot() async throws {
        let activityClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "stale", legID: "L1")]
        )
        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: snapshotClient
        )
        let now = F.departure.addingTimeInterval(61 * 60)
        XCTAssertNil(FlightCountdownEngine.buildCountdownOutput(from: [F.leg()], nowUTC: now))
        await coordinator.refresh(output: nil, mode: .reconcile, nowUTC: now)

        let counts = await activityClient.counts()
        let persistedLegIDs = await snapshotClient.persistedLegIDs()
        XCTAssertEqual(counts.end, 1)
        XCTAssertEqual(persistedLegIDs, [nil])
    }

    func test_T18_expiryEndsCurrentAndStartsEligibleNextLegExactlyOnce() async throws {
        let current = F.leg(id: "L1")
        let nextDeparture = F.departure.addingTimeInterval(90 * 60)
        let next = F.leg(
            id: "L2",
            departure: nextDeparture,
            arrival: F.arrival.addingTimeInterval(90 * 60)
        )
        let activityClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "current", legID: current.id)]
        )
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: FlightCountdownSnapshotSpy()
        )

        let beforeExpiry = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [current, next],
            nowUTC: F.departure.addingTimeInterval(60 * 60 + 59)
        ))
        await coordinator.refresh(
            output: beforeExpiry,
            mode: .reconcile,
            nowUTC: F.departure.addingTimeInterval(60 * 60 + 59)
        )

        let atExpiry = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [current, next],
            nowUTC: F.departure.addingTimeInterval(61 * 60)
        ))
        await coordinator.refresh(
            output: atExpiry,
            mode: .reconcile,
            nowUTC: F.departure.addingTimeInterval(61 * 60)
        )

        let counts = await activityClient.counts()
        XCTAssertEqual(beforeExpiry.leg.id, "L1")
        XCTAssertEqual(atExpiry.leg.id, "L2")
        XCTAssertEqual(counts.update, 1)
        XCTAssertEqual(counts.end, 1)
        XCTAssertEqual(counts.request, 1)
    }

    @MainActor
    func test_boundarySchedulingUsesOnlyReportSTDAndSTDPlusSixtyOne() throws {
        let report = F.departure.addingTimeInterval(-90 * 60)
        let leg = F.leg(report: report)
        let preReportNow = report.addingTimeInterval(-60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [leg],
            nowUTC: preReportNow
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
            F.departure.addingTimeInterval(61 * 60)
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

    func updatedPlannedDepartureUTCs() -> [Date] {
        updateSnapshots.map(\.plannedDepartureUTC)
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

    func test_T6_expiredLegIsExcludedAndNextLegIsSelectedAfterRelaunchReconstruction() throws {
        let expired = F.leg(id: "expired")
        let nextDeparture = F.departure.addingTimeInterval(3 * 60 * 60)
        let next = F.leg(
            id: "next",
            departure: nextDeparture,
            arrival: nextDeparture.addingTimeInterval(2 * 60 * 60)
        )
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [expired, next],
            nowUTC: F.departure.addingTimeInterval(61 * 60)
        ))
        XCTAssertEqual(output.leg.id, "next")
        XCTAssertEqual(output.state, .preDeparture)
    }

    func test_T21_passedLegWinsThroughMinuteSixtyThenNextLegTakesOverAtMinuteSixtyOne() throws {
        let current = F.leg(id: "current")
        let next = F.leg(
            id: "next",
            departure: F.departure.addingTimeInterval(90 * 60),
            arrival: F.arrival.addingTimeInterval(90 * 60)
        )
        let minuteSixty = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [next, current],
            nowUTC: F.departure.addingTimeInterval(60 * 60 + 59)
        ))
        XCTAssertEqual(minuteSixty.leg.id, current.id)
        XCTAssertEqual(minuteSixty.state, .departureTimePassed)

        let minuteSixtyOne = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [next, current],
            nowUTC: F.departure.addingTimeInterval(61 * 60)
        ))
        XCTAssertEqual(minuteSixtyOne.leg.id, next.id)
        XCTAssertEqual(minuteSixtyOne.state, .preDeparture)
    }
}

final class FlightCountdownConversionAndBuilderTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_T11_countdownLegUsesPlanningAndIgnoresActualValuesIncludingInvalidActual() throws {
        let leg = makeTripLeg(
            sequence: 1,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: "2026-07-01T12:30:00Z",
            displayArrival: "2026-07-01T20:20:00Z",
            plannedDeparture: "2026-07-01T12:00:00Z",
            plannedArrival: "2026-07-01T20:00:00Z",
            atd: "not-a-date",
            ata: "also-not-a-date"
        )
        let converted = try leg.countdownLegResult().get()
        XCTAssertEqual(converted.plannedDepartureUTC, F.departure)
        XCTAssertEqual(converted.plannedArrivalUTC, F.arrival)
        XCTAssertEqual(FlightCountdownEngine.state(for: converted, nowUTC: F.departure), .departureTimePassed)
    }

    func test_T11_actualOnlyChangesProduceIdenticalOperationalPayload() throws {
        let original = makeTripLeg(
            sequence: 1,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: "2026-07-01T12:00:00Z",
            displayArrival: "2026-07-01T20:00:00Z",
            plannedDeparture: "2026-07-01T12:00:00Z",
            plannedArrival: "2026-07-01T20:00:00Z"
        )
        var withActual = original
        withActual.depUTC = "2026-07-01T12:22:00Z"
        withActual.arrUTC = "2026-07-01T19:51:00Z"
        withActual.atdUTC = "2026-07-01T12:22:00Z"
        withActual.ataUTC = "2026-07-01T19:51:00Z"

        let now = F.departure.addingTimeInterval(15 * 60)
        let withoutActual = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [original])],
            domicileAirportCode: "ANC",
            nowUTC: now
        ))
        let actualObserved = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [withActual])],
            domicileAirportCode: "ANC",
            nowUTC: now
        ))

        XCTAssertEqual(actualObserved, withoutActual)
    }

    func test_T11_STAOnlyChangeDoesNotAlterRealtimeStateOrDescriptor() throws {
        let original = makeTripLeg(
            sequence: 1,
            dep: "ANC",
            arr: "NRT",
            displayDeparture: "2026-07-01T12:00:00Z",
            displayArrival: "2026-07-01T20:00:00Z",
            plannedDeparture: "2026-07-01T12:00:00Z",
            plannedArrival: "2026-07-01T20:00:00Z"
        )
        var revisedArrival = original
        revisedArrival.staUTC = "2026-07-01T21:30:00Z"
        let now = F.departure.addingTimeInterval(15 * 60)

        let baseline = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [original])],
            domicileAirportCode: "ANC",
            nowUTC: now
        ))
        let revised = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [revisedArrival])],
            domicileAirportCode: "ANC",
            nowUTC: now
        ))

        XCTAssertEqual(revised.leg.id, baseline.leg.id)
        XCTAssertEqual(revised.state, baseline.state)
        XCTAssertEqual(revised.presentation, baseline.presentation)
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
            nowUTC: F.date("2026-07-01T10:00:00Z")
        ))
        XCTAssertEqual(preReport.state, .preReport)
        XCTAssertEqual(preReport.leg.reportTimeUTC, F.date("2026-07-01T10:30:00Z"))

        let afterFirst = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [first, second])],
            domicileAirportCode: "ANC",
            nowUTC: F.date("2026-07-02T10:00:00Z")
        ))
        XCTAssertEqual(afterFirst.leg.id, second.id.uuidString)
        XCTAssertNil(afterFirst.leg.reportTimeUTC)
        XCTAssertEqual(afterFirst.state, .preDeparture)
    }

    func test_reportTimeIsNotInferredWhenNoBaseDepartureCanBeIdentified() throws {
        let leg = makeTripLeg(
            sequence: 1,
            dep: "NRT",
            arr: "ANC",
            displayDeparture: "2026-07-01T12:00:00Z",
            displayArrival: "2026-07-01T20:00:00Z",
            plannedDeparture: "2026-07-01T12:00:00Z",
            plannedArrival: "2026-07-01T20:00:00Z"
        )
        let output = try XCTUnwrap(OperationalStateBuilder.build(
            schedules: [makeSchedule(legs: [leg])],
            domicileAirportCode: "ANC",
            nowUTC: F.date("2026-07-01T10:00:00Z")
        ))

        XCTAssertNil(output.leg.reportTimeUTC)
        XCTAssertEqual(output.state, .preDeparture)
        XCTAssertEqual(output.presentation.prefix, "Dep in")
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
            nowUTC: F.date("2026-07-02T10:00:00Z")
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

#if DEBUG
@MainActor
final class DebugFlightCountdownFixtureTests: XCTestCase {
    private let canonicalNowUTC = ISO8601DateFormatter().date(from: "2026-08-16T18:30:00Z")!

    func test_T45_fixtureUsesProductionOperationalStateBuilder() throws {
        let output = try XCTUnwrap(buildCanonicalOutput(nowUTC: canonicalNowUTC))

        XCTAssertEqual(output.leg.id, AppViewModel.debugFlightCountdownFirstLegID.uuidString)
        XCTAssertEqual(output.state, .preReport)
        XCTAssertEqual(output.visibility, .liveActivity)
        XCTAssertEqual(output.leg.reportTimeUTC, date("2026-08-16T22:10:00Z"))
        XCTAssertEqual(
            output.leg.reportTimeUTC?.timeIntervalSince(canonicalNowUTC),
            date("2026-08-16T22:10:00Z").timeIntervalSince(canonicalNowUTC)
        )
    }

    func test_T46_deviceTimezoneDoesNotChangeDurationStateOrCurrentLeg() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        var outputs: [CountdownEngineOutput] = []
        for identifier in ["America/Anchorage", "Asia/Ho_Chi_Minh", "Asia/Seoul"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: identifier))
            outputs.append(try XCTUnwrap(buildCanonicalOutput(nowUTC: canonicalNowUTC)))
        }

        let expected = try XCTUnwrap(outputs.first)
        for output in outputs {
            XCTAssertEqual(output.state, .preReport)
            XCTAssertEqual(output.leg.id, AppViewModel.debugFlightCountdownFirstLegID.uuidString)
            XCTAssertEqual(output.presentation, expected.presentation)
            XCTAssertEqual(output.leg.reportTimeUTC?.timeIntervalSince(canonicalNowUTC),
                           expected.leg.reportTimeUTC?.timeIntervalSince(canonicalNowUTC))
            XCTAssertEqual(output.display.departureTimeText, expected.display.departureTimeText)
            XCTAssertEqual(output.display.arrivalTimeText, expected.display.arrivalTimeText)
        }
    }

    func test_T47_operationalStateIsIndependentAcrossAllPresentationWindows() throws {
        let variants: [(String, FlightPresentationVisibility)] = [
            ("2026-08-16T10:40:00Z", .hidden),
            ("2026-08-16T16:40:00Z", .widget),
            ("2026-08-16T18:40:00Z", .liveActivity)
        ]

        for (nowString, expectedVisibility) in variants {
            let output = try XCTUnwrap(buildCanonicalOutput(nowUTC: date(nowString)))
            XCTAssertEqual(output.leg.id, AppViewModel.debugFlightCountdownFirstLegID.uuidString)
            XCTAssertEqual(output.state, .preReport)
            XCTAssertEqual(output.visibility, expectedVisibility)
            XCTAssertEqual(output.leg.plannedDepartureUTC, date("2026-08-16T23:40:00Z"))
            XCTAssertEqual(output.leg.reportTimeUTC, date("2026-08-16T22:10:00Z"))
        }
    }

    func test_T48_passedFirstLegOwnsMinuteSixtyAndSecondLegTakesOverAtMinuteSixtyOne() throws {
        let firstDeparture = date("2026-08-16T23:40:00Z")
        let minuteSixty = try XCTUnwrap(buildCanonicalOutput(
            nowUTC: firstDeparture.addingTimeInterval(60 * 60 + 59)
        ))
        let minuteSixtyOne = try XCTUnwrap(buildCanonicalOutput(
            nowUTC: firstDeparture.addingTimeInterval(61 * 60)
        ))
        XCTAssertEqual(AppViewModel.debugFlightCountdownCanonicalSchedules().flatMap(\.legs).count, 2)
        XCTAssertEqual(minuteSixty.leg.id, AppViewModel.debugFlightCountdownFirstLegID.uuidString)
        XCTAssertEqual(minuteSixty.state, .departureTimePassed)
        XCTAssertEqual(minuteSixtyOne.leg.id, AppViewModel.debugFlightCountdownSecondLegID.uuidString)
        XCTAssertEqual(minuteSixtyOne.state, .preDeparture)
        XCTAssertNil(minuteSixtyOne.leg.reportTimeUTC)
    }

    func test_T49_fixtureLifecycleDoesNotPersistOrUploadSchedules() async throws {
        let baseline = PayPeriodSchedule(
            id: "BASELINE",
            label: "BASELINE",
            tripCount: 0,
            legCount: 0,
            openTimeCount: 0,
            updatedAt: date("2026-08-01T00:00:00Z"),
            legs: [],
            openTimeTrips: []
        )
        let cache = DebugFlightFixtureCache(
            snapshot: ScheduleCacheSnapshotV2(
                crewAccessSchedules: [baseline],
                bidproSchedules: [],
                lastSyncAt: date("2026-08-01T00:00:00Z"),
                migratedAt: nil
            )
        )
        let friendUploadSpy = DebugFlightFixtureFriendUploadSpy()
        let deviceUploadSpy = DebugFlightFixtureDeviceUploadSpy()
        let notificationSpy = DebugFlightFixtureNotificationSpy()
        let activitySpy = FlightCountdownActivitySpy(activities: [])
        let snapshotSpy = FlightCountdownSnapshotSpy()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdh-debug-flight-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let viewModel = AppViewModel(
            cacheService: cache,
            notificationService: notificationSpy,
            friendScheduleCloudKitService: friendUploadSpy,
            deviceScheduleCloudKitService: deviceUploadSpy,
            flightCountdownCoordinator: FlightCountdownCoordinator(
                activityClient: activitySpy,
                snapshotClient: snapshotSpy
            ),
            crewAccessImportsDirectory: directory,
            retentionReferenceDate: { ISO8601DateFormatter().date(from: "2026-08-16T18:30:00Z")! }
        )
        viewModel.isScheduleSharingEnabled = true
        let schedulesBefore = viewModel.schedules
        let crewSchedulesBefore = viewModel.crewAccessSchedules
        let revisionBefore = viewModel.scheduleDataRevision

        await viewModel.startDebugFlightCountdownFixture(nowUTC: canonicalNowUTC)

        XCTAssertTrue(viewModel.isDebugFlightCountdownFixtureActive)
        XCTAssertEqual(viewModel.schedules, schedulesBefore)
        XCTAssertEqual(viewModel.crewAccessSchedules, crewSchedulesBefore)
        XCTAssertEqual(viewModel.scheduleDataRevision, revisionBefore)
        let uploadCountsAfterStart = await friendUploadSpy.counts()
        let deviceUploadsAfterStart = await deviceUploadSpy.uploadCount()
        let activityCountsAfterStart = await activitySpy.counts()
        XCTAssertEqual(uploadCountsAfterStart, .init(shared: 0, snapshot: 0))
        XCTAssertEqual(deviceUploadsAfterStart, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertEqual(activityCountsAfterStart.request, 1)

        await viewModel.stopDebugFlightCountdownFixture(nowUTC: canonicalNowUTC)

        let notificationInvalidationsAfterStop = await notificationSpy.invalidationCount()
        let uploadCountsAfterStop = await friendUploadSpy.counts()
        let deviceUploadsAfterStop = await deviceUploadSpy.uploadCount()
        let persistedLegIDsAfterStop = await snapshotSpy.persistedLegIDs()
        XCTAssertFalse(viewModel.isDebugFlightCountdownFixtureActive)
        XCTAssertEqual(viewModel.schedules, schedulesBefore)
        XCTAssertEqual(viewModel.crewAccessSchedules, crewSchedulesBefore)
        XCTAssertEqual(notificationInvalidationsAfterStop, 1)
        XCTAssertEqual(uploadCountsAfterStop, .init(shared: 0, snapshot: 0))
        XCTAssertEqual(deviceUploadsAfterStop, 0)
        XCTAssertNil(persistedLegIDsAfterStop.last!)
        XCTAssertNil(viewModel.nextFlightCountdownOutput(nowUTC: canonicalNowUTC))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func buildCanonicalOutput(nowUTC: Date) -> CountdownEngineOutput? {
        OperationalStateBuilder.build(
            schedules: AppViewModel.debugFlightCountdownCanonicalSchedules(),
            domicileAirportCode: "ANC",
            nowUTC: nowUTC
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class DebugFlightFixtureCache: ScheduleCacheServiceProtocol {
    private var snapshot: ScheduleCacheSnapshotV2?

    init(snapshot: ScheduleCacheSnapshotV2?) {
        self.snapshot = snapshot
    }

    func load() -> ScheduleCacheSnapshotV2? { snapshot }
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private actor DebugFlightFixtureFriendUploadSpy: FriendScheduleCloudKitServicing {
    struct Counts: Equatable {
        let shared: Int
        let snapshot: Int
    }

    private var sharedUploadCount = 0
    private var snapshotUploadCount = 0

    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {
        sharedUploadCount += 1
    }

    func uploadScheduleSnapshot(
        gemsID: String,
        ownerDisplayName: String,
        crewAccessTrips: [CrewAccessTripJSON]
    ) async throws {
        snapshotUploadCount += 1
    }

    func requestFriend(
        myGEMSID: String,
        friendGEMSID: String,
        friendResetAt: Date?
    ) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(
            friendGEMSID: friendGEMSID,
            isAccepted: false,
            linkedAt: nil,
            requestedAt: nil
        )
    }

    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func deleteSharedScheduleData(gemsID: String) async throws {}
    func deleteFriendSharingData(gemsID: String) async throws {}

    func refreshConnections(
        myGEMSID: String,
        connections: [FriendConnection],
        friendResetAt: Date?
    ) async throws -> FriendConnectionRefreshResult {
        FriendConnectionRefreshResult(connections: connections)
    }

    func counts() -> Counts {
        Counts(shared: sharedUploadCount, snapshot: snapshotUploadCount)
    }
}

private actor DebugFlightFixtureDeviceUploadSpy: DeviceScheduleCloudKitServicing {
    private var count = 0

    func uploadDeviceSchedule(
        gemsID: String,
        cloudKitRecordName: String,
        schedules: [PayPeriodSchedule],
        deviceID: String,
        source: DeviceScheduleSyncSource
    ) async throws {
        count += 1
    }

    func fetchDeviceSchedule(gemsID: String) async throws -> DeviceScheduleSnapshot? { nil }
    func uploadCount() -> Int { count }
}

private actor DebugFlightFixtureNotificationSpy: NextReportNotificationServiceProtocol {
    private var invalidations = 0

    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func invalidateNextReportNotifications() async { invalidations += 1 }
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
    }

    func invalidationCount() -> Int { invalidations }
}
#endif
