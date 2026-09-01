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

private enum HomeWidgetTestFixture {
    static let report = date("2026-08-30T22:00:00Z")
    static let firstDeparture = date("2026-08-30T23:00:00Z")
    static let firstArrival = date("2026-08-31T01:00:00Z")
    static let secondDeparture = date("2026-08-31T04:00:00Z")
    static let secondArrival = date("2026-08-31T08:00:00Z")
    static let finalDeparture = date("2026-08-31T12:00:00Z")
    static let finalArrival = date("2026-08-31T20:00:00Z")
    static let release = date("2026-08-31T20:30:00Z")
    static let nextReport = date("2026-08-31T21:00:00Z")
    static let nextDeparture = date("2026-08-31T22:30:00Z")
    static let nextArrival = date("2026-09-01T02:00:00Z")
    static let nextRelease = date("2026-09-01T02:30:00Z")

    static let sdfCoordinate = HomeWidgetAirportCoordinate(
        latitude: 38.1706,
        longitude: -85.735076
    )
    static let nrtCoordinate = HomeWidgetAirportCoordinate(
        latitude: 35.76858,
        longitude: 140.388714
    )
    static let ancCoordinate = HomeWidgetAirportCoordinate(
        latitude: 61.1744,
        longitude: -149.996
    )

    static let firstLeg = leg(
        id: "first",
        flightNumber: "5X123",
        departureAirport: "ANC",
        arrivalAirport: "SDF",
        departure: firstDeparture,
        arrival: firstArrival,
        departureTimeZoneID: "America/Anchorage",
        arrivalTimeZoneID: "America/Kentucky/Louisville",
        arrivalCoordinate: sdfCoordinate,
        layoverAfterMinutes: 180
    )
    static let secondLeg = leg(
        id: "second",
        flightNumber: "5X456",
        departureAirport: "SDF",
        arrivalAirport: "NRT",
        departure: secondDeparture,
        arrival: secondArrival,
        departureTimeZoneID: "America/Kentucky/Louisville",
        arrivalTimeZoneID: "Asia/Tokyo",
        arrivalCoordinate: nrtCoordinate,
        layoverAfterMinutes: 240
    )
    static let finalLeg = leg(
        id: "final",
        flightNumber: "5X789",
        departureAirport: "NRT",
        arrivalAirport: "ANC",
        departure: finalDeparture,
        arrival: finalArrival,
        departureTimeZoneID: "Asia/Tokyo",
        arrivalTimeZoneID: "America/Anchorage",
        arrivalCoordinate: ancCoordinate
    )
    static let currentTrip = HomeWidgetTrip(
        id: "PP26-08|A70639",
        tripID: "A70639",
        reportTimeUTC: report,
        reportTimeZoneID: "America/Anchorage",
        releaseBoundaryUTC: release,
        legs: [firstLeg, secondLeg, finalLeg]
    )
    static let nextTrip = HomeWidgetTrip(
        id: "PP26-08|A70640",
        tripID: "A70640",
        reportTimeUTC: nextReport,
        reportTimeZoneID: "America/Anchorage",
        releaseBoundaryUTC: nextRelease,
        legs: [
            leg(
                id: "next",
                flightNumber: "5X900",
                departureAirport: "ANC",
                arrivalAirport: "SDF",
                departure: nextDeparture,
                arrival: nextArrival,
                departureTimeZoneID: "America/Anchorage",
                arrivalTimeZoneID: "America/Kentucky/Louisville",
                arrivalCoordinate: sdfCoordinate
            )
        ]
    )
    static let snapshot = HomeWidgetScheduleSnapshot(
        updatedAtUTC: report.addingTimeInterval(-60),
        trips: [nextTrip, currentTrip]
    )

    static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func leg(
        id: String,
        flightNumber: String,
        departureAirport: String,
        arrivalAirport: String,
        departure: Date,
        arrival: Date,
        departureTimeZoneID: String,
        arrivalTimeZoneID: String,
        arrivalCoordinate: HomeWidgetAirportCoordinate? = nil,
        layoverAfterMinutes: Int? = nil
    ) -> HomeWidgetLeg {
        HomeWidgetLeg(
            id: id,
            flightNumber: flightNumber,
            departureAirportIATA: departureAirport,
            arrivalAirportIATA: arrivalAirport,
            plannedDepartureUTC: departure,
            plannedArrivalUTC: arrival,
            departureTimeZoneID: departureTimeZoneID,
            arrivalTimeZoneID: arrivalTimeZoneID,
            arrivalCoordinate: arrivalCoordinate,
            layoverAfterMinutes: layoverAfterMinutes
        )
    }
}

private actor HomeWidgetWeatherEnrichmentCounter {
    private var count = 0

    func recordAndReturn(_ value: String?) -> String? {
        count += 1
        return value
    }

    func value() -> Int { count }
}

private final class ANCOnlyIATATimeZoneResolver: IATATimeZoneResolving, @unchecked Sendable {
    let mappingVersion = "anc-only"

    func resolve(_ iata: String) -> String? {
        iata.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ANC"
            ? "America/Anchorage"
            : nil
    }
    func airportName(_ iata: String) -> String? { nil }
    func cityName(_ iata: String) -> String? { nil }
    func setOverride(iata: String, tzID: String?) {}
    func currentOverrides() -> [String: String] { [:] }
}

private final class ANCSDFIATATimeZoneResolver: IATATimeZoneResolving, @unchecked Sendable {
    let mappingVersion = "anc-sdf-only"

    func resolve(_ iata: String) -> String? {
        switch iata.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ANC": "America/Anchorage"
        case "SDF": "America/Kentucky/Louisville"
        default: nil
        }
    }
    func airportName(_ iata: String) -> String? { nil }
    func cityName(_ iata: String) -> String? { nil }
    func setOverride(iata: String, tzID: String?) {}
    func currentOverrides() -> [String: String] { [:] }
}

final class Phase4LayoutTests: XCTestCase {
#if false // RETIRED: Flight Countdown Live Activity was removed by product decision.
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
        let timerClampUTC = FlightCountdownLiveActivityTimerContract.timerClampUTC(
            plannedDepartureUTC: targetUTC
        )

        XCTAssertEqual(FlightCountdownLiveActivityTimerContract.maxFieldCount, 2)
        XCTAssertEqual(FlightCountdownLiveActivityTimerContract.maxPrecision, .seconds(60))
        XCTAssertEqual(FlightCountdownLiveActivityTimerContract.departureElapsedClampInterval, 60 * 60)
        XCTAssertEqual(
            FlightCountdownLiveActivityTimerContract.countdownInterval(endingAt: targetUTC).upperBound,
            targetUTC
        )
        XCTAssertEqual(
            FlightCountdownLiveActivityTimerContract.countUpInterval(
                startingAt: targetUTC,
                timerClampUTC: timerClampUTC
            ),
            targetUTC..<timerClampUTC
        )
        XCTAssertEqual(timerClampUTC, targetUTC.addingTimeInterval(60 * 60))
        XCTAssertEqual(expirationUTC, targetUTC.addingTimeInterval(61 * 60))
        XCTAssertNotEqual(timerClampUTC, expirationUTC)

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
            FlightCountdownActivityLifecyclePolicy.staleDate(
                state: .preDeparture,
                plannedDepartureUTC: plannedDeparture,
                reportTimeUTC: nil
            ),
            plannedDeparture
        )
        let reportTime = plannedDeparture.addingTimeInterval(-90 * 60)
        XCTAssertEqual(
            FlightCountdownActivityLifecyclePolicy.staleDate(
                state: .preReport,
                plannedDepartureUTC: plannedDeparture,
                reportTimeUTC: reportTime
            ),
            reportTime
        )
        XCTAssertEqual(
            FlightCountdownActivityLifecyclePolicy.staleDate(
                state: .departureTimePassed,
                plannedDepartureUTC: plannedDeparture,
                reportTimeUTC: nil
            ),
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
        XCTAssertTrue(
            compactSharedSource.contains(
                "countUpInterval(startingAt:presentation.anchorUTC,timerClampUTC:timerClampUTC)"
            )
        )
        XCTAssertFalse(
            compactSharedSource.contains(
                "countUpInterval(startingAt:presentation.anchorUTC,expirationUTC:"
            )
        )
    }
#endif

    func test_T16_flightOperationalSurfacesStaySharedWhileTimelineUsesNextReportContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let timelinePaths = [
            "TripDataHub/Views/TimelineTabView.swift",
            "TripDataHub/Views/iPad/iPadTimelineSidebarView.swift"
        ]

        for path in timelinePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("TimelineNextReportCountdownView"), path)
            XCTAssertTrue(source.contains("TimelineNextReportCountdownBuilder"), path)
            XCTAssertFalse(source.contains("OperationalCountdownStatusView"), path)
            XCTAssertFalse(source.contains("operationalCountdownOutput"), path)
            XCTAssertFalse(source.contains("countdownText("), path)
            XCTAssertFalse(source.contains("(-05d"), path)
        }

        let widgetPath = "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
        let widgetSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(widgetPath),
            encoding: .utf8
        )
        XCTAssertTrue(widgetSource.contains("HomeWidgetDomain.timeline"), widgetPath)
        XCTAssertTrue(widgetSource.contains("HomeWidgetEntryView"), widgetPath)
        XCTAssertFalse(widgetSource.contains("TimelineNextReportCountdownBuilder"), widgetPath)
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
        XCTAssertTrue(appViewModelSource.contains("homeWidgetScheduleSnapshot"))
        XCTAssertTrue(appViewModelSource.contains("refreshHomeWidget"))
        XCTAssertFalse(appViewModelSource.contains("flightCountdownBoundaryTask"))
        XCTAssertFalse(appViewModelSource.contains("nextFlightCountdownEvaluationBoundary"))
    }

    /// T-51S guards the source-level theme-aware foreground/background ownership contract. It
    /// does not inspect rendered pixels; Light/Dark acceptance remains a device verification step.
    func test_T51S_homeWidgetCustomBackgroundUsesSystemAppearancePalette() throws {
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
            source.range(of: "private struct HomeWidgetEntryView")
        ).lowerBound
        let widgetViewEnd = try XCTUnwrap(
            source.range(
                of: "private struct HomeWidgetSmallView",
                range: widgetViewStart..<source.endIndex
            )
        ).lowerBound
        let widgetViewSource = compactSyntax(
            String(source[widgetViewStart..<widgetViewEnd])
        )

        XCTAssertTrue(widgetViewSource.contains("@Environment(\\.colorScheme)privatevarcolorScheme"))
        XCTAssertTrue(widgetViewSource.contains("HomeWidgetPalette(colorScheme:colorScheme)"))
        XCTAssertFalse(widgetViewSource.contains(".environment(\\.colorScheme,.dark)"))
        XCTAssertTrue(widgetViewSource.contains(".containerBackground(for:.widget)"))
        XCTAssertTrue(widgetViewSource.contains("LinearGradient("))
    }

#if false // RETIRED: Flight Countdown Live Activity was removed by product decision.
    func test_postTripCorrective_liveActivityUsesStateSpecificFreshnessAndStaleSafeShell() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinatorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "TripDataHub/Services/FlightCountdownCoordinator.swift"
            ),
            encoding: .utf8
        )
        let widgetSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
            ),
            encoding: .utf8
        )
        let compactCoordinator = compactSyntax(coordinatorSource)
        let compactWidget = compactSyntax(widgetSource)

        XCTAssertTrue(compactCoordinator.contains("switchstate"))
        XCTAssertTrue(compactCoordinator.contains("case.preDeparture:"))
        XCTAssertTrue(compactCoordinator.contains("returnplannedDepartureUTC"))
        XCTAssertTrue(compactCoordinator.contains("case.departureTimePassed"))
        XCTAssertTrue(
            compactCoordinator.contains(
                "plannedDepartureUTC.addingTimeInterval(FlightOperationalState.expirationInterval)"
            )
        )
        XCTAssertTrue(compactWidget.contains("isStale:context.isStale"))
        XCTAssertTrue(compactWidget.contains("ifisStale"))
        XCTAssertTrue(compactWidget.contains("OpenTripDataHubforcurrentstatus"))
        XCTAssertTrue(compactWidget.contains("elseifstate==.preDeparture"))
        XCTAssertTrue(compactWidget.contains("format:.reference("))
        XCTAssertTrue(compactWidget.contains("to:plannedDepartureUTC"))
        XCTAssertTrue(compactWidget.contains("allowedFields:[.hour,.minute]"))
    }

    func test_postTripCorrective_dynamicIslandCompactAndMinimalAreNeutralIndicatorsOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
            ),
            encoding: .utf8
        )
        let dynamicIslandStart = try XCTUnwrap(source.range(of: "DynamicIsland {"))
        let dynamicIslandEnd = try XCTUnwrap(
            source.range(
                of: "\n        }\n    }\n}",
                range: dynamicIslandStart.lowerBound..<source.endIndex
            )
        )
        let dynamicIslandSource = String(source[dynamicIslandStart.lowerBound..<dynamicIslandEnd.upperBound])
        let compactLeading = try sourceSlice(
            dynamicIslandSource,
            from: "compactLeading: {",
            to: "compactTrailing: {"
        )
        let compactTrailing = try sourceSlice(
            dynamicIslandSource,
            from: "compactTrailing: {",
            to: "minimal: {"
        )
        let minimal = try sourceSlice(
            dynamicIslandSource,
            from: "minimal: {",
            to: "\n        }"
        )

        for region in [compactLeading, compactTrailing, minimal] {
            XCTAssertFalse(region.contains("flightNumber"))
            XCTAssertFalse(region.contains("LiveActivityOperationalStatusView"))
            XCTAssertFalse(region.contains("formattedFlightNumber"))
            XCTAssertFalse(region.contains("hours"))
            XCTAssertFalse(region.contains("minutes"))
        }
        XCTAssertTrue(compactLeading.contains("Image(systemName: \"airplane\")"))
        XCTAssertTrue(minimal.contains("Image(systemName: \"airplane\")"))
        XCTAssertTrue(compactTrailing.contains("EmptyView()"))
    }
#endif

    func test_F9_homeWidgetFamilyInformationContract() {
        XCTAssertFalse(HomeWidgetFamily.small.showsArrivalTime)
        XCTAssertFalse(HomeWidgetFamily.small.showsUTCTime)
        XCTAssertFalse(HomeWidgetFamily.small.showsDestinationWeather)
        XCTAssertFalse(HomeWidgetFamily.small.showsLayover)

        XCTAssertTrue(HomeWidgetFamily.medium.showsArrivalTime)
        XCTAssertTrue(HomeWidgetFamily.medium.showsUTCTime)
        XCTAssertTrue(HomeWidgetFamily.medium.showsDestinationWeather)
        XCTAssertTrue(HomeWidgetFamily.medium.showsLayover)
    }

    private func compactSyntax(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private func sourceSlice(
        _ source: String,
        from startToken: String,
        to endToken: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken)).upperBound
        let end = try XCTUnwrap(
            source.range(of: endToken, range: start..<source.endIndex)
        ).lowerBound
        return String(source[start..<end])
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

#if false // RETIRED: Flight Countdown Live Activity was removed by product decision.
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
#endif

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
            (F.departure, .departureTimePassed, nil, nil),
            (F.departure.addingTimeInterval(60), .departureTimePassed, nil, nil),
            (F.departure.addingTimeInterval(60 * 60), .departureTimePassed, nil, nil),
            (F.departure.addingTimeInterval(60 * 60 + 59), .departureTimePassed, nil, nil),
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

    func test_T21_evaluationOrderAndExactSixtyOneMinuteBoundary() {
        let report = F.departure.addingTimeInterval(-90 * 60)
        XCTAssertEqual(F.state(now: report, report: report), .preDeparture)
        XCTAssertEqual(F.state(now: F.departure, report: report), .departureTimePassed)
        XCTAssertEqual(F.state(now: F.departure.addingTimeInterval(60 * 60 + 59), report: report), .departureTimePassed)
        XCTAssertEqual(F.state(now: F.departure.addingTimeInterval(61 * 60), report: report), .expired)
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
        let presentation = try XCTUnwrap(output.presentation)

        XCTAssertEqual(F.departure.timeIntervalSince(now), 2 * 60 * 60 + 11 * 60)
        XCTAssertEqual(presentation.state, .preDeparture)
        XCTAssertEqual(presentation.prefix, "Dep in")
        XCTAssertEqual(presentation.anchorUTC, F.departure)
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

    func test_T10_STDPassedKeepsDomainStateWithoutWidgetPresentationUntilExpiration() throws {
        let now = F.departure.addingTimeInterval(60 * 60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now
        ))
        XCTAssertEqual(output.state, .departureTimePassed)
        XCTAssertEqual(output.visibility, .hidden)
        XCTAssertNil(output.presentation)
    }

    func test_departurePassedStateExpiresAtSixtyOne() {
        let report = F.departure.addingTimeInterval(-90 * 60)
        XCTAssertNil(OperationalCountdownPresentation.make(
            state: .departureTimePassed,
            plannedDepartureUTC: F.departure,
            reportTimeUTC: report
        ))

        let checkpoints: [(TimeInterval, FlightOperationalState)] = [
            (59 * 60 + 59, .departureTimePassed),
            (60 * 60, .departureTimePassed),
            (60 * 60 + 59, .departureTimePassed),
            (61 * 60, .expired)
        ]
        for (elapsed, expectedState) in checkpoints {
            let now = F.departure.addingTimeInterval(elapsed)
            XCTAssertEqual(F.state(now: now, report: report), expectedState)
        }
    }

    func test_expirationBoundaryRemainsAbsoluteAcrossDeviceTimezones() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        for identifier in ["America/Anchorage", "Asia/Ho_Chi_Minh", "Asia/Seoul"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: identifier))
            XCTAssertEqual(
                F.state(now: F.departure.addingTimeInterval(60 * 60 + 59)),
                .departureTimePassed
            )
            XCTAssertEqual(
                F.state(now: F.departure.addingTimeInterval(61 * 60)),
                .expired
            )
        }
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

#if false // RETIRED: Activity request/update/end lifecycle tests for the removed feature.
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

    func test_foregroundReconcileAtDeparturePlusTwentyTwoPublishesPassedState() async throws {
        let activityClient = FlightCountdownActivitySpy(
            activities: [FlightCountdownActivityRecord(id: "activity-L1", legID: "L1")]
        )
        let coordinator = FlightCountdownCoordinator(
            activityClient: activityClient,
            snapshotClient: FlightCountdownSnapshotSpy()
        )
        let now = F.departure.addingTimeInterval(22 * 60)
        let output = try XCTUnwrap(
            FlightCountdownEngine.buildCountdownOutput(from: [F.leg()], nowUTC: now)
        )

        await coordinator.refresh(output: output, mode: .reconcile, nowUTC: now)

        XCTAssertEqual(output.state, .departureTimePassed)
        let updatedStates = await activityClient.updatedStates()
        XCTAssertEqual(updatedStates, [.departureTimePassed])
        let counts = await activityClient.counts()
        XCTAssertEqual(counts.update, 1)
        XCTAssertEqual(counts.end, 0)
        XCTAssertEqual(counts.request, 0)
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
#endif

private actor FlightCountdownSnapshotSpy: FlightCountdownSnapshotClient {
    private var persisted: [FlightCountdownSnapshot?] = []
    private var persistedHomeWidgetSchedules: [HomeWidgetScheduleSnapshot?] = []
    private var reloadCount = 0

    func persist(_ snapshot: FlightCountdownSnapshot?) async {
        persisted.append(snapshot)
    }

    func persistHomeWidgetSchedule(_ snapshot: HomeWidgetScheduleSnapshot?) async {
        persistedHomeWidgetSchedules.append(snapshot)
    }

    func reloadWidgets() async {
        reloadCount += 1
    }

    func persistedLegIDs() -> [String?] {
        persisted.map { $0?.legID }
    }

    func persistedHomeWidgetFirstLegIDs() -> [String?] {
        persistedHomeWidgetSchedules.map { $0?.trips.first?.legs.first?.id }
    }

    func persistedHomeWidgetTripIDs() -> [[String]?] {
        persistedHomeWidgetSchedules.map { snapshot in
            snapshot?.trips.map(\.tripID)
        }
    }

    func homeWidgetCounts() -> (persist: Int, reload: Int) {
        (persistedHomeWidgetSchedules.count, reloadCount)
    }

    func counts() -> (persist: Int, reload: Int) {
        (persisted.count, reloadCount)
    }
}

final class FlightCountdownSnapshotCoordinatorTests: XCTestCase {
    private typealias F = FlightCountdownFixture

    func test_approachingDeparturePublishesHomeWidgetSnapshotWithoutActivityDependency() async throws {
        let now = F.departure.addingTimeInterval(-9 * 60 * 60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now
        ))
        XCTAssertEqual(output.visibility, .widget)

        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(snapshotClient: snapshotClient)
        await coordinator.refresh(output: output, mode: .reconcile, nowUTC: now)

        let persistedLegIDs = await snapshotClient.persistedLegIDs()
        XCTAssertEqual(persistedLegIDs, [F.leg().id])
        let counts = await snapshotClient.counts()
        XCTAssertEqual(counts.persist, 1)
        XCTAssertEqual(counts.reload, 1)
    }

    func test_destructiveRebuildClearsThenPublishesHomeWidgetSnapshot() async throws {
        let now = F.departure.addingTimeInterval(-9 * 60 * 60)
        let output = try XCTUnwrap(FlightCountdownEngine.buildCountdownOutput(
            from: [F.leg()],
            nowUTC: now
        ))
        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(snapshotClient: snapshotClient)

        await coordinator.refresh(output: output, mode: .destructiveRebuild, nowUTC: now)

        let ids = await snapshotClient.persistedLegIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertNil(ids[0])
        XCTAssertEqual(ids[1], F.leg().id)
        let counts = await snapshotClient.counts()
        XCTAssertEqual(counts.reload, 2)
    }

    func test_newHomeWidgetReconcilePublishesOneScheduleProjection() async {
        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(snapshotClient: snapshotClient)

        await coordinator.refreshHomeWidget(snapshot: HomeWidgetTestFixture.snapshot, mode: .reconcile)

        let tripIDs = await snapshotClient.persistedHomeWidgetTripIDs()
        let counts = await snapshotClient.homeWidgetCounts()
        XCTAssertEqual(tripIDs, [["A70640", "A70639"]])
        XCTAssertEqual(counts.persist, 1)
        XCTAssertEqual(counts.reload, 1)
    }

    func test_newHomeWidgetDestructiveRebuildClearsThenPublishes() async {
        let snapshotClient = FlightCountdownSnapshotSpy()
        let coordinator = FlightCountdownCoordinator(snapshotClient: snapshotClient)

        await coordinator.refreshHomeWidget(
            snapshot: HomeWidgetTestFixture.snapshot,
            mode: .destructiveRebuild
        )

        let tripIDs = await snapshotClient.persistedHomeWidgetTripIDs()
        let counts = await snapshotClient.homeWidgetCounts()
        XCTAssertEqual(tripIDs, [nil, ["A70640", "A70639"]])
        XCTAssertEqual(counts.persist, 2)
        XCTAssertEqual(counts.reload, 2)
    }

    func test_boundarySchedulingCarriesReportEverySTDAndReleaseTransitions() throws {
        let snapshot = HomeWidgetTestFixture.snapshot
        let timeline = HomeWidgetDomain.timeline(
            from: snapshot,
            nowUTC: HomeWidgetTestFixture.report.addingTimeInterval(-60)
        )

        XCTAssertEqual(
            timeline.map(\.date),
            [
                HomeWidgetTestFixture.report.addingTimeInterval(-60),
                HomeWidgetTestFixture.report,
                HomeWidgetTestFixture.firstDeparture,
                HomeWidgetTestFixture.secondDeparture,
                HomeWidgetTestFixture.finalDeparture,
                HomeWidgetTestFixture.release,
                HomeWidgetTestFixture.nextReport,
                HomeWidgetTestFixture.nextDeparture,
                HomeWidgetTestFixture.nextRelease
            ]
        )
    }

    func test_productionHasNoFlightCountdownLiveActivityRuntimePath() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "TripDataHub/Models/FlightCountdownSharedModels.swift",
            "TripDataHub/Services/FlightCountdownCoordinator.swift",
            "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift",
            "TripDataHub/Info.plist",
            "TripDataCountdownWidgetExtension/Info.plist"
        ]
        let forbiddenTokens = [
            "import ActivityKit",
            "Activity.request(",
            "activity.update(",
            "activity.end(",
            "ActivityConfiguration(",
            "DynamicIsland",
            "FlightCountdownAttributes",
            "NSSupportsLiveActivities"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(relativePath) retained \(token)")
            }
        }
    }
}

final class HomeWidgetDomainTests: XCTestCase {
    private typealias F = HomeWidgetTestFixture

    func test_reportStateBeforeReportSelectsNextTrip() throws {
        let selection = try XCTUnwrap(HomeWidgetDomain.selection(
            from: F.snapshot,
            nowUTC: F.report.addingTimeInterval(-1)
        ))

        XCTAssertEqual(selection.state, .nextTripReport)
        XCTAssertEqual(selection.trip.tripID, "A70639")
        XCTAssertNil(selection.displayedLeg)
    }

    func test_exactReportTransitionsToActiveTripAndFirstFlight() throws {
        let selection = try XCTUnwrap(HomeWidgetDomain.selection(
            from: F.snapshot,
            nowUTC: F.report
        ))

        XCTAssertEqual(selection.state, .activeTripNextFlight)
        XCTAssertEqual(selection.trip.tripID, "A70639")
        XCTAssertEqual(selection.displayedLeg?.id, "first")
    }

    func test_reportPresentationUsesReportLocationLCLAndEquivalentUTCInstant() throws {
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: F.snapshot,
            nowUTC: F.report.addingTimeInterval(-1)
        ))

        XCTAssertEqual(presentation.reportTime?.local, "AUG 30 14:00")
        XCTAssertEqual(presentation.reportTime?.utc, "AUG 30 22:00")
        XCTAssertEqual(F.currentTrip.reportTimeUTC, F.report)
    }

    func test_nextFlightSelectionChangesAtEveryExactSTD() throws {
        let checkpoints: [(Date, String, HomeWidgetOperationalState)] = [
            (F.firstDeparture.addingTimeInterval(-1), "first", .activeTripNextFlight),
            (F.firstDeparture, "second", .activeTripNextFlight),
            (F.firstDeparture.addingTimeInterval(30 * 60), "second", .activeTripNextFlight),
            (F.secondDeparture, "final", .activeTripNextFlight),
            (F.finalDeparture, "final", .activeTripFinalLeg)
        ]

        for (now, expectedLegID, expectedState) in checkpoints {
            let selection = try XCTUnwrap(HomeWidgetDomain.selection(from: F.snapshot, nowUTC: now))
            XCTAssertEqual(selection.displayedLeg?.id, expectedLegID, "now=\(now)")
            XCTAssertEqual(selection.state, expectedState, "now=\(now)")
        }
    }

    func test_activeTripSuppressesFollowingTripReport() throws {
        let selection = try XCTUnwrap(HomeWidgetDomain.selection(
            from: F.snapshot,
            nowUTC: F.finalDeparture.addingTimeInterval(60)
        ))

        XCTAssertEqual(selection.trip.tripID, "A70639")
        XCTAssertEqual(selection.state, .activeTripFinalLeg)
        XCTAssertNotEqual(selection.trip.tripID, F.nextTrip.tripID)
    }

    func test_finalLegFallbackPersistsUntilReleaseThenNextReportBecomesEligible() throws {
        let atFinalSTD = try XCTUnwrap(HomeWidgetDomain.selection(
            from: F.snapshot,
            nowUTC: F.finalDeparture
        ))
        let justBeforeRelease = try XCTUnwrap(HomeWidgetDomain.selection(
            from: F.snapshot,
            nowUTC: F.release.addingTimeInterval(-1)
        ))
        let atRelease = try XCTUnwrap(HomeWidgetDomain.selection(
            from: F.snapshot,
            nowUTC: F.release
        ))

        XCTAssertEqual(atFinalSTD.state, .activeTripFinalLeg)
        XCTAssertEqual(atFinalSTD.displayedLeg?.id, "final")
        XCTAssertEqual(justBeforeRelease.trip.tripID, "A70639")
        XCTAssertEqual(justBeforeRelease.state, .activeTripFinalLeg)
        XCTAssertEqual(atRelease.trip.tripID, "A70640")
        XCTAssertEqual(atRelease.state, .nextTripReport)
    }

    func test_finalFallbackPresentationRetainsNeutralFinalLegInformation() throws {
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: F.snapshot,
            nowUTC: F.finalDeparture
        ))

        XCTAssertEqual(presentation.state, .activeTripFinalLeg)
        XCTAssertEqual(presentation.flightNumber, "5X789")
        XCTAssertEqual(presentation.departureAirportIATA, "NRT")
        XCTAssertEqual(presentation.arrivalAirportIATA, "ANC")
        XCTAssertNil(presentation.reportTime)
    }

    func test_departureAndArrivalLCLUseTheirAirportTimezonesAndUTCUsesSameDates() throws {
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: F.snapshot,
            nowUTC: F.report
        ))

        XCTAssertEqual(presentation.departureTime?.local, "AUG 30 15:00")
        XCTAssertEqual(presentation.departureTime?.utc, "AUG 30 23:00")
        XCTAssertEqual(presentation.arrivalTime?.local, "AUG 30 21:00")
        XCTAssertEqual(presentation.arrivalTime?.utc, "AUG 31 01:00")
        XCTAssertEqual(F.firstLeg.plannedDepartureUTC, F.firstDeparture)
        XCTAssertEqual(F.firstLeg.plannedArrivalUTC, F.firstArrival)
    }

    func test_DSTTransitionUsesAirportTimezonesNotDeviceTimezone() throws {
        let departure = F.date("2026-03-08T10:30:00Z")
        let arrival = F.date("2026-03-08T12:30:00Z")
        let snapshot = singleLegSnapshot(
            report: departure.addingTimeInterval(-60 * 60),
            departure: departure,
            arrival: arrival,
            departureTimeZoneID: "America/Los_Angeles",
            arrivalTimeZoneID: "America/New_York"
        )
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        for deviceTimeZoneID in ["Asia/Seoul", "Pacific/Honolulu"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: deviceTimeZoneID))
            let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
                from: snapshot,
                nowUTC: departure.addingTimeInterval(-1)
            ))
            XCTAssertEqual(presentation.departureTime?.local, "MAR 08 03:30")
            XCTAssertEqual(presentation.arrivalTime?.local, "MAR 08 08:30")
            XCTAssertEqual(presentation.departureTime?.utc, "MAR 08 10:30")
            XCTAssertEqual(presentation.arrivalTime?.utc, "MAR 08 12:30")
        }
    }

    func test_internationalDateLineCanShowDifferentLocalCalendarDates() throws {
        let departure = F.date("2026-07-01T16:00:00Z")
        let arrival = F.date("2026-07-02T02:00:00Z")
        let snapshot = singleLegSnapshot(
            report: departure.addingTimeInterval(-60 * 60),
            departure: departure,
            arrival: arrival,
            departureTimeZoneID: "Asia/Seoul",
            arrivalTimeZoneID: "America/Anchorage"
        )
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: snapshot,
            nowUTC: departure.addingTimeInterval(-1)
        ))

        XCTAssertEqual(presentation.departureTime?.local, "JUL 02 01:00")
        XCTAssertEqual(presentation.arrivalTime?.local, "JUL 01 18:00")
        XCTAssertEqual(presentation.departureTime?.utc, "JUL 01 16:00")
        XCTAssertEqual(presentation.arrivalTime?.utc, "JUL 02 02:00")
    }

    func test_layoverUsesArrivalToFollowingDepartureAbsoluteDurationAndArrivalAirport() {
        XCTAssertTrue(ScheduledLayoverPolicy.isLayover(
            arrivalUTC: F.firstArrival,
            nextDepartureUTC: F.secondDeparture,
            sameTrip: true,
            arrivalAirportIATA: "SDF",
            nextDepartureAirportIATA: "SDF"
        ))
        XCTAssertEqual(
            ScheduledLayoverPolicy.durationMinutes(
                arrivalUTC: F.firstArrival,
                nextDepartureUTC: F.secondDeparture
            ),
            180
        )
        XCTAssertEqual(F.firstLeg.arrivalAirportIATA, "SDF")
        XCTAssertEqual(HomeWidgetDomain.layoverDurationText(minutes: 18 * 60 + 25), "18h 25m")
    }

    func test_ordinaryConnectionAndAirportMismatchAreNotLayovers() {
        XCTAssertFalse(ScheduledLayoverPolicy.isLayover(
            arrivalUTC: F.firstArrival,
            nextDepartureUTC: F.firstArrival.addingTimeInterval(179 * 60),
            sameTrip: true,
            arrivalAirportIATA: "SDF",
            nextDepartureAirportIATA: "SDF"
        ))
        XCTAssertFalse(ScheduledLayoverPolicy.isLayover(
            arrivalUTC: F.firstArrival,
            nextDepartureUTC: F.secondDeparture,
            sameTrip: true,
            arrivalAirportIATA: "SDF",
            nextDepartureAirportIATA: "CVG"
        ))
    }

    func test_nearestArrivalForecastMapsSymbolTemperatureAndDestination() throws {
        let hours = [
            HomeWidgetWeatherHour(
                date: F.firstArrival.addingTimeInterval(-55 * 60),
                temperatureCelsius: 20.1,
                symbolName: "cloud"
            ),
            HomeWidgetWeatherHour(
                date: F.firstArrival.addingTimeInterval(5 * 60),
                temperatureCelsius: 25.6,
                symbolName: "cloud.sun.fill"
            )
        ]
        let weather = try XCTUnwrap(HomeWidgetDomain.nearestWeather(
            to: F.firstArrival,
            destinationAirportIATA: "SDF",
            hours: hours
        ))

        XCTAssertEqual(weather.destinationAirportIATA, "SDF")
        XCTAssertEqual(weather.forecastDateUTC, hours[1].date)
        XCTAssertEqual(weather.symbolName, "cloud.sun.fill")
        XCTAssertEqual(weather.temperatureCelsius, 25.6)
        XCTAssertEqual(weather.temperatureText, "26°C")
    }

    func test_unavailableWeatherNeverRemovesOperationalPresentation() throws {
        XCTAssertNil(HomeWidgetDomain.nearestWeather(
            to: F.firstArrival,
            destinationAirportIATA: "SDF",
            hours: []
        ))
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: F.snapshot,
            nowUTC: F.report
        ))
        XCTAssertEqual(presentation.flightNumber, "5X123")
        XCTAssertEqual(presentation.arrivalAirportIATA, "SDF")
    }

    func test_weatherEnrichmentIsBoundedToCurrentEntryAndLaterEntriesRemainUsable() async throws {
        let points = HomeWidgetDomain.timeline(
            from: F.snapshot,
            nowUTC: F.report
        )
        let counter = HomeWidgetWeatherEnrichmentCounter()

        let enriched: [HomeWidgetEnrichedTimelinePoint<String>] =
            await HomeWidgetTimelineEnrichmentPolicy.enrich(
                points: points,
                allowsWeather: true
            ) { presentation in
                await counter.recordAndReturn(presentation?.flightNumber)
            }

        let callCount = await counter.value()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(HomeWidgetTimelineEnrichmentPolicy.maximumWeatherEnrichmentCount, 1)
        XCTAssertEqual(enriched.count, points.count)
        XCTAssertEqual(enriched.first?.enrichment, "5X123")
        XCTAssertTrue(enriched.dropFirst().allSatisfy { $0.enrichment == nil })
        let laterFlight = try XCTUnwrap(
            enriched.dropFirst().first(where: { $0.point.presentation?.flightNumber != nil })
        )
        XCTAssertNotNil(laterFlight.point.presentation?.departureTime)
        XCTAssertNotNil(laterFlight.point.presentation?.arrivalTime)
    }

    func test_weatherFailureStillReturnsEveryUsableTimelinePoint() async {
        let points = HomeWidgetDomain.timeline(
            from: F.snapshot,
            nowUTC: F.report
        )
        let counter = HomeWidgetWeatherEnrichmentCounter()

        let enriched: [HomeWidgetEnrichedTimelinePoint<String>] =
            await HomeWidgetTimelineEnrichmentPolicy.enrich(
                points: points,
                allowsWeather: true
            ) { _ in
                await counter.recordAndReturn(nil)
            }

        let callCount = await counter.value()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(enriched.count, points.count)
        XCTAssertEqual(
            enriched.map(\.point.presentation),
            points.map(\.presentation)
        )
        XCTAssertTrue(enriched.allSatisfy { $0.enrichment == nil })
    }

    func test_disallowedWeatherPerformsNoEnrichmentAndKeepsEveryPoint() async {
        let points = HomeWidgetDomain.timeline(from: F.snapshot, nowUTC: F.report)
        let counter = HomeWidgetWeatherEnrichmentCounter()

        let enriched: [HomeWidgetEnrichedTimelinePoint<String>] =
            await HomeWidgetTimelineEnrichmentPolicy.enrich(
                points: points,
                allowsWeather: false
            ) { _ in
                await counter.recordAndReturn("unexpected")
            }

        let callCount = await counter.value()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(enriched.count, points.count)
        XCTAssertTrue(enriched.allSatisfy { $0.enrichment == nil })
    }

    func test_arrivalOutsideHourlyForecastHorizonIsUnavailableWithoutARequest() {
        let now = F.report
        XCTAssertTrue(HomeWidgetDomain.canRequestArrivalForecast(
            arrivalUTC: now.addingTimeInterval(9 * 24 * 60 * 60),
            nowUTC: now
        ))
        XCTAssertFalse(HomeWidgetDomain.canRequestArrivalForecast(
            arrivalUTC: now.addingTimeInterval(11 * 24 * 60 * 60),
            nowUTC: now
        ))
    }

    func test_weatherCoordinateComesFromArrivalAirportMetadata() throws {
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: F.snapshot,
            nowUTC: F.report
        ))

        XCTAssertEqual(presentation.arrivalAirportIATA, "SDF")
        XCTAssertEqual(presentation.arrivalCoordinate, F.sdfCoordinate)
        XCTAssertEqual(
            IATATimeZoneResolver.shared.coordinate("SDF"),
            HomeWidgetAirportCoordinate(latitude: 38.1706, longitude: -85.735076)
        )
    }

    func test_scheduleBuilderAttachesCanonicalLayoverAndArrivalCoordinates() throws {
        let first = sourceLeg(
            sequence: 1,
            flight: "5X123",
            departureAirport: "ANC",
            arrivalAirport: "SDF",
            departure: F.firstDeparture,
            arrival: F.firstArrival
        )
        let second = sourceLeg(
            sequence: 2,
            flight: "5X456",
            departureAirport: "SDF",
            arrivalAirport: "NRT",
            departure: F.secondDeparture,
            arrival: F.secondArrival
        )
        let schedule = PayPeriodSchedule(
            id: "PP26-08",
            label: "PP26-08",
            tripCount: 1,
            legCount: 2,
            openTimeCount: 0,
            updatedAt: F.report,
            legs: [first, second],
            openTimeTrips: []
        )
        let snapshot = try XCTUnwrap(HomeWidgetScheduleBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            nowUTC: F.report.addingTimeInterval(-24 * 60 * 60)
        ))
        let projectedFirst = try XCTUnwrap(snapshot.trips.first?.legs.first)

        XCTAssertEqual(projectedFirst.arrivalAirportIATA, "SDF")
        XCTAssertEqual(projectedFirst.layoverAfterMinutes, 180)
        XCTAssertEqual(
            projectedFirst.arrivalCoordinate,
            IATATimeZoneResolver.shared.coordinate("SDF")
        )
        XCTAssertNotEqual(
            projectedFirst.arrivalCoordinate,
            IATATimeZoneResolver.shared.coordinate("ANC")
        )
    }

    func test_builderDerivesReleaseFromLastValidProjectedLegWhenSourceFinalIsMalformed() throws {
        let first = sourceLeg(
            sequence: 1,
            flight: "5X123",
            departureAirport: "ANC",
            arrivalAirport: "SDF",
            departure: F.firstDeparture,
            arrival: F.firstArrival
        )
        var malformedFinal = sourceLeg(
            sequence: 2,
            flight: "5X456",
            departureAirport: "SDF",
            arrivalAirport: "NRT",
            departure: F.secondDeparture,
            arrival: F.secondArrival
        )
        malformedFinal.arrUTC = "not-a-date"
        malformedFinal.staUTC = "not-a-date"
        let schedule = sourceSchedule(legs: [first, malformedFinal])

        let snapshot = try XCTUnwrap(HomeWidgetScheduleBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            nowUTC: F.report.addingTimeInterval(-24 * 60 * 60)
        ))
        let trip = try XCTUnwrap(snapshot.trips.first)

        XCTAssertEqual(trip.legs.map(\.id), [first.id.uuidString])
        XCTAssertEqual(
            trip.releaseBoundaryUTC,
            F.firstArrival.addingTimeInterval(HomeWidgetDomain.postFinalArrivalInterval)
        )
    }

    func test_builderUsesFinalSourceArrivalWhenFinalLegTimezoneIsUnresolved() throws {
        let first = sourceLeg(
            sequence: 1,
            flight: "5X123",
            departureAirport: "ANC",
            arrivalAirport: "SDF",
            departure: F.firstDeparture,
            arrival: F.firstArrival
        )
        let final = sourceLeg(
            sequence: 2,
            flight: "5X456",
            departureAirport: "SDF",
            arrivalAirport: "XYZ",
            departure: F.secondDeparture,
            arrival: F.finalArrival
        )
        let snapshot = try XCTUnwrap(HomeWidgetScheduleBuilder.build(
            schedules: [sourceSchedule(legs: [first, final])],
            domicileAirportCode: "ANC",
            nowUTC: F.report.addingTimeInterval(-24 * 60 * 60),
            tzResolver: ANCSDFIATATimeZoneResolver()
        ))
        let trip = try XCTUnwrap(snapshot.trips.first)

        XCTAssertEqual(trip.legs.map(\.id), [first.id.uuidString])
        XCTAssertEqual(
            trip.releaseBoundaryUTC,
            F.finalArrival.addingTimeInterval(HomeWidgetDomain.postFinalArrivalInterval)
        )

        let selectionSnapshot = HomeWidgetScheduleSnapshot(
            updatedAtUTC: snapshot.updatedAtUTC,
            trips: snapshot.trips + [F.nextTrip]
        )
        let atProjectedRelease = try XCTUnwrap(HomeWidgetDomain.selection(
            from: selectionSnapshot,
            nowUTC: F.firstArrival.addingTimeInterval(HomeWidgetDomain.postFinalArrivalInterval)
        ))
        let atSourceRelease = try XCTUnwrap(HomeWidgetDomain.selection(
            from: selectionSnapshot,
            nowUTC: F.finalArrival.addingTimeInterval(HomeWidgetDomain.postFinalArrivalInterval)
        ))

        XCTAssertEqual(atProjectedRelease.trip.tripID, "A70639")
        XCTAssertEqual(atProjectedRelease.state, .activeTripFinalLeg)
        XCTAssertNotEqual(atProjectedRelease.trip.tripID, F.nextTrip.tripID)
        XCTAssertEqual(atSourceRelease.trip.tripID, F.nextTrip.tripID)
        XCTAssertEqual(atSourceRelease.state, .nextTripReport)
    }

    func test_builderNormalTripReleaseUsesFinalScheduledArrival() throws {
        let first = sourceLeg(
            sequence: 1,
            flight: "5X123",
            departureAirport: "ANC",
            arrivalAirport: "SDF",
            departure: F.firstDeparture,
            arrival: F.firstArrival
        )
        let final = sourceLeg(
            sequence: 2,
            flight: "5X456",
            departureAirport: "SDF",
            arrivalAirport: "NRT",
            departure: F.secondDeparture,
            arrival: F.finalArrival
        )
        let snapshot = try XCTUnwrap(HomeWidgetScheduleBuilder.build(
            schedules: [sourceSchedule(legs: [first, final])],
            domicileAirportCode: "ANC",
            nowUTC: F.report.addingTimeInterval(-24 * 60 * 60)
        ))

        XCTAssertEqual(
            snapshot.trips.first?.releaseBoundaryUTC,
            F.finalArrival.addingTimeInterval(HomeWidgetDomain.postFinalArrivalInterval)
        )
    }

    func test_builderExcludesTripWhenEveryFlightFailsTimezoneResolution() {
        let schedule = sourceSchedule(legs: [
            sourceLeg(
                sequence: 1,
                flight: "5X123",
                departureAirport: "ANC",
                arrivalAirport: "SDF",
                departure: F.firstDeparture,
                arrival: F.firstArrival
            )
        ])

        XCTAssertNil(HomeWidgetScheduleBuilder.build(
            schedules: [schedule],
            domicileAirportCode: "ANC",
            nowUTC: F.report.addingTimeInterval(-24 * 60 * 60),
            tzResolver: ANCOnlyIATATimeZoneResolver()
        ))
    }

    func test_nilReleaseTripIsNeverActiveAndDoesNotSuppressLaterValidReport() throws {
        let malformedTrip = HomeWidgetTrip(
            id: "malformed",
            tripID: "BAD",
            reportTimeUTC: F.report.addingTimeInterval(-60 * 60),
            reportTimeZoneID: "America/Anchorage",
            releaseBoundaryUTC: nil,
            legs: [F.firstLeg]
        )
        let snapshot = HomeWidgetScheduleSnapshot(
            updatedAtUTC: F.report,
            trips: [malformedTrip, F.nextTrip]
        )
        let selection = try XCTUnwrap(HomeWidgetDomain.selection(
            from: snapshot,
            nowUTC: F.report
        ))

        XCTAssertEqual(selection.state, .nextTripReport)
        XCTAssertEqual(selection.trip.tripID, F.nextTrip.tripID)
        XCTAssertNotEqual(selection.trip.tripID, malformedTrip.tripID)
    }

    func test_emptyProjectedTripIsIneligibleForDomainSelection() throws {
        let emptyTrip = HomeWidgetTrip(
            id: "empty",
            tripID: "EMPTY",
            reportTimeUTC: F.report.addingTimeInterval(-60 * 60),
            reportTimeZoneID: "America/Anchorage",
            releaseBoundaryUTC: F.release,
            legs: []
        )
        let snapshot = HomeWidgetScheduleSnapshot(
            updatedAtUTC: F.report,
            trips: [emptyTrip, F.nextTrip]
        )
        let selection = try XCTUnwrap(HomeWidgetDomain.selection(from: snapshot, nowUTC: F.report))

        XCTAssertEqual(selection.trip.tripID, F.nextTrip.tripID)
        XCTAssertEqual(selection.state, .nextTripReport)
    }

    func test_familyPresentationContractsConsumeOneSharedPresentation() throws {
        let presentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: F.snapshot,
            nowUTC: F.report
        ))

        XCTAssertNotNil(presentation.departureTime)
        XCTAssertNotNil(presentation.arrivalTime)
        XCTAssertFalse(HomeWidgetFamily.small.showsArrivalTime)
        XCTAssertFalse(HomeWidgetFamily.small.showsUTCTime)
        XCTAssertFalse(HomeWidgetFamily.small.showsDestinationWeather)
        XCTAssertTrue(HomeWidgetFamily.medium.showsArrivalTime)
        XCTAssertTrue(HomeWidgetFamily.medium.showsUTCTime)
        XCTAssertTrue(HomeWidgetFamily.medium.showsDestinationWeather)
        XCTAssertTrue(HomeWidgetFamily.medium.showsLayover)
        XCTAssertEqual(presentation.layoverAfterMinutes, 180)
    }

    func test_timelineIncludesImmediateReportEverySTDAndFinalRelease() {
        let now = F.report.addingTimeInterval(-60 * 60)
        let timeline = HomeWidgetDomain.timeline(from: F.snapshot, nowUTC: now)

        XCTAssertEqual(timeline.first?.presentation?.state, .nextTripReport)
        XCTAssertEqual(
            timeline.map(\.date),
            [
                now,
                F.report,
                F.firstDeparture,
                F.secondDeparture,
                F.finalDeparture,
                F.release,
                F.nextReport,
                F.nextDeparture,
                F.nextRelease
            ]
        )
        XCTAssertEqual(
            timeline.map { $0.presentation?.state },
            [
                .nextTripReport,
                .activeTripNextFlight,
                .activeTripNextFlight,
                .activeTripNextFlight,
                .activeTripFinalLeg,
                .nextTripReport,
                .activeTripNextFlight,
                .activeTripFinalLeg,
                nil
            ]
        )
    }

    func test_timelineIsBoundedForManyTripsAndLegs() {
        let now = F.report
        let legs = (1...40).map { index in
            let departure = now.addingTimeInterval(TimeInterval(index * 60 * 60))
            return F.leg(
                id: "many-\(index)",
                flightNumber: "5X\(index)",
                departureAirport: "ANC",
                arrivalAirport: "SDF",
                departure: departure,
                arrival: departure.addingTimeInterval(30 * 60),
                departureTimeZoneID: "America/Anchorage",
                arrivalTimeZoneID: "America/Kentucky/Louisville"
            )
        }
        let trip = HomeWidgetTrip(
            id: "many",
            tripID: "MANY",
            reportTimeUTC: now.addingTimeInterval(-60),
            reportTimeZoneID: "America/Anchorage",
            releaseBoundaryUTC: now.addingTimeInterval(41 * 60 * 60),
            legs: legs
        )
        let timeline = HomeWidgetDomain.timeline(
            from: .init(updatedAtUTC: now, trips: [trip]),
            nowUTC: now
        )

        XCTAssertEqual(timeline.count, HomeWidgetDomain.maximumTimelineEntryCount)
        XCTAssertTrue(timeline.allSatisfy {
            $0.date <= now.addingTimeInterval(HomeWidgetDomain.timelineHorizon)
        })
        XCTAssertEqual(timeline.first?.presentation?.flightNumber, "5X1")
        XCTAssertEqual(timeline.last?.presentation?.flightNumber, "5X12")
    }

    func test_legacyWindowDistanceDoesNotHideCurrentReportWithinBoundedTimeline() {
        let now = F.report.addingTimeInterval(-40 * 60 * 60)
        let timeline = HomeWidgetDomain.timeline(from: F.snapshot, nowUTC: now)

        XCTAssertEqual(timeline.first?.presentation?.state, .nextTripReport)
        XCTAssertEqual(
            timeline.map(\.date),
            [now, F.report, F.firstDeparture, F.secondDeparture]
        )
    }

    private func singleLegSnapshot(
        report: Date,
        departure: Date,
        arrival: Date,
        departureTimeZoneID: String,
        arrivalTimeZoneID: String
    ) -> HomeWidgetScheduleSnapshot {
        let leg = F.leg(
            id: "timezone",
            flightNumber: "5X1",
            departureAirport: "DEP",
            arrivalAirport: "ARR",
            departure: departure,
            arrival: arrival,
            departureTimeZoneID: departureTimeZoneID,
            arrivalTimeZoneID: arrivalTimeZoneID
        )
        return HomeWidgetScheduleSnapshot(
            updatedAtUTC: report,
            trips: [
                HomeWidgetTrip(
                    id: "timezone-trip",
                    tripID: "TZ1",
                    reportTimeUTC: report,
                    reportTimeZoneID: departureTimeZoneID,
                    releaseBoundaryUTC: arrival.addingTimeInterval(30 * 60),
                    legs: [leg]
                )
            ]
        )
    }

    private func sourceLeg(
        sequence: Int,
        flight: String,
        departureAirport: String,
        arrivalAirport: String,
        departure: Date,
        arrival: Date
    ) -> TripLeg {
        let formatter = ISO8601DateFormatter()
        return TripLeg(
            payPeriod: "PP26-08",
            pairing: "A70639",
            leg: sequence,
            flight: flight,
            depAirport: departureAirport,
            depLocal: "00:00",
            arrAirport: arrivalAirport,
            arrLocal: "00:00",
            depUTC: formatter.string(from: departure),
            arrUTC: formatter.string(from: arrival),
            status: "-",
            block: "2:00",
            stdUTC: formatter.string(from: departure),
            staUTC: formatter.string(from: arrival)
        )
    }

    private func sourceSchedule(legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "PP26-08",
            label: "PP26-08",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: F.report,
            legs: legs,
            openTimeTrips: []
        )
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
        XCTAssertEqual(output.presentation?.prefix, "Dep in")
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

#if false // RETIRED: scenario matrix existed only to exercise Live Activity/SpringBoard states.
    func test_debugRuntimeScenariosGenerateExpectedPlanningRelationshipsAndProductionStates() throws {
        let variants: [(
            FlightCountdownDebugScenario,
            TimeInterval,
            FlightOperationalState,
            FlightPresentationVisibility
        )] = [
            (.preReport, 5 * 60 * 60, .preReport, .liveActivity),
            (.homeWidgetPreReport, 9 * 60 * 60, .preReport, .widget),
            (.preDeparture, 30 * 60, .preDeparture, .liveActivity),
            (.departureTimePassed0, 0, .departureTimePassed, .liveActivity),
            (.departureTimePassed1, -60, .departureTimePassed, .liveActivity),
            (.departureTimePassed60, -(60 * 60), .departureTimePassed, .liveActivity),
            (.stalePreDeparture22, -(22 * 60), .preDeparture, .liveActivity),
            (.expired61, -(61 * 60), .departureTimePassed, .liveActivity),
            (.longFlightNumber, 30 * 60, .preDeparture, .liveActivity),
            (.commercialDeadhead, 30 * 60, .preDeparture, .liveActivity)
        ]

        for (scenario, expectedDepartureOffset, expectedState, expectedVisibility) in variants {
            let schedules = AppViewModel.debugFlightCountdownInteractiveSchedules(
                nowUTC: canonicalNowUTC,
                scenario: scenario
            )
            let output = try XCTUnwrap(OperationalStateBuilder.build(
                schedules: schedules,
                domicileAirportCode: "ANC",
                nowUTC: scenario.evaluationDate(relativeTo: canonicalNowUTC)
            ))

            XCTAssertEqual(output.leg.id, AppViewModel.debugFlightCountdownFirstLegID.uuidString)
            XCTAssertEqual(
                output.leg.plannedDepartureUTC.timeIntervalSince(canonicalNowUTC),
                expectedDepartureOffset,
                accuracy: 0.001,
                "Unexpected STD relationship for \(scenario.rawValue)"
            )
            let reportTimeUTC = try XCTUnwrap(output.leg.reportTimeUTC)
            XCTAssertEqual(
                reportTimeUTC.timeIntervalSince(output.leg.plannedDepartureUTC),
                -(90 * 60),
                accuracy: 0.001,
                "Production report policy was bypassed for \(scenario.rawValue)"
            )
            XCTAssertEqual(output.state, expectedState)
            XCTAssertEqual(output.presentation.state, expectedState)
            XCTAssertEqual(output.visibility, expectedVisibility)
            if scenario == .longFlightNumber {
                XCTAssertEqual(output.leg.flightNumber, "LONGFLIGHT12345")
            }
            if scenario == .commercialDeadhead {
                XCTAssertEqual(output.leg.flightNumber, "JL809")
                XCTAssertTrue(output.leg.isDeadhead)
            }
        }
    }

    func test_debugStaleFixtureMovesOnlyAlreadyPastLifecycleBoundaryFifteenSecondsForward() throws {
        for scenario in [
            FlightCountdownDebugScenario.stalePreDeparture22,
            .expired61
        ] {
            let schedules = AppViewModel.debugFlightCountdownInteractiveSchedules(
                nowUTC: canonicalNowUTC,
                scenario: scenario
            )
            let output = try XCTUnwrap(OperationalStateBuilder.build(
                schedules: schedules,
                domicileAirportCode: "ANC",
                nowUTC: scenario.evaluationDate(relativeTo: canonicalNowUTC)
            ))
            let snapshot = FlightCountdownSnapshot(
                updatedAtUTC: canonicalNowUTC,
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
                departureDateText: "",
                departureTimeText: "",
                arrivalDateText: "",
                arrivalTimeText: ""
            )

            XCTAssertEqual(
                FlightCountdownActivityLifecyclePolicy.staleDate(for: snapshot),
                canonicalNowUTC.addingTimeInterval(15)
            )
        }
    }
#endif

    func test_homeWidgetRuntimeFixtureAndSettingsUIAreGuardedByDEBUGCompilation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previewSource = try String(contentsOf: repositoryRoot
            .appendingPathComponent("TripDataHub/ViewModels/AppViewModel+PreviewData.swift"))
        let settingsSource = try String(contentsOf: repositoryRoot
            .appendingPathComponent("TripDataHub/Views/SettingsTabView.swift"))

        XCTAssertTrue(previewSource.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(previewSource.hasSuffix("#endif\n"))
        XCTAssertEqual(AppViewModel.debugFlightCountdownFixtureID, "A79999R")
        XCTAssertEqual(AppViewModel.debugFlightCountdownFixtureID.count, 7)
        XCTAssertFalse(settingsSource.contains("FlightCountdownDebugScenario"))
        XCTAssertFalse(settingsSource.contains("Countdown State"))
        assertToken("Start Home Widget Fixture", isInsideDebugBlockIn: settingsSource)
        assertToken("startDebugFlightCountdownFixture", isInsideDebugBlockIn: settingsSource)
    }

    func test_homeWidgetPreTripLayoutHasCompactAccessibilityFallbacks() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
        ))
        let compact = source.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )

        XCTAssertTrue(compact.contains("HomeWidgetSmallReportView(presentation:presentation)"))
        XCTAssertTrue(compact.contains("HomeWidgetRouteTimeGrid(presentation:presentation).dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertTrue(compact.contains("Text(\"TRIPINPROGRESS\").font(.caption2.weight(.bold)).foregroundStyle(palette.secondaryText).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertTrue(compact.contains("timeRow(departure:presentation.departureTime?.local,arrival:presentation.arrivalTime?.local,marker:\"L\")"))
        XCTAssertTrue(compact.contains("timeRow(departure:presentation.departureTime?.utc,arrival:presentation.arrivalTime?.utc,marker:\"Z\")"))
        XCTAssertTrue(compact.contains("HomeWidgetRouteTimeGrid(presentation:presentation)"))
        XCTAssertTrue(compact.contains(".dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertTrue(compact.contains("weather:weather,attribution:attribution).dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertTrue(compact.contains("ViewThatFits(in:.vertical)"))
        XCTAssertTrue(compact.contains("alignment:.topLeading"))
        XCTAssertFalse(compact.contains(".environment(\\.colorScheme,.dark)"))
        XCTAssertTrue(compact.contains("HomeWidgetPalette(colorScheme:colorScheme)"))
        XCTAssertTrue(compact.contains("attribution.combinedMarkDarkData:attribution.combinedMarkLightData"))
    }

    func test_homeWidgetPass2ScenariosUseProductionDomainAtExactBoundaries() throws {
        let anchorUTC = date("2026-09-01T00:00:00Z")
        let variants: [(
            HomeWidgetDebugAcceptanceScenario,
            HomeWidgetOperationalState,
            String?,
            String
        )] = [
            (.preTrip, .nextTripReport, nil, "A79999R"),
            (.activeFirst, .activeTripNextFlight, AppViewModel.debugFlightCountdownSecondLegID.uuidString, "A79999R"),
            (.beforeFirstSTD, .activeTripNextFlight, AppViewModel.debugFlightCountdownSecondLegID.uuidString, "A79999R"),
            (.atFirstSTD, .activeTripNextFlight, AppViewModel.debugHomeWidgetFinalLegID.uuidString, "A79999R"),
            (.afterFirstSTD, .activeTripNextFlight, AppViewModel.debugHomeWidgetFinalLegID.uuidString, "A79999R"),
            (.finalLeg, .activeTripFinalLeg, AppViewModel.debugHomeWidgetFinalLegID.uuidString, "A79999R"),
            (.beforeRelease, .activeTripFinalLeg, AppViewModel.debugHomeWidgetFinalLegID.uuidString, "A79999R"),
            (.atRelease, .nextTripReport, nil, "12165")
        ]

        for (scenario, expectedState, expectedLegID, expectedTripID) in variants {
            let fixture = AppViewModel.debugHomeWidgetAcceptanceFixture(
                scenario: scenario,
                anchorUTC: anchorUTC
            )
            let snapshot = try XCTUnwrap(HomeWidgetScheduleBuilder.build(
                schedules: fixture.schedules,
                domicileAirportCode: "ANC",
                nowUTC: fixture.effectiveNowUTC
            ))
            let selection = try XCTUnwrap(HomeWidgetDomain.selection(
                from: snapshot,
                nowUTC: fixture.effectiveNowUTC
            ))

            XCTAssertEqual(selection.state, expectedState, scenario.rawValue)
            XCTAssertEqual(selection.displayedLeg?.id, expectedLegID, scenario.rawValue)
            XCTAssertEqual(selection.trip.tripID, expectedTripID, scenario.rawValue)
        }

        let activeFixture = AppViewModel.debugHomeWidgetAcceptanceFixture(
            scenario: .activeFirst,
            anchorUTC: anchorUTC
        )
        let activeSnapshot = try XCTUnwrap(HomeWidgetScheduleBuilder.build(
            schedules: activeFixture.schedules,
            domicileAirportCode: "ANC",
            nowUTC: activeFixture.effectiveNowUTC
        ))
        let activePresentation = try XCTUnwrap(HomeWidgetDomain.presentation(
            from: activeSnapshot,
            nowUTC: activeFixture.effectiveNowUTC
        ))
        XCTAssertEqual(activePresentation.flightNumber, "5X108")
        XCTAssertEqual(activePresentation.departureAirportIATA, "SDF")
        XCTAssertEqual(activePresentation.arrivalAirportIATA, "NRT")
        XCTAssertEqual(activePresentation.layoverAfterMinutes, 38 * 60 + 25)
    }

    func test_homeWidgetPass2DebugClockAndLaunchHookRemainDEBUGOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedSource = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TripDataHub/Models/FlightCountdownSharedModels.swift"
        ))
        let previewSource = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TripDataHub/ViewModels/AppViewModel+PreviewData.swift"
        ))
        let widgetSource = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift"
        ))

        assertToken("enum HomeWidgetDebugClockStore", isInsideDebugBlockIn: sharedSource)
        XCTAssertTrue(previewSource.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(previewSource.contains("UITEST_HOME_WIDGET_SCENARIO"))
        XCTAssertTrue(widgetSource.contains("HomeWidgetDebugClockStore.load() ?? wallNowUTC"))
        XCTAssertTrue(widgetSource.contains(
            "HomeWidgetDomain.presentation(from: snapshot, nowUTC: now)"
        ))
    }

    func test_T45_fixtureUsesProductionOperationalStateBuilder() throws {
        let output = try XCTUnwrap(buildCanonicalOutput(nowUTC: canonicalNowUTC))

        XCTAssertEqual(output.leg.id, AppViewModel.debugFlightCountdownFirstLegID.uuidString)
        XCTAssertEqual(output.state, .preReport)
        XCTAssertEqual(output.visibility, .hidden)
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
            ("2026-08-16T18:40:00Z", .hidden)
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
        XCTAssertEqual(uploadCountsAfterStart, .init(shared: 0, snapshot: 0))
        XCTAssertEqual(deviceUploadsAfterStart, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let persistedLegIDsAfterStart = await snapshotSpy.persistedHomeWidgetFirstLegIDs()
        XCTAssertEqual(
            persistedLegIDsAfterStart.last,
            AppViewModel.debugFlightCountdownFirstLegID.uuidString
        )

        await viewModel.refreshFlightCountdownPresentation(
            mode: .reconcile,
            nowUTC: canonicalNowUTC.addingTimeInterval(10 * 60)
        )
        let persistedLegIDsAfterRefresh = await snapshotSpy.persistedHomeWidgetFirstLegIDs()
        XCTAssertEqual(
            persistedLegIDsAfterRefresh.last,
            AppViewModel.debugFlightCountdownFirstLegID.uuidString
        )

        await viewModel.stopDebugFlightCountdownFixture(nowUTC: canonicalNowUTC)

        let notificationInvalidationsAfterStop = await notificationSpy.invalidationCount()
        let uploadCountsAfterStop = await friendUploadSpy.counts()
        let deviceUploadsAfterStop = await deviceUploadSpy.uploadCount()
        let persistedLegIDsAfterStop = await snapshotSpy.persistedHomeWidgetFirstLegIDs()
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

    private func assertToken(
        _ token: String,
        isInsideDebugBlockIn source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let tokenRange = source.range(of: token) else {
            XCTFail("Missing source token: \(token)", file: file, line: line)
            return
        }
        let prefix = source[..<tokenRange.lowerBound]
        let debugStart = prefix.range(of: "#if DEBUG", options: .backwards)
        let debugEndBeforeToken = prefix.range(of: "#endif", options: .backwards)
        XCTAssertNotNil(debugStart, file: file, line: line)
        if let debugStart, let debugEndBeforeToken {
            XCTAssertGreaterThan(
                source.distance(from: source.startIndex, to: debugStart.lowerBound),
                source.distance(from: source.startIndex, to: debugEndBeforeToken.lowerBound),
                "\(token) is not inside the active DEBUG block",
                file: file,
                line: line
            )
        }
        let suffix = source[tokenRange.upperBound...]
        XCTAssertNotNil(suffix.range(of: "#endif"), file: file, line: line)
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
