import Foundation

/// Single app-side entry point for deriving current flight state and optional Home Widget presentation.
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

/// Builds the complete, compact schedule projection consumed by the Home Screen Widget.
/// Selection remains in `HomeWidgetDomain`, which is compiled into both the app and extension.
enum HomeWidgetScheduleBuilder {
    static func build(
        schedules: [PayPeriodSchedule],
        domicileAirportCode: String,
        nowUTC: Date,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared,
        onExclusion: (FlightCountdownLegExclusion) -> Void = { _ in }
    ) -> HomeWidgetScheduleSnapshot? {
        let domicile = normalizedAirport(domicileAirportCode)
        let grouped = Dictionary(grouping: schedules.flatMap(\.legs)) {
            "\($0.payPeriod)|\($0.pairing)"
        }

        let trips = grouped.compactMap { groupID, sourceLegs -> HomeWidgetTrip? in
            let orderedSourceLegs = sourceLegs.sorted(by: sourceLegOrder)
            guard let firstDomicileDeparture = orderedSourceLegs.first(where: {
                normalizedAirport($0.depAirport) == domicile
                    && LegConnectionTextBuilder.parseUTC($0.plannedDepartureUTC) != nil
            }),
            let firstDepartureUTC = LegConnectionTextBuilder.parseUTC(
                firstDomicileDeparture.plannedDepartureUTC
            ),
            let reportTimeZoneID = tzResolver.resolve(firstDomicileDeparture.depAirport)
            else {
                return nil
            }

            let reportLeadMinutes = ReportLeadTimePolicy.minutes(
                originAirport: firstDomicileDeparture.depAirport,
                destinationAirport: firstDomicileDeparture.arrAirport,
                tzResolver: tzResolver
            )
            let reportTimeUTC = firstDepartureUTC.addingTimeInterval(
                TimeInterval(-reportLeadMinutes * 60)
            )

            let sourceFlightLegs = orderedSourceLegs.filter(isFlightLeg)

            var projectedLegs: [HomeWidgetLeg] = []
            for sourceLeg in sourceFlightLegs {
                guard let plannedDepartureUTC = LegConnectionTextBuilder.parseUTC(
                    sourceLeg.plannedDepartureUTC
                ) else {
                    onExclusion(.init(legID: sourceLeg.id, reason: .missingPlannedDeparture))
                    continue
                }
                guard let plannedArrivalUTC = LegConnectionTextBuilder.parseUTC(
                    sourceLeg.plannedArrivalUTC
                ) else {
                    onExclusion(.init(legID: sourceLeg.id, reason: .missingPlannedArrival))
                    continue
                }
                guard let departureTimeZoneID = tzResolver.resolve(sourceLeg.depAirport) else {
                    onExclusion(.init(legID: sourceLeg.id, reason: .unresolvedDepartureTimeZone))
                    continue
                }
                guard let arrivalTimeZoneID = tzResolver.resolve(sourceLeg.arrAirport) else {
                    onExclusion(.init(legID: sourceLeg.id, reason: .unresolvedArrivalTimeZone))
                    continue
                }

                projectedLegs.append(
                    HomeWidgetLeg(
                        id: sourceLeg.id.uuidString,
                        flightNumber: FlightNumberNormalizer.displayValue(sourceLeg.flight),
                        departureAirportIATA: normalizedAirport(sourceLeg.depAirport),
                        arrivalAirportIATA: normalizedAirport(sourceLeg.arrAirport),
                        plannedDepartureUTC: plannedDepartureUTC,
                        plannedArrivalUTC: plannedArrivalUTC,
                        departureTimeZoneID: departureTimeZoneID,
                        arrivalTimeZoneID: arrivalTimeZoneID,
                        arrivalCoordinate: tzResolver.coordinate(sourceLeg.arrAirport),
                        layoverAfterMinutes: nil
                    )
                )
            }

            projectedLegs = projectedLegs.enumerated().map { index, leg in
                guard projectedLegs.indices.contains(index + 1) else { return leg }
                let nextLeg = projectedLegs[index + 1]
                guard ScheduledLayoverPolicy.isLayover(
                    arrivalUTC: leg.plannedArrivalUTC,
                    nextDepartureUTC: nextLeg.plannedDepartureUTC,
                    sameTrip: true,
                    arrivalAirportIATA: leg.arrivalAirportIATA,
                    nextDepartureAirportIATA: nextLeg.departureAirportIATA
                ) else {
                    return leg
                }
                let minutes = ScheduledLayoverPolicy.durationMinutes(
                    arrivalUTC: leg.plannedArrivalUTC,
                    nextDepartureUTC: nextLeg.plannedDepartureUTC
                )
                return HomeWidgetLeg(
                    id: leg.id,
                    flightNumber: leg.flightNumber,
                    departureAirportIATA: leg.departureAirportIATA,
                    arrivalAirportIATA: leg.arrivalAirportIATA,
                    plannedDepartureUTC: leg.plannedDepartureUTC,
                    plannedArrivalUTC: leg.plannedArrivalUTC,
                    departureTimeZoneID: leg.departureTimeZoneID,
                    arrivalTimeZoneID: leg.arrivalTimeZoneID,
                    arrivalCoordinate: leg.arrivalCoordinate,
                    layoverAfterMinutes: minutes
                )
            }

            guard !projectedLegs.isEmpty else {
                return nil
            }
            let completionArrivalUTC = sourceFlightLegs.reversed().compactMap {
                LegConnectionTextBuilder.parseUTC($0.plannedArrivalUTC)
            }.first ?? projectedLegs.last?.plannedArrivalUTC
            guard let completionArrivalUTC else {
                return nil
            }
            let releaseBoundaryUTC = completionArrivalUTC.addingTimeInterval(
                HomeWidgetDomain.postFinalArrivalInterval
            )

            return HomeWidgetTrip(
                id: groupID,
                tripID: firstDomicileDeparture.pairing,
                reportTimeUTC: reportTimeUTC,
                reportTimeZoneID: reportTimeZoneID,
                releaseBoundaryUTC: releaseBoundaryUTC,
                legs: projectedLegs
            )
        }
        .filter { trip in
            trip.reportTimeUTC > nowUTC
                || (trip.releaseBoundaryUTC.map { $0 > nowUTC } ?? false)
        }
        .sorted {
            if $0.reportTimeUTC != $1.reportTimeUTC {
                return $0.reportTimeUTC < $1.reportTimeUTC
            }
            return $0.id < $1.id
        }

        guard !trips.isEmpty else { return nil }
        return HomeWidgetScheduleSnapshot(updatedAtUTC: nowUTC, trips: trips)
    }

    private static func isFlightLeg(_ leg: TripLeg) -> Bool {
        normalizedAirport(leg.flight) != "GND"
            && normalizedAirport(leg.status) != "GND"
    }

    private static func sourceLegOrder(_ lhs: TripLeg, _ rhs: TripLeg) -> Bool {
        if lhs.leg != rhs.leg { return lhs.leg < rhs.leg }
        let lhsDeparture = LegConnectionTextBuilder.parseUTC(lhs.plannedDepartureUTC)
        let rhsDeparture = LegConnectionTextBuilder.parseUTC(rhs.plannedDepartureUTC)
        if lhsDeparture != rhsDeparture {
            return (lhsDeparture ?? .distantFuture) < (rhsDeparture ?? .distantFuture)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func normalizedAirport(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
