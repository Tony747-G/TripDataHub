import Foundation

struct NextReportTripWindow {
    let key: String
    let payPeriod: String
    let pairing: String
    let tripStartDomicile: Date
    let reportTime: Date
    let tripEndDomicile: Date
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
