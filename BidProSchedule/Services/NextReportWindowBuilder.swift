import Foundation

struct NextReportTripWindow {
    let key: String
    let pairing: String
    let tripStartANC: Date
    let reportTime: Date
    let tripEndANC: Date
}

enum NextReportWindowBuilder {
    static let anchorageFallbackOffsetSeconds = -9 * 3600
    static let reportLeadTimeSeconds: TimeInterval = 90 * 60

    static func build(
        schedules: [PayPeriodSchedule],
        anchorageTimeZone: TimeZone
    ) -> [NextReportTripWindow] {
        let allLegs = schedules
            .flatMap(\.legs)
            .sorted { lhs, rhs in
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

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = anchorageTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var results: [NextReportTripWindow] = []
        for (groupKey, legs) in grouped {
            let sorted = legs.sorted { lhs, rhs in
                if lhs.depLocal == rhs.depLocal {
                    return lhs.leg < rhs.leg
                }
                return lhs.depLocal < rhs.depLocal
            }

            guard let firstANCDep = sorted.first(where: { $0.depAirport.uppercased() == "ANC" }),
                  let tripStartANC = formatter.date(from: firstANCDep.depLocal)
            else {
                continue
            }

            let reportTime = tripStartANC.addingTimeInterval(-reportLeadTimeSeconds)

            let ancArrivals = sorted
                .filter { $0.arrAirport.uppercased() == "ANC" }
                .compactMap { formatter.date(from: $0.arrLocal) }

            guard let tripEndANC = ancArrivals.max() else {
                continue
            }

            let key = "\(groupKey)|\(Int(reportTime.timeIntervalSince1970))"
            results.append(
                NextReportTripWindow(
                    key: key,
                    pairing: firstANCDep.pairing,
                    tripStartANC: tripStartANC,
                    reportTime: reportTime,
                    tripEndANC: tripEndANC
                )
            )
        }

        return results
    }
}
