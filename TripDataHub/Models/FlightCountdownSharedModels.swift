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

enum FlightReferenceTimeDisplay: String, Codable, Hashable {
    case lcl
    case utc
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
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
    let referenceText: String?
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
        guard state != .completed, state != .stale else {
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
        let departureTimeZoneID: String
        let arrivalTimeZoneID: String
        let departureDateText: String
        let departureTimeText: String
        let arrivalDateText: String
        let arrivalTimeText: String
        let referenceText: String?
    }

    let activityID: String
}
#endif
