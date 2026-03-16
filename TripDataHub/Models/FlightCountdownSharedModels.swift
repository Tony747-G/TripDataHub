import Foundation
#if os(iOS)
import ActivityKit
#endif

enum CountdownPresentationPhase: String, Codable, Hashable {
    case none
    case widget
    case liveCountdown
    case liveDelayed
    case finished
}

struct FlightCountdownSnapshot: Codable, Equatable, Hashable {
    let updatedAtUTC: Date
    let phase: CountdownPresentationPhase
    let legID: String
    let flightNumber: String?
    let isDeadhead: Bool
    let departureAirportIATA: String
    let arrivalAirportIATA: String
    let scheduledDepartureUTC: Date
    let scheduledArrivalUTC: Date
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
}

enum FlightCountdownSharedStore {
    static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    static let widgetSnapshotFileName = "flight_countdown_snapshot.json"

    /// T-12h: widget phase begins
    static let widgetLeadTime: TimeInterval = 12 * 60 * 60
    /// T-6h: live activity phase begins
    static let liveLeadTime: TimeInterval = 6 * 60 * 60
    /// T+6h: live activity ends
    static let delayedTailTime: TimeInterval = 6 * 60 * 60

    /// Single authoritative phase computation shared by the engine and widget extension.
    static func phase(scheduledDepartureUTC: Date, now: Date) -> CountdownPresentationPhase {
        if now < scheduledDepartureUTC.addingTimeInterval(-widgetLeadTime) { return .none }
        if now < scheduledDepartureUTC.addingTimeInterval(-liveLeadTime) { return .widget }
        if now < scheduledDepartureUTC { return .liveCountdown }
        if now < scheduledDepartureUTC.addingTimeInterval(delayedTailTime) { return .liveDelayed }
        return .finished
    }

    /// Formats a duration as "Xh Xm" (e.g. "2h 11m"). Returns "0h 0m" if end is before start.
    static func durationText(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start)) / 60)
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
}

#if os(iOS)
struct FlightCountdownAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let legID: String
        let phase: CountdownPresentationPhase
        let flightNumber: String?
        let isDeadhead: Bool
        let departureAirportIATA: String
        let arrivalAirportIATA: String
        let scheduledDepartureUTC: Date
        let scheduledArrivalUTC: Date
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
