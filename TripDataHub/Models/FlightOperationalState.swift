import Foundation

/// Evidence-based operational state for one flight leg.
///
/// Presentation windows are deliberately absent from this API. The evaluator accepts only
/// planning instants, observed Actual instants, an optional trip report instant, and `now`.
enum FlightOperationalState: String, Codable, Hashable, CaseIterable {
    case preReport
    case postReportPreDeparture
    case scheduledDeparturePassed
    case inFlight
    case scheduledArrivalPassed
    case completed
    case stale

    /// The order of these branches is part of INV-018. In particular, the STA and STA+1h checks
    /// must precede the ATD branch so arrival-passed and stale remain reachable when ATD is known.
    static func evaluate(
        plannedDepartureUTC: Date,
        plannedArrivalUTC: Date,
        atdUTC: Date?,
        ataUTC: Date?,
        reportTimeUTC: Date?,
        nowUTC: Date
    ) -> FlightOperationalState {
        if ataUTC != nil {
            return .completed
        }
        if nowUTC >= plannedArrivalUTC.addingTimeInterval(60 * 60) {
            return .stale
        }
        if nowUTC >= plannedArrivalUTC {
            return .scheduledArrivalPassed
        }
        if atdUTC != nil, nowUTC < plannedArrivalUTC {
            return .inFlight
        }
        if nowUTC >= plannedDepartureUTC {
            return .scheduledDeparturePassed
        }
        if let reportTimeUTC, nowUTC < reportTimeUTC {
            return .preReport
        }
        return .postReportPreDeparture
    }
}
