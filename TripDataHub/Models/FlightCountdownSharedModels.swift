import Foundation
import SwiftUI

enum FlightPresentationVisibility: String, Codable, Hashable {
    case hidden
    case widget
}

struct OperationalCountdownPresentation: Codable, Equatable, Hashable {
    let state: FlightOperationalState
    let prefix: String
    let anchorUTC: Date

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
                anchorUTC: reportTimeUTC
            )
        case .preDeparture:
            return OperationalCountdownPresentation(
                state: state,
                prefix: "Dep in",
                anchorUTC: plannedDepartureUTC
            )
        case .departureTimePassed, .expired:
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
    /// T-6h: Home Screen Widget presentation ends.
    static let widgetEndLeadTime: TimeInterval = 6 * 60 * 60

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
        guard nowUTC < plannedDepartureUTC.addingTimeInterval(-widgetEndLeadTime) else {
            return .hidden
        }
        return .widget
    }

    static func nextVisibilityBoundary(
        plannedDepartureUTC: Date,
        nowUTC: Date
    ) -> Date? {
        let widgetStart = plannedDepartureUTC.addingTimeInterval(-widgetLeadTime)
        if nowUTC < widgetStart {
            return widgetStart
        }
        let widgetEnd = plannedDepartureUTC.addingTimeInterval(-widgetEndLeadTime)
        if nowUTC < widgetEnd {
            return widgetEnd
        }
        return nil
    }
}

enum FlightCountdownTimerContract {
    static let maxFieldCount = 2
    static let maxPrecision = Duration.seconds(60)

    static func countdownInterval(endingAt targetUTC: Date) -> Range<Date> {
        Date.distantPast..<targetUTC
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
            Text(
                .currentDate,
                format: .timer(
                    countingDownIn: FlightCountdownTimerContract.countdownInterval(
                        endingAt: presentation.anchorUTC
                    ),
                    showsHours: true,
                    maxFieldCount: FlightCountdownTimerContract.maxFieldCount,
                    maxPrecision: FlightCountdownTimerContract.maxPrecision
                )
            )
        }
        .monospacedDigit()
    }
}

enum FlightCountdownSharedStore {
    static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    static let widgetSnapshotFileName = "flight_countdown_snapshot.json"
}
