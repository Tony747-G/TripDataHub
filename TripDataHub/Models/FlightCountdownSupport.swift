import Foundation

struct FlightCountdownLeg: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let flightNumber: String?
    let isDeadhead: Bool
    let departureAirportIATA: String
    let arrivalAirportIATA: String
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let reportTimeUTC: Date?
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
}

enum FlightCountdownLegExclusionReason: String, Error, Equatable {
    case missingPlannedDeparture
    case invalidPlannedDeparture
    case missingPlannedArrival
    case invalidPlannedArrival
    case unresolvedDepartureTimeZone
    case unresolvedArrivalTimeZone
}

struct FlightCountdownLegExclusion: Equatable {
    let legID: UUID
    let reason: FlightCountdownLegExclusionReason
}

struct CountdownDisplayStrings: Codable, Equatable, Hashable {
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
    let routeText: String
}

struct CountdownEngineOutput: Codable, Equatable, Hashable {
    let leg: FlightCountdownLeg
    let state: FlightOperationalState
    let visibility: FlightPresentationVisibility
    let presentation: OperationalCountdownPresentation?
    let display: CountdownDisplayStrings
}

struct EvaluatedFlightCountdownLeg: Equatable {
    let leg: FlightCountdownLeg
    let state: FlightOperationalState
}

enum FlightCountdownEngine {
    private static let formatterLock = NSLock()
    private static var dateFormatterCache: [String: DateFormatter] = [:]
    private static var timeFormatterCache: [String: DateFormatter] = [:]

    static func state(for leg: FlightCountdownLeg, nowUTC: Date) -> FlightOperationalState {
        FlightOperationalState.evaluate(
            plannedDepartureUTC: leg.plannedDepartureUTC,
            reportTimeUTC: leg.reportTimeUTC,
            nowUTC: nowUTC
        )
    }

    static func selectRelevantLeg(
        from legs: [FlightCountdownLeg],
        nowUTC: Date
    ) -> EvaluatedFlightCountdownLeg? {
        let evaluated = legs.map { EvaluatedFlightCountdownLeg(leg: $0, state: state(for: $0, nowUTC: nowUTC)) }

        if let departurePassed = latestDeparture(in: evaluated.filter { $0.state == .departureTimePassed }) {
            return departurePassed
        }

        return evaluated
            .filter { $0.state == .preDeparture || $0.state == .preReport }
            .sorted(by: compareUpcoming(_:_:))
            .first
    }

    static func displayStrings(for leg: FlightCountdownLeg) -> CountdownDisplayStrings {
        let departureDateText = localDateText(for: leg.plannedDepartureUTC, timeZoneID: leg.departureTimeZoneID)
        let departureTimeText = localTimeText(for: leg.plannedDepartureUTC, timeZoneID: leg.departureTimeZoneID)
        let arrivalDateText = localDateText(for: leg.plannedArrivalUTC, timeZoneID: leg.arrivalTimeZoneID)
        let arrivalTimeText = localTimeText(for: leg.plannedArrivalUTC, timeZoneID: leg.arrivalTimeZoneID)
        let routeText = "\(leg.departureAirportIATA) \(departureTimeText) -> \(arrivalDateText) \(arrivalTimeText) \(leg.arrivalAirportIATA)"
        return CountdownDisplayStrings(
            departureDateText: departureDateText,
            departureTimeText: departureTimeText,
            arrivalDateText: arrivalDateText,
            arrivalTimeText: arrivalTimeText,
            routeText: routeText
        )
    }

    static func buildCountdownOutput(
        from legs: [FlightCountdownLeg],
        nowUTC: Date
    ) -> CountdownEngineOutput? {
        guard let evaluated = selectRelevantLeg(from: legs, nowUTC: nowUTC) else {
            return nil
        }
        let presentation = OperationalCountdownPresentation.make(
            state: evaluated.state,
            plannedDepartureUTC: evaluated.leg.plannedDepartureUTC,
            reportTimeUTC: evaluated.leg.reportTimeUTC
        )
        let display = displayStrings(for: evaluated.leg)
        let visibility = FlightPresentationPolicy.visibility(
            for: evaluated.state,
            plannedDepartureUTC: evaluated.leg.plannedDepartureUTC,
            nowUTC: nowUTC
        )
        return CountdownEngineOutput(
            leg: evaluated.leg,
            state: evaluated.state,
            visibility: visibility,
            presentation: presentation,
            display: display
        )
    }

    private static func latestDeparture(in legs: [EvaluatedFlightCountdownLeg]) -> EvaluatedFlightCountdownLeg? {
        legs.sorted {
            if $0.leg.plannedDepartureUTC != $1.leg.plannedDepartureUTC {
                return $0.leg.plannedDepartureUTC > $1.leg.plannedDepartureUTC
            }
            return $0.leg.id < $1.leg.id
        }.first
    }

    private static func compareUpcoming(
        _ lhs: EvaluatedFlightCountdownLeg,
        _ rhs: EvaluatedFlightCountdownLeg
    ) -> Bool {
        if lhs.leg.plannedDepartureUTC != rhs.leg.plannedDepartureUTC {
            return lhs.leg.plannedDepartureUTC < rhs.leg.plannedDepartureUTC
        }
        if lhs.leg.plannedArrivalUTC != rhs.leg.plannedArrivalUTC {
            return lhs.leg.plannedArrivalUTC < rhs.leg.plannedArrivalUTC
        }
        return lhs.leg.id < rhs.leg.id
    }

    private static func localDateText(for utcDate: Date, timeZoneID: String) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let existing = dateFormatterCache[timeZoneID] {
            formatter = existing
        } else {
            let newFormatter = DateFormatter()
            newFormatter.calendar = Calendar(identifier: .gregorian)
            newFormatter.locale = Locale(identifier: "en_US_POSIX")
            newFormatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
            newFormatter.dateFormat = "MMM d"
            dateFormatterCache[timeZoneID] = newFormatter
            formatter = newFormatter
        }
        return formatter.string(from: utcDate)
    }

    private static func localTimeText(for utcDate: Date, timeZoneID: String) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let existing = timeFormatterCache[timeZoneID] {
            formatter = existing
        } else {
            let newFormatter = DateFormatter()
            newFormatter.calendar = Calendar(identifier: .gregorian)
            newFormatter.locale = Locale(identifier: "en_US_POSIX")
            newFormatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
            newFormatter.dateFormat = "HH:mm"
            timeFormatterCache[timeZoneID] = newFormatter
            formatter = newFormatter
        }
        return formatter.string(from: utcDate)
    }
}

extension TripLeg {
    var isDeadheadLeg: Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "DH" || normalized == "CML"
    }

    func countdownLeg(
        reportTimeUTC: Date? = nil,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> FlightCountdownLeg? {
        try? countdownLegResult(reportTimeUTC: reportTimeUTC, tzResolver: tzResolver).get()
    }

    func countdownLegResult(
        reportTimeUTC: Date? = nil,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> Result<FlightCountdownLeg, FlightCountdownLegExclusionReason> {
        guard let plannedDepartureText = plannedDepartureUTC else {
            return .failure(.missingPlannedDeparture)
        }
        guard let plannedDeparture = LegConnectionTextBuilder.parseUTC(plannedDepartureText) else {
            return .failure(.invalidPlannedDeparture)
        }
        guard let plannedArrivalText = plannedArrivalUTC else {
            return .failure(.missingPlannedArrival)
        }
        guard let plannedArrival = LegConnectionTextBuilder.parseUTC(plannedArrivalText) else {
            return .failure(.invalidPlannedArrival)
        }
        guard let departureTimeZoneID = tzResolver.resolve(depAirport) else {
            return .failure(.unresolvedDepartureTimeZone)
        }
        guard let arrivalTimeZoneID = tzResolver.resolve(arrAirport) else {
            return .failure(.unresolvedArrivalTimeZone)
        }

        let cleanedFlight = flight.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            FlightCountdownLeg(
                id: id.uuidString,
                flightNumber: cleanedFlight.isEmpty ? nil : cleanedFlight,
                isDeadhead: isDeadheadLeg,
                departureAirportIATA: depAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                arrivalAirportIATA: arrAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                plannedDepartureUTC: plannedDeparture,
                plannedArrivalUTC: plannedArrival,
                reportTimeUTC: reportTimeUTC,
                departureTimeZoneID: departureTimeZoneID,
                arrivalTimeZoneID: arrivalTimeZoneID
            )
        )
    }
}
