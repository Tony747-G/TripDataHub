import Foundation

/// Single app-side entry point for deriving the current flight state and its presentation payload.
enum OperationalStateBuilder {
    static func build(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        domicileTimeZone: TimeZone,
        nowUTC: Date,
        referenceTimeDisplay: FlightReferenceTimeDisplay,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared,
        onExclusion: (FlightCountdownLegExclusion) -> Void = { _ in }
    ) -> CountdownEngineOutput? {
        let reportWindows = NextReportWindowBuilder.build(
            schedules: schedules,
            domicileAirportCode: domicileAirportCode,
            domicileTimeZone: domicileTimeZone,
            tzResolver: tzResolver
        )
        let reportTimes = reportTimesByLegID(
            schedules: schedules,
            windows: reportWindows,
            domicileAirportCode: domicileAirportCode
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
            nowUTC: nowUTC,
            referenceTimeDisplay: referenceTimeDisplay
        )
    }

    private static func reportTimesByLegID(
        schedules: [PayPeriodSchedule],
        windows: [NextReportTripWindow],
        domicileAirportCode: String
    ) -> [UUID: Date] {
        let domicile = domicileAirportCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allLegs = schedules.flatMap(\.legs)
        var result: [UUID: Date] = [:]

        for window in windows {
            let matchingLeg = allLegs
                .filter {
                    $0.payPeriod == window.payPeriod
                        && $0.pairing == window.pairing
                        && $0.depAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == domicile
                }
                .first {
                    guard let departure = LegConnectionTextBuilder.parseUTC($0.plannedDepartureUTC) else {
                        return false
                    }
                    return departure == window.tripStartDomicile
                }
            if let matchingLeg {
                result[matchingLeg.id] = window.reportTime
            }
        }
        return result
    }
}
