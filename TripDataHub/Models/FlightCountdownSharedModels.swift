import Foundation
import SwiftUI
#if os(iOS)
import ActivityKit
#endif

enum FlightPresentationVisibility: String, Codable, Hashable {
    case hidden
    case widget
    case liveActivity
}

enum OperationalCountdownDirection: String, Codable, Equatable, Hashable {
    case countingDown
    case countingUp
}

struct OperationalCountdownPresentation: Codable, Equatable, Hashable {
    let state: FlightOperationalState
    let prefix: String
    let direction: OperationalCountdownDirection
    let anchorUTC: Date
    /// Operational selection/lifecycle boundary. This is intentionally not the timer range end.
    let expirationUTC: Date?
    /// Presentation-only upper bound that prevents a retained Activity shell exceeding 60 minutes.
    let timerClampUTC: Date?

    static func make(
        state: FlightOperationalState,
        plannedDepartureUTC: Date,
        reportTimeUTC: Date?
    ) -> OperationalCountdownPresentation? {
        switch state {
        case .preReport:
            guard let reportTimeUTC else { return nil }
            return OperationalCountdownPresentation(
                state: state,
                prefix: "Report in",
                direction: .countingDown,
                anchorUTC: reportTimeUTC,
                expirationUTC: plannedDepartureUTC.addingTimeInterval(FlightOperationalState.expirationInterval),
                timerClampUTC: nil
            )
        case .preDeparture:
            return OperationalCountdownPresentation(
                state: state,
                prefix: "Dep in",
                direction: .countingDown,
                anchorUTC: plannedDepartureUTC,
                expirationUTC: plannedDepartureUTC.addingTimeInterval(FlightOperationalState.expirationInterval),
                timerClampUTC: nil
            )
        case .departureTimePassed:
            return OperationalCountdownPresentation(
                state: state,
                prefix: "Departure time passed",
                direction: .countingUp,
                anchorUTC: plannedDepartureUTC,
                expirationUTC: plannedDepartureUTC.addingTimeInterval(FlightOperationalState.expirationInterval),
                timerClampUTC: FlightCountdownLiveActivityTimerContract.timerClampUTC(
                    plannedDepartureUTC: plannedDepartureUTC
                )
            )
        case .expired:
            return nil
        }
    }
}

struct FlightCountdownSnapshot: Codable, Equatable, Hashable {
    let updatedAtUTC: Date
    let state: FlightOperationalState
    let visibility: FlightPresentationVisibility
    let legID: String
    let flightNumber: String?
    let isDeadhead: Bool
    let departureAirportIATA: String
    let arrivalAirportIATA: String
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let reportTimeUTC: Date?
    let presentation: OperationalCountdownPresentation?
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
}

enum FlightPresentationPolicy {
    /// T-12h: Home Screen Widget presentation begins.
    static let widgetLeadTime: TimeInterval = 12 * 60 * 60
    /// T-6h: Live Activity presentation begins.
    static let liveLeadTime: TimeInterval = 6 * 60 * 60

    /// Presentation windows decide only surface visibility; they never decide operational state.
    static func visibility(
        for state: FlightOperationalState,
        plannedDepartureUTC: Date,
        nowUTC: Date
    ) -> FlightPresentationVisibility {
        guard state != .expired else {
            return .hidden
        }
        if nowUTC < plannedDepartureUTC.addingTimeInterval(-widgetLeadTime) {
            return .hidden
        }
        if nowUTC < plannedDepartureUTC.addingTimeInterval(-liveLeadTime) {
            return .widget
        }
        return .liveActivity
    }

    static func nextVisibilityBoundary(
        plannedDepartureUTC: Date,
        nowUTC: Date
    ) -> Date? {
        let widgetStart = plannedDepartureUTC.addingTimeInterval(-widgetLeadTime)
        if nowUTC < widgetStart {
            return widgetStart
        }
        let liveStart = plannedDepartureUTC.addingTimeInterval(-liveLeadTime)
        if nowUTC < liveStart {
            return liveStart
        }
        return nil
    }
}

enum FlightCountdownRouteLine {
    static func text(
        departureAirport: String,
        departureTime: String,
        arrivalAirport: String,
        arrivalTime: String
    ) -> String {
        "\(departureAirport) \(departureTime) → \(arrivalAirport) \(arrivalTime)"
    }
}

enum FlightCountdownLiveActivityTimerContract {
    static let maxFieldCount = 2
    static let maxPrecision = Duration.seconds(60)
    static let departureElapsedClampInterval: TimeInterval = 60 * 60

    static func countdownInterval(endingAt targetUTC: Date) -> Range<Date> {
        Date.distantPast..<targetUTC
    }

    static func timerClampUTC(plannedDepartureUTC: Date) -> Date {
        plannedDepartureUTC.addingTimeInterval(departureElapsedClampInterval)
    }

    static func countUpInterval(startingAt startUTC: Date, timerClampUTC: Date) -> Range<Date> {
        startUTC..<timerClampUTC
    }
}

struct OperationalCountdownStatusView: View {
    let presentation: OperationalCountdownPresentation
    var showsPrefix = true
    var prioritizesPrefix = false

    var body: some View {
        HStack(spacing: prioritizesPrefix ? 2 : 4) {
            if showsPrefix {
                Text(presentation.prefix)
                    .layoutPriority(prioritizesPrefix ? 1 : 0)
            }
            switch presentation.direction {
            case .countingDown:
                Text(
                    .currentDate,
                    format: .timer(
                        countingDownIn: FlightCountdownLiveActivityTimerContract.countdownInterval(
                            endingAt: presentation.anchorUTC
                        ),
                        showsHours: true,
                        maxFieldCount: FlightCountdownLiveActivityTimerContract.maxFieldCount,
                        maxPrecision: FlightCountdownLiveActivityTimerContract.maxPrecision
                    )
                )
            case .countingUp:
                if let timerClampUTC = presentation.timerClampUTC {
                    Text(
                        .currentDate,
                        format: .timer(
                            countingUpIn: FlightCountdownLiveActivityTimerContract.countUpInterval(
                                startingAt: presentation.anchorUTC,
                                timerClampUTC: timerClampUTC
                            ),
                            showsHours: false,
                            maxFieldCount: 1,
                            maxPrecision: FlightCountdownLiveActivityTimerContract.maxPrecision
                        )
                    )
                }
            }
        }
        .monospacedDigit()
    }
}

enum FlightCountdownExpandedLayoutContract {
    static let rowCount = 4
    static let airplaneSymbolName = "airplane"
    static let airplaneColumnWidth: CGFloat = 20
    static let airplaneColumnHeight: CGFloat = 18
}

struct FlightCountdownExpandedLayoutView<StatusContent: View>: View {
    let flightText: String
    let departureDateText: String
    let departureAirportTimeText: String
    let arrivalDateText: String
    let arrivalAirportTimeText: String
    private let statusContent: () -> StatusContent

    init(
        flightText: String,
        departureDateText: String,
        departureAirportTimeText: String,
        arrivalDateText: String,
        arrivalAirportTimeText: String,
        @ViewBuilder statusContent: @escaping () -> StatusContent
    ) {
        self.flightText = flightText
        self.departureDateText = departureDateText
        self.departureAirportTimeText = departureAirportTimeText
        self.arrivalDateText = arrivalDateText
        self.arrivalAirportTimeText = arrivalAirportTimeText
        self.statusContent = statusContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(flightText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(minHeight: 20, alignment: .leading)

            alignedRow(
                left: departureDateText,
                right: arrivalDateText,
                center: Color.clear
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 20)

            alignedRow(
                left: departureAirportTimeText,
                right: arrivalAirportTimeText,
                center: Image(systemName: FlightCountdownExpandedLayoutContract.airplaneSymbolName)
                    .accessibilityHidden(true)
            )
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .frame(minHeight: 24)

            statusContent()
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(minHeight: 28, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alignedRow<CenterContent: View>(
        left: String,
        right: String,
        center: CenterContent
    ) -> some View {
        HStack(spacing: 8) {
            scalableText(left, alignment: .leading)
            center
                .frame(
                    width: FlightCountdownExpandedLayoutContract.airplaneColumnWidth,
                    height: FlightCountdownExpandedLayoutContract.airplaneColumnHeight
                )
            scalableText(right, alignment: .trailing)
        }
    }

    private func scalableText(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct FlightCountdownRouteLineView: View {
    let departureAirport: String
    let departureTime: String
    let arrivalAirport: String
    let arrivalTime: String

    var body: some View {
        Text(FlightCountdownRouteLine.text(
            departureAirport: departureAirport,
            departureTime: departureTime,
            arrivalAirport: arrivalAirport,
            arrivalTime: arrivalTime
        ))
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .allowsTightening(true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum FlightCountdownSharedStore {
    static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    static let widgetSnapshotFileName = "flight_countdown_snapshot.json"

    static func durationText(from start: Date, to end: Date) -> String? {
        guard end >= start else { return nil }
        let totalMinutes = Int(end.timeIntervalSince(start)) / 60
        return "\(totalMinutes / 60)hr \(String(format: "%02d", totalMinutes % 60))min"
    }
}

#if os(iOS)
struct FlightCountdownAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let legID: String
        let state: FlightOperationalState
        let flightNumber: String?
        let isDeadhead: Bool
        let departureAirportIATA: String
        let arrivalAirportIATA: String
        let plannedDepartureUTC: Date
        let plannedArrivalUTC: Date
        let reportTimeUTC: Date?
        let presentation: OperationalCountdownPresentation?
        let departureTimeZoneID: String
        let arrivalTimeZoneID: String
        let departureDateText: String
        let departureTimeText: String
        let arrivalDateText: String
        let arrivalTimeText: String
    }

    let activityID: String
}
#endif
