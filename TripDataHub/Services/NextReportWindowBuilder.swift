import Foundation

struct NextReportTripWindow {
    let key: String
    let pairing: String
    let tripStartDomicile: Date
    let reportTime: Date
    let tripEndDomicile: Date
}

enum NextReportWindowBuilder {
    static let anchorageFallbackOffsetSeconds = -9 * 3600
    static let reportLeadTimeSeconds: TimeInterval = 90 * 60

    static func build(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        domicileTimeZone: TimeZone
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

            guard let firstDomicileDeparture = sorted.first(where: { $0.depAirport.uppercased() == domicileAirport }),
                  let tripStartDomicile = parseUTC(firstDomicileDeparture.depUTC)
            else {
                continue
            }

            let reportTime = tripStartDomicile.addingTimeInterval(-reportLeadTimeSeconds)

            let domicileArrivals = sorted
                .filter { $0.arrAirport.uppercased() == domicileAirport }
                .compactMap { parseUTC($0.arrUTC) }

            guard let tripEndDomicile = domicileArrivals.max() else {
                continue
            }

            let key = "\(groupKey)|\(Int(reportTime.timeIntervalSince1970))"
            results.append(
                NextReportTripWindow(
                    key: key,
                    pairing: firstDomicileDeparture.pairing,
                    tripStartDomicile: tripStartDomicile,
                    reportTime: reportTime,
                    tripEndDomicile: tripEndDomicile
                )
            )
        }

        return results
    }

    private static func parseUTC(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return LegConnectionTextBuilder.parseUTC(raw)
    }

    private static func sortDate(for leg: TripLeg, localFormatter: DateFormatter) -> Date {
        if let depUTC = parseUTC(leg.depUTC) {
            return depUTC
        }
        if let parsedLocal = localFormatter.date(from: leg.depLocal) {
            return parsedLocal
        }
        return .distantFuture
    }
}
