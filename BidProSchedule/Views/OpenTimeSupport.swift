import Foundation

struct OpenTimeDisplayRow: Identifiable {
    let id: UUID
    let trip: OpenTimeTrip
    let payPeriod: String
    let pairing: String
    let route: String
    let credit: String
    let startLocal: String
    let endLocal: String
    let requestType: String
    let status: String
}

struct OpenTimeDaySection: Identifiable {
    let id: String
    let label: String
    let rows: [OpenTimeDisplayRow]
}

struct OpenTimePPSection: Identifiable {
    let id: String
    let label: String
    let daySections: [OpenTimeDaySection]
}

enum OpenTimeSectionBuilder {
    static func build(schedules: [PayPeriodSchedule]) -> [OpenTimePPSection] {
        schedules.compactMap { schedule in
            let rows = schedule.openTimeTrips
                .map { trip in
                    OpenTimeDisplayRow(
                        id: trip.id,
                        trip: trip,
                        payPeriod: schedule.label,
                        pairing: trip.pairing,
                        route: trip.route,
                        credit: trip.credit,
                        startLocal: trip.startLocal,
                        endLocal: trip.endLocal,
                        requestType: trip.requestType,
                        status: trip.status
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.startLocal == rhs.startLocal {
                        return lhs.pairing < rhs.pairing
                    }
                    return lhs.startLocal < rhs.startLocal
                }

            guard !rows.isEmpty else { return nil }

            var order: [String] = []
            var grouped: [String: [OpenTimeDisplayRow]] = [:]
            for row in rows {
                let key = ScheduleDateText.datePart(from: row.startLocal)
                if grouped[key] == nil {
                    order.append(key)
                    grouped[key] = []
                }
                grouped[key]?.append(row)
            }

            let daySections = order.map { key in
                OpenTimeDaySection(
                    id: "\(schedule.label)-\(key)",
                    label: ScheduleDateText.dayHeaderLabel(from: key),
                    rows: grouped[key] ?? []
                )
            }

            return OpenTimePPSection(
                id: schedule.label,
                label: schedule.label,
                daySections: daySections
            )
        }
    }
}
