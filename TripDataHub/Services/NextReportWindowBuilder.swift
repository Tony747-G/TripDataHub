import Foundation

struct NextReportTripWindow {
    let key: String
    let payPeriod: String
    let pairing: String
    let tripStartDomicile: Date
    let reportTime: Date
    let tripEndDomicile: Date
}

enum TimelineNextReportUrgency: Equatable {
    case normal
    case urgent
}

struct TimelineNextReportTrip: Equatable {
    let key: String
    let pairing: String
    let reportTime: Date
    let releaseBoundary: Date?
}

struct TimelineNextReportPresentation: Equatable {
    let pairing: String
    let reportTime: Date
    let titleText: String
    let reportDateTimeText: String
    let remainingText: String
    let urgency: TimelineNextReportUrgency
}

/// Timeline-only report countdown policy.
///
/// Notifications and the Home Screen Widget continue to use their independent selectors. Timeline
/// suppresses future report instants while a started Trip remains active. Selection/scroll state
/// never participates; release is derived only from the final scheduled flight arrival.
enum TimelineNextReportCountdownBuilder {
    static let urgentThreshold: TimeInterval = 12 * 60 * 60
    static let dayThreshold: TimeInterval = 24 * 60 * 60
    static let postArrivalReleaseInterval: TimeInterval = 30 * 60
    private static let formatterLock = NSLock()
    private static var reportDateTimeFormatters: [String: DateFormatter] = [:]

    static func build(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> [TimelineNextReportTrip] {
        let domicileAirport = domicileAirportCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let grouped = Dictionary(grouping: schedules.flatMap(\.legs)) {
            "\($0.payPeriod)|\($0.pairing)"
        }

        return grouped.compactMap { groupKey, legs in
            let firstDomicileDeparture = legs
                .filter { $0.depAirport.uppercased() == domicileAirport }
                .compactMap { leg -> (TripLeg, Date)? in
                    guard let raw = leg.plannedDepartureUTC,
                          let departure = LegConnectionTextBuilder.parseUTC(raw)
                    else {
                        return nil
                    }
                    return (leg, departure)
                }
                .min {
                    if $0.1 != $1.1 { return $0.1 < $1.1 }
                    return $0.0.leg < $1.0.leg
                }

            guard let (leg, departure) = firstDomicileDeparture else { return nil }
            let leadMinutes = ReportLeadTimePolicy.minutes(
                originAirport: leg.depAirport,
                destinationAirport: leg.arrAirport,
                tzResolver: tzResolver
            )
            let reportTime = departure.addingTimeInterval(TimeInterval(-leadMinutes * 60))
            // Determine the final flight before parsing its arrival. Falling back to an earlier
            // arrival when the final flight is incomplete would fabricate a release boundary.
            let finalFlight = legs
                .filter(isFlightLeg)
                .max(by: isEarlierTripLeg)
            let releaseBoundary = finalFlight
                .flatMap { LegConnectionTextBuilder.parseUTC($0.staUTC ?? $0.originalSTAUTC) }
                .map { $0.addingTimeInterval(postArrivalReleaseInterval) }
            return TimelineNextReportTrip(
                key: "\(groupKey)|\(Int(reportTime.timeIntervalSince1970))",
                pairing: leg.pairing,
                reportTime: reportTime,
                releaseBoundary: releaseBoundary
            )
        }
    }

    static func nextTrip(
        from trips: [TimelineNextReportTrip],
        now: Date
    ) -> TimelineNextReportTrip? {
        let startedTrips = trips.filter { $0.reportTime <= now }

        if startedTrips.contains(where: { trip in
            guard let releaseBoundary = trip.releaseBoundary else { return false }
            return now < releaseBoundary
        }) {
            return nil
        }

        // A missing final arrival on the most recently started Trip has no safe inferred release.
        // Once a later Trip itself starts, that later Trip becomes the conservative authority.
        if let mostRecentlyStarted = startedTrips.max(by: tripReportOrder),
           mostRecentlyStarted.releaseBoundary == nil {
            return nil
        }

        return trips
            .filter { $0.reportTime > now }
            .min(by: tripReportOrder)
    }

    static func presentation(
        from windows: [TimelineNextReportTrip],
        now: Date,
        displayTimeZone: TimeZone,
        zoneCode: String
    ) -> TimelineNextReportPresentation? {
        guard let trip = nextTrip(from: windows, now: now) else { return nil }
        let remaining = trip.reportTime.timeIntervalSince(now)
        guard remaining > 0 else { return nil }

        return TimelineNextReportPresentation(
            pairing: trip.pairing,
            reportTime: trip.reportTime,
            titleText: "NEXT REPORT Trip \(trip.pairing)",
            reportDateTimeText: reportDateTimeText(
                trip.reportTime,
                timeZone: displayTimeZone,
                zoneCode: zoneCode
            ),
            remainingText: "Report in \(remainingText(remaining))",
            urgency: remaining >= urgentThreshold ? .normal : .urgent
        )
    }

    static func remainingText(_ remaining: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(floor(remaining)))
        let days = wholeSeconds / Int(dayThreshold)
        let hours = (wholeSeconds % Int(dayThreshold)) / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let minuteText = String(format: "%02d", minutes)

        if remaining >= dayThreshold {
            return "\(days) days \(hours) hours, \(minuteText) minutes"
        }
        return "\(wholeSeconds / 3_600) hours, \(minuteText) minutes"
    }

    private static func reportDateTimeText(
        _ date: Date,
        timeZone: TimeZone,
        zoneCode: String
    ) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let cached = reportDateTimeFormatters[timeZone.identifier] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.calendar = Calendar(identifier: .gregorian)
            created.locale = Locale(identifier: "en_US_POSIX")
            created.timeZone = timeZone
            created.dateFormat = "EEE, MMM dd yyyy   HH:mm"
            reportDateTimeFormatters[timeZone.identifier] = created
            formatter = created
        }
        return "\(formatter.string(from: date).uppercased()) \(zoneCode.uppercased())"
    }

    private static func isFlightLeg(_ leg: TripLeg) -> Bool {
        leg.flight.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("GND") != .orderedSame
            && leg.status.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("GND") != .orderedSame
    }

    private static func isEarlierTripLeg(_ lhs: TripLeg, _ rhs: TripLeg) -> Bool {
        if lhs.leg != rhs.leg { return lhs.leg < rhs.leg }
        let lhsDeparture = LegConnectionTextBuilder.parseUTC(lhs.plannedDepartureUTC)
        let rhsDeparture = LegConnectionTextBuilder.parseUTC(rhs.plannedDepartureUTC)
        if lhsDeparture != rhsDeparture {
            return (lhsDeparture ?? .distantPast) < (rhsDeparture ?? .distantPast)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func tripReportOrder(
        _ lhs: TimelineNextReportTrip,
        _ rhs: TimelineNextReportTrip
    ) -> Bool {
        if lhs.reportTime != rhs.reportTime {
            return lhs.reportTime < rhs.reportTime
        }
        return lhs.key < rhs.key
    }
}

enum NextReportWindowBuilder {
    static let anchorageFallbackOffsetSeconds = -9 * 3600

    static func build(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        domicileTimeZone: TimeZone,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> [NextReportTripWindow] {
        let domicileAirport = domicileAirportCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parseFormatter = DateFormatter()
        parseFormatter.calendar = Calendar(identifier: .gregorian)
        parseFormatter.locale = Locale(identifier: "en_US_POSIX")
        parseFormatter.timeZone = domicileTimeZone
        parseFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let allLegs = schedules
            .flatMap(\.legs)
            .sorted { lhs, rhs in
                let lhsDate = sortDate(for: lhs, localFormatter: parseFormatter)
                let rhsDate = sortDate(for: rhs, localFormatter: parseFormatter)
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                if lhs.depLocal == rhs.depLocal {
                    return lhs.flight < rhs.flight
                }
                return lhs.depLocal < rhs.depLocal
            }

        var grouped: [String: [TripLeg]] = [:]
        for leg in allLegs {
            let key = "\(leg.payPeriod)|\(leg.pairing)"
            grouped[key, default: []].append(leg)
        }

        var results: [NextReportTripWindow] = []
        for (groupKey, legs) in grouped {
            let sorted = legs.sorted { lhs, rhs in
                let lhsDate = sortDate(for: lhs, localFormatter: parseFormatter)
                let rhsDate = sortDate(for: rhs, localFormatter: parseFormatter)
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                if lhs.depLocal == rhs.depLocal {
                    return lhs.leg < rhs.leg
                }
                return lhs.depLocal < rhs.depLocal
            }

            // Report time is a property of the schedule, not of what happened (INV-012). Using
            // the display value here would move the pilot's report time whenever an Actual
            // departure was observed — a late ATD would silently push report time later.
            guard let firstDomicileDeparture = sorted.first(where: { $0.depAirport.uppercased() == domicileAirport }),
                  let tripStartDomicile = parseUTC(firstDomicileDeparture.plannedDepartureUTC)
            else {
                continue
            }

            let reportLeadMinutes = ReportLeadTimePolicy.minutes(
                originAirport: firstDomicileDeparture.depAirport,
                destinationAirport: firstDomicileDeparture.arrAirport,
                tzResolver: tzResolver
            )
            let reportTime = tripStartDomicile.addingTimeInterval(TimeInterval(-reportLeadMinutes * 60))

            // Scheduled for the same reason: the suppression window must be derivable before the
            // trip is flown, and must not shift underneath the countdown mid-trip.
            let domicileArrivals = sorted
                .filter { $0.arrAirport.uppercased() == domicileAirport }
                .compactMap { parseUTC($0.plannedArrivalUTC) }

            guard let tripEndDomicile = domicileArrivals.max() else {
                continue
            }

            let key = "\(groupKey)|\(Int(reportTime.timeIntervalSince1970))"
            results.append(
                NextReportTripWindow(
                    key: key,
                    payPeriod: firstDomicileDeparture.payPeriod,
                    pairing: firstDomicileDeparture.pairing,
                    tripStartDomicile: tripStartDomicile,
                    reportTime: reportTime,
                    tripEndDomicile: tripEndDomicile
                )
            )
        }

        return results
    }

    /// Selects the next report countdown while suppressing it until the current
    /// trip has returned to domicile. At the exact arrival time, the following
    /// trip becomes eligible.
    static func nextReportWindow(
        from windows: [NextReportTripWindow],
        now: Date
    ) -> NextReportTripWindow? {
        for window in windows.sorted(by: { $0.reportTime < $1.reportTime }) {
            if now < window.reportTime {
                return window
            }
            if now < window.tripEndDomicile {
                return nil
            }
        }
        return nil
    }

    static func hasActiveTrip(
        in windows: [NextReportTripWindow],
        now: Date
    ) -> Bool {
        windows.contains { now >= $0.reportTime && now < $0.tripEndDomicile }
    }

    private static func parseUTC(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return LegConnectionTextBuilder.parseUTC(raw)
    }

    private static func sortDate(for leg: TripLeg, localFormatter: DateFormatter) -> Date {
        // Scheduled ordering, so an observed delay cannot reorder the legs of a trip.
        if let depUTC = parseUTC(leg.plannedDepartureUTC) {
            return depUTC
        }
        if let parsedLocal = localFormatter.date(from: leg.depLocal) {
            return parsedLocal
        }
        return .distantFuture
    }
}
