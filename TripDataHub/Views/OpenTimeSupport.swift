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
    /// Build PP sections from all open time trips across all schedules.
    /// Groups trips by their actual Pay Period derived from the trip's departure
    /// date (via resolvePayPeriodLabel), not from TripBoard's payPeriodId.
    /// TripBoard's payPeriodId numbering may differ from the app's PP calendar,
    /// which causes mislabelling when using schedule.label directly.
    static func build(
        schedules: [PayPeriodSchedule],
        domicile: String = DomicileSupport.defaultDomicile
    ) -> [OpenTimePPSection] {
        // Collect all rows, keyed by actual PP derived from startLocal
        var rowsByPP: [String: [OpenTimeDisplayRow]] = [:]
        var ppOrder: [String] = []

        for schedule in schedules {
            for trip in schedule.openTimeTrips {
                let dateKey = ScheduleDateText.datePart(from: trip.startLocal)
                // Derive the actual PP from the trip's departure date using the
                // app's own BP/PP calendar. Fall back to TripBoard's label if
                // the date can't be resolved.
                let ppLabel: String
                if let date = SharedDateFormatters.localDayInput.date(from: dateKey),
                   let resolved = resolvePayPeriodLabel(for: date, domicile: domicile) {
                    ppLabel = resolved
                } else {
                    ppLabel = schedule.label
                }

                let row = OpenTimeDisplayRow(
                    id: trip.id,
                    trip: trip,
                    payPeriod: ppLabel,
                    pairing: trip.pairing,
                    route: trip.route,
                    credit: trip.credit,
                    startLocal: trip.startLocal,
                    endLocal: trip.endLocal,
                    requestType: trip.requestType,
                    status: trip.status
                )

                if rowsByPP[ppLabel] == nil {
                    ppOrder.append(ppLabel)
                    rowsByPP[ppLabel] = []
                }
                rowsByPP[ppLabel]?.append(row)
            }
        }

        // Sort rows within each PP by startLocal, then build day-sections
        return ppOrder.compactMap { ppLabel -> OpenTimePPSection? in
            guard var rows = rowsByPP[ppLabel], !rows.isEmpty else { return nil }
            rows.sort { lhs, rhs in
                lhs.startLocal == rhs.startLocal ? lhs.pairing < rhs.pairing : lhs.startLocal < rhs.startLocal
            }

            var dayOrder: [String] = []
            var dayGrouped: [String: [OpenTimeDisplayRow]] = [:]
            for row in rows {
                let key = ScheduleDateText.datePart(from: row.startLocal)
                if dayGrouped[key] == nil {
                    dayOrder.append(key)
                    dayGrouped[key] = []
                }
                dayGrouped[key]?.append(row)
            }

            let daySections = dayOrder.map { key in
                OpenTimeDaySection(
                    id: "\(ppLabel)-\(key)",
                    label: ScheduleDateText.dayHeaderLabel(from: key),
                    rows: dayGrouped[key] ?? []
                )
            }

            return OpenTimePPSection(id: ppLabel, label: ppLabel, daySections: daySections)
        }
    }
}
