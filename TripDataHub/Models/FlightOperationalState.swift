import Foundation

/// Schedule-based real-time operational countdown state for one flight leg.
///
/// Presentation windows and Actual/arrival data are deliberately absent from this API.
enum FlightOperationalState: String, Codable, Hashable, CaseIterable {
    case preReport
    case preDeparture
    case departureTimePassed
    case expired

    static let expirationInterval: TimeInterval = 61 * 60

    /// The order of these branches is part of INV-018.
    static func evaluate(
        plannedDepartureUTC: Date,
        reportTimeUTC: Date?,
        nowUTC: Date
    ) -> FlightOperationalState {
        if nowUTC >= plannedDepartureUTC.addingTimeInterval(expirationInterval) {
            return .expired
        }
        if nowUTC >= plannedDepartureUTC {
            return .departureTimePassed
        }
        if let reportTimeUTC, nowUTC < reportTimeUTC {
            return .preReport
        }
        return .preDeparture
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.preReport.rawValue:
            self = .preReport
        case Self.preDeparture.rawValue, "postReportPreDeparture":
            self = .preDeparture
        case Self.departureTimePassed.rawValue:
            self = .departureTimePassed
        case Self.expired.rawValue:
            self = .expired
        case "scheduledDeparturePassed", "inFlight", "scheduledArrivalPassed", "completed", "stale":
            // Legacy derived state must never survive upgrade as a real-time operational claim.
            self = .expired
        default:
            self = .expired
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
