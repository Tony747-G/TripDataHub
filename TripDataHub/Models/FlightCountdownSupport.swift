import Foundation

struct FlightCountdownLeg: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let flightNumber: String?
    let isDeadhead: Bool
    let departureAirportIATA: String
    let arrivalAirportIATA: String
    let scheduledDepartureUTC: Date
    let scheduledArrivalUTC: Date
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
}

struct CountdownDisplayStrings: Codable, Equatable, Hashable {
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
    let routeText: String
    let statusText: String
}

struct CountdownEngineOutput: Codable, Equatable, Hashable {
    let leg: FlightCountdownLeg
    let phase: CountdownPresentationPhase
    let display: CountdownDisplayStrings
}

enum FlightCountdownEngine {
    private static let widgetLeadTime: TimeInterval = 12 * 60 * 60
    private static let liveLeadTime: TimeInterval = 6 * 60 * 60
    private static let delayedTailTime: TimeInterval = 6 * 60 * 60

    static func selectRelevantLeg(
        from legs: [FlightCountdownLeg],
        nowUTC: Date
    ) -> FlightCountdownLeg? {
        legs
            .sorted(by: compareLegs(_:_:))
            .first { leg in
                nowUTC >= leg.scheduledDepartureUTC.addingTimeInterval(-widgetLeadTime)
                    && nowUTC < leg.scheduledDepartureUTC.addingTimeInterval(delayedTailTime)
            }
    }

    static func phase(
        for leg: FlightCountdownLeg,
        nowUTC: Date
    ) -> CountdownPresentationPhase {
        let departureUTC = leg.scheduledDepartureUTC
        if nowUTC < departureUTC.addingTimeInterval(-widgetLeadTime) {
            return .none
        }
        if nowUTC < departureUTC.addingTimeInterval(-liveLeadTime) {
            return .widget
        }
        if nowUTC < departureUTC {
            return .liveCountdown
        }
        if nowUTC < departureUTC.addingTimeInterval(delayedTailTime) {
            return .liveDelayed
        }
        return .finished
    }

    static func statusText(
        for leg: FlightCountdownLeg,
        nowUTC: Date
    ) -> String? {
        let currentPhase = phase(for: leg, nowUTC: nowUTC)
        switch currentPhase {
        case .widget, .liveCountdown:
            return "Departure in \(durationText(from: nowUTC, to: leg.scheduledDepartureUTC))"
        case .liveDelayed:
            return "Delayed \(durationText(from: leg.scheduledDepartureUTC, to: nowUTC))"
        case .none, .finished:
            return nil
        }
    }

    static func displayStrings(for leg: FlightCountdownLeg, nowUTC: Date) -> CountdownDisplayStrings? {
        guard let statusText = statusText(for: leg, nowUTC: nowUTC) else {
            return nil
        }
        let departureDateText = localDateText(for: leg.scheduledDepartureUTC, timeZoneID: leg.departureTimeZoneID)
        let departureTimeText = localTimeText(for: leg.scheduledDepartureUTC, timeZoneID: leg.departureTimeZoneID)
        let arrivalDateText = localDateText(for: leg.scheduledArrivalUTC, timeZoneID: leg.arrivalTimeZoneID)
        let arrivalTimeText = localTimeText(for: leg.scheduledArrivalUTC, timeZoneID: leg.arrivalTimeZoneID)
        let routeText = "\(leg.departureAirportIATA) \(departureTimeText) -> \(arrivalDateText) \(arrivalTimeText) \(leg.arrivalAirportIATA)"
        return CountdownDisplayStrings(
            departureDateText: departureDateText,
            departureTimeText: departureTimeText,
            arrivalDateText: arrivalDateText,
            arrivalTimeText: arrivalTimeText,
            routeText: routeText,
            statusText: statusText
        )
    }

    static func buildCountdownOutput(
        from legs: [FlightCountdownLeg],
        nowUTC: Date
    ) -> CountdownEngineOutput? {
        guard let leg = selectRelevantLeg(from: legs, nowUTC: nowUTC) else {
            return nil
        }
        let currentPhase = phase(for: leg, nowUTC: nowUTC)
        guard let display = displayStrings(for: leg, nowUTC: nowUTC) else {
            return nil
        }
        return CountdownEngineOutput(leg: leg, phase: currentPhase, display: display)
    }

    private static func compareLegs(_ lhs: FlightCountdownLeg, _ rhs: FlightCountdownLeg) -> Bool {
        if lhs.scheduledDepartureUTC != rhs.scheduledDepartureUTC {
            return lhs.scheduledDepartureUTC < rhs.scheduledDepartureUTC
        }
        if lhs.scheduledArrivalUTC != rhs.scheduledArrivalUTC {
            return lhs.scheduledArrivalUTC < rhs.scheduledArrivalUTC
        }
        return lhs.id < rhs.id
    }

    private static func durationText(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start)) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m"
    }

    private static func localDateText(for utcDate: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter.string(from: utcDate)
    }

    private static func localTimeText(for utcDate: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: utcDate)
    }
}

extension TripLeg {
    var isDeadheadLeg: Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "DH" || normalized == "CML"
    }

    func countdownLeg(tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared) -> FlightCountdownLeg? {
        guard let scheduledDepartureUTC = LegConnectionTextBuilder.parseUTC(depUTC),
              let scheduledArrivalUTC = LegConnectionTextBuilder.parseUTC(arrUTC),
              let departureTimeZoneID = tzResolver.resolve(depAirport),
              let arrivalTimeZoneID = tzResolver.resolve(arrAirport)
        else {
            return nil
        }

        let cleanedFlight = flight.trimmingCharacters(in: .whitespacesAndNewlines)
        return FlightCountdownLeg(
            id: id.uuidString,
            flightNumber: cleanedFlight.isEmpty ? nil : cleanedFlight,
            isDeadhead: isDeadheadLeg,
            departureAirportIATA: depAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            arrivalAirportIATA: arrAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            scheduledDepartureUTC: scheduledDepartureUTC,
            scheduledArrivalUTC: scheduledArrivalUTC,
            departureTimeZoneID: departureTimeZoneID,
            arrivalTimeZoneID: arrivalTimeZoneID
        )
    }
}

extension Array where Element == PayPeriodSchedule {
    func countdownLegs(tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared) -> [FlightCountdownLeg] {
        flatMap(\.legs).compactMap { $0.countdownLeg(tzResolver: tzResolver) }
    }
}
