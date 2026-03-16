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
