import Foundation

/// Single app-side entry point for deriving the current flight state and its presentation payload.
enum OperationalStateBuilder {
    static func build(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        nowUTC: Date,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared,
        onExclusion: (FlightCountdownLegExclusion) -> Void = { _ in }
    ) -> CountdownEngineOutput? {
        let reportTimes = reportTimesByLegID(
            schedules: schedules,
            domicileAirportCode: domicileAirportCode,
            tzResolver: tzResolver
        )

        var countdownLegs: [FlightCountdownLeg] = []
        for leg in schedules.flatMap(\.legs) {
            switch leg.countdownLegResult(
                reportTimeUTC: reportTimes[leg.id],
                tzResolver: tzResolver
            ) {
            case .success(let countdownLeg):
                countdownLegs.append(countdownLeg)
            case .failure(let reason):
                onExclusion(FlightCountdownLegExclusion(legID: leg.id, reason: reason))
            }
        }

        return FlightCountdownEngine.buildCountdownOutput(
            from: countdownLegs,
            nowUTC: nowUTC
        )
    }

    private static func reportTimesByLegID(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        tzResolver: IATATimeZoneResolving
    ) -> [UUID: Date] {
        let domicile = domicileAirportCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var result: [UUID: Date] = [:]

        let grouped = Dictionary(grouping: schedules.flatMap(\.legs)) {
            "\($0.payPeriod)|\($0.pairing)"
        }
        for legs in grouped.values {
            let ordered = legs.sorted {
                let lhs = LegConnectionTextBuilder.parseUTC($0.plannedDepartureUTC) ?? .distantFuture
                let rhs = LegConnectionTextBuilder.parseUTC($1.plannedDepartureUTC) ?? .distantFuture
                if lhs != rhs { return lhs < rhs }
                if $0.leg != $1.leg { return $0.leg < $1.leg }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let firstBaseDeparture = ordered.first(where: {
                $0.depAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == domicile
                    && LegConnectionTextBuilder.parseUTC($0.plannedDepartureUTC) != nil
            }),
            let departure = LegConnectionTextBuilder.parseUTC(firstBaseDeparture.plannedDepartureUTC) else {
                continue
            }
            let leadMinutes = ReportLeadTimePolicy.minutes(
                originAirport: firstBaseDeparture.depAirport,
                destinationAirport: firstBaseDeparture.arrAirport,
                tzResolver: tzResolver
            )
            result[firstBaseDeparture.id] = departure.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        }
        return result
    }
}
