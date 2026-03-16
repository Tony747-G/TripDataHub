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
    // DateFormatter caches keyed by timezone ID. The lock protects dictionary mutations;
    // formatters themselves are immutable after creation so concurrent reads are safe.
    private static let formatterLock = NSLock()
    private static var dateFormatterCache: [String: DateFormatter] = [:]
    private static var timeFormatterCache: [String: DateFormatter] = [:]

    static func selectRelevantLeg(
        from legs: [FlightCountdownLeg],
        nowUTC: Date
    ) -> FlightCountdownLeg? {
        let eligibleLegs = legs.filter { leg in
            nowUTC >= leg.scheduledDepartureUTC.addingTimeInterval(-FlightCountdownSharedStore.widgetLeadTime)
                && nowUTC < leg.scheduledDepartureUTC.addingTimeInterval(FlightCountdownSharedStore.delayedTailTime)
        }

        let liveUpcoming = eligibleLegs
            .filter { phase(for: $0, nowUTC: nowUTC) == .liveCountdown }
            .sorted(by: compareLegs(_:_:))
        if let liveUpcomingLeg = liveUpcoming.first {
            return liveUpcomingLeg
        }

        let widgetUpcoming = eligibleLegs
            .filter { phase(for: $0, nowUTC: nowUTC) == .widget }
            .sorted(by: compareLegs(_:_:))
        if let widgetUpcomingLeg = widgetUpcoming.first {
            return widgetUpcomingLeg
        }

        let liveDelayed = eligibleLegs
            .filter { phase(for: $0, nowUTC: nowUTC) == .liveDelayed }
            .sorted(by: compareDelayedLegs(_:_:))
        if let liveDelayedLeg = liveDelayed.first {
            return liveDelayedLeg
        }

        return nil
    }

    static func phase(
        for leg: FlightCountdownLeg,
        nowUTC: Date
    ) -> CountdownPresentationPhase {
        FlightCountdownSharedStore.phase(scheduledDepartureUTC: leg.scheduledDepartureUTC, now: nowUTC)
    }

    static func statusText(
        for leg: FlightCountdownLeg,
        nowUTC: Date
    ) -> String? {
        let currentPhase = phase(for: leg, nowUTC: nowUTC)
        switch currentPhase {
        case .widget, .liveCountdown:
            return "Departure in \(FlightCountdownSharedStore.durationText(from: nowUTC, to: leg.scheduledDepartureUTC))"
        case .liveDelayed:
            return "Delayed \(FlightCountdownSharedStore.durationText(from: leg.scheduledDepartureUTC, to: nowUTC))"
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

    private static func compareDelayedLegs(_ lhs: FlightCountdownLeg, _ rhs: FlightCountdownLeg) -> Bool {
        if lhs.scheduledDepartureUTC != rhs.scheduledDepartureUTC {
            return lhs.scheduledDepartureUTC > rhs.scheduledDepartureUTC
        }
        if lhs.scheduledArrivalUTC != rhs.scheduledArrivalUTC {
            return lhs.scheduledArrivalUTC > rhs.scheduledArrivalUTC
        }
        return lhs.id < rhs.id
    }

    // Lock covers both dictionary access and the formatting call so no formatter
    // is ever used outside the lock — avoiding the DateFormatter thread-safety ambiguity.
    private static func localDateText(for utcDate: Date, timeZoneID: String) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let f: DateFormatter
        if let existing = dateFormatterCache[timeZoneID] {
            f = existing
        } else {
            let newF = DateFormatter()
            newF.calendar = Calendar(identifier: .gregorian)
            newF.locale = Locale(identifier: "en_US_POSIX")
            newF.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
            newF.dateFormat = "MMM d"
            dateFormatterCache[timeZoneID] = newF
            f = newF
        }
        return f.string(from: utcDate)
    }

    private static func localTimeText(for utcDate: Date, timeZoneID: String) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let f: DateFormatter
        if let existing = timeFormatterCache[timeZoneID] {
            f = existing
        } else {
            let newF = DateFormatter()
            newF.calendar = Calendar(identifier: .gregorian)
            newF.locale = Locale(identifier: "en_US_POSIX")
            newF.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
            newF.dateFormat = "HH:mm"
            timeFormatterCache[timeZoneID] = newF
            f = newF
        }
        return f.string(from: utcDate)
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
