import Foundation

// MARK: - Generator

enum WatchSnapshotGenerator {

    /// Report time before the first departure when starting from crew domicile (1h30m).
    static let reportLeadBeforeDep: TimeInterval = 90 * 60

    /// Trip mode window: 24h before report = 24h + 1h30m before first departure from domicile.
    static let tripLeadWindow: TimeInterval = 24 * 60 * 60 + reportLeadBeforeDep  // 25.5h
    static let tripLeadBeforeDutyStart: TimeInterval = tripLeadWindow - reportLeadBeforeDep

    /// Watch continues to show Trip mode for this long after arrival.
    static let tripTailWindow: TimeInterval = 6 * 60 * 60

    /// Watch shows Training mode for CQ events within this window before start.
    static let trainingLeadWindow: TimeInterval = 6 * 60 * 60

    /// Generates a WatchOperationalSnapshot from current schedule state.
    ///
    /// Priority (highest first):
    /// 1. Active reserve / LCO / RCID window  — LDT + remaining window is the key info
    /// 2. Active imported trip/pairing (from T-24h of report until final arrival tail)
    /// 3. Upcoming trip pairing within T-24h of report
    /// 4. Active or upcoming CQ within T-6h
    /// 5. Off-duty
    static func generate(
        schedules: [PayPeriodSchedule],
        manualEvents: [ManualOperationalEvent],
        crewBase: CrewBase,
        now: Date = Date(),
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> WatchOperationalSnapshot {
        let tripWindows = tripWindows(from: schedules, crewBase: crewBase, tzResolver: tzResolver)
        let tz = crewBase.timeZone

        if let event = activeReserveOrRCID(in: manualEvents, now: now) {
            return snapshot(.reserve, now: now, reserve: reservePayload(from: event))
        }

        if let leg = tripLegForCurrentMode(in: tripWindows, now: now) {
            return snapshot(.trip, now: now, trip: tripPayload(from: leg, crewBase: crewBase))
        }

        if let event = activeOrUpcomingCQ(in: manualEvents, now: now) {
            return snapshot(.training, now: now, training: trainingPayload(from: event, tz: tz))
        }

        return snapshot(.offDuty, now: now,
                        offDuty: offDutyPayload(manualEvents: manualEvents, tripWindows: tripWindows, tz: tz, now: now))
    }
}

// MARK: - Mode selectors

private extension WatchSnapshotGenerator {

    static func activeReserveOrRCID(in events: [ManualOperationalEvent], now: Date) -> ManualOperationalEvent? {
        events.first { $0.code.isWatchReserveMode && $0.startUTC <= now && now < $0.endUTC }
    }

    static func tripLegForCurrentMode(in windows: [TripWindow], now: Date) -> FlightCountdownLeg? {
        windows
            .filter { $0.modeStartUTC <= now && now < $0.modeEndUTC }
            .sorted { $0.modeStartUTC < $1.modeStartUTC }
            .compactMap { $0.displayLeg(now: now) }
            .first
    }

    static func activeOrUpcomingCQ(in events: [ManualOperationalEvent], now: Date) -> ManualOperationalEvent? {
        events.first {
            $0.code.isWatchTrainingMode &&
            now >= $0.startUTC.addingTimeInterval(-trainingLeadWindow) &&
            now < $0.endUTC
        }
    }
}

// MARK: - Payload builders

private extension WatchSnapshotGenerator {

    struct TripWindow {
        let key: String
        let legs: [FlightCountdownLeg]
        let dutyStartUTC: Date
        let dutyTimeLabel: String
        let modeStartUTC: Date
        let modeEndUTC: Date
        let scheduleUpdatedAt: Date

        func displayLeg(now: Date) -> FlightCountdownLeg? {
            if let nextLeg = legs.first(where: { now < $0.scheduledDepartureUTC }) {
                return nextLeg
            }
            return legs.last { now < $0.scheduledArrivalUTC.addingTimeInterval(WatchSnapshotGenerator.tripTailWindow) }
        }
    }

    static func tripWindows(
        from schedules: [PayPeriodSchedule],
        crewBase: CrewBase,
        tzResolver: IATATimeZoneResolving
    ) -> [TripWindow] {
        var latestWindowByKey: [String: TripWindow] = [:]

        for schedule in schedules {
            let grouped = Dictionary(grouping: schedule.legs) { leg in
                "\(leg.payPeriod)|\(leg.pairing)"
            }

            for (key, tripLegs) in grouped {
                guard let window = tripWindow(
                    key: key,
                    tripLegs: tripLegs,
                    scheduleUpdatedAt: schedule.updatedAt,
                    crewBase: crewBase,
                    tzResolver: tzResolver
                ) else { continue }

                if let existing = latestWindowByKey[key] {
                    if window.scheduleUpdatedAt > existing.scheduleUpdatedAt {
                        latestWindowByKey[key] = window
                    }
                } else {
                    latestWindowByKey[key] = window
                }
            }
        }

        return latestWindowByKey.values.sorted { $0.modeStartUTC < $1.modeStartUTC }
    }

    static func tripWindow(
        key: String,
        tripLegs: [TripLeg],
        scheduleUpdatedAt: Date,
        crewBase: CrewBase,
        tzResolver: IATATimeZoneResolving
    ) -> TripWindow? {
        let legs = tripLegs
            .compactMap { $0.countdownLeg(tzResolver: tzResolver) }
            .sorted { $0.scheduledDepartureUTC < $1.scheduledDepartureUTC }
        guard let first = legs.first, let last = legs.last else { return nil }

        let reportUTC = reportUTC(for: first, crewBase: crewBase)
        let dutyStartUTC = reportUTC ?? first.scheduledDepartureUTC
        return TripWindow(
            key: key,
            legs: legs,
            dutyStartUTC: dutyStartUTC,
            dutyTimeLabel: reportUTC == nil ? "Departure" : "Report",
            modeStartUTC: dutyStartUTC.addingTimeInterval(-tripLeadBeforeDutyStart),
            modeEndUTC: last.scheduledArrivalUTC.addingTimeInterval(tripTailWindow),
            scheduleUpdatedAt: scheduleUpdatedAt
        )
    }

    static func snapshot(
        _ mode: WatchOperationalMode,
        now: Date,
        trip: TripPayload? = nil,
        reserve: ReservePayload? = nil,
        training: TrainingPayload? = nil,
        offDuty: OffDutyPayload? = nil
    ) -> WatchOperationalSnapshot {
        WatchOperationalSnapshot(mode: mode, generatedAtUTC: now,
                                 trip: trip, reserve: reserve, training: training, offDuty: offDuty)
    }

    static func tripPayload(from leg: FlightCountdownLeg, crewBase: CrewBase) -> TripPayload {
        return TripPayload(
            depIata: leg.departureAirportIATA,
            depTimeZoneIdentifier: leg.departureTimeZoneID,
            arrIata: leg.arrivalAirportIATA,
            arrTimeZoneIdentifier: leg.arrivalTimeZoneID,
            depUtc: leg.scheduledDepartureUTC,
            arrUtc: leg.scheduledArrivalUTC,
            reportUtc: reportUTC(for: leg, crewBase: crewBase)
        )
    }

    static func reportUTC(for leg: FlightCountdownLeg, crewBase: CrewBase) -> Date? {
        leg.departureAirportIATA == crewBase.reportAirportCode
            ? leg.scheduledDepartureUTC.addingTimeInterval(-reportLeadBeforeDep)
            : nil
    }

    static func reservePayload(from event: ManualOperationalEvent) -> ReservePayload {
        ReservePayload(
            domicile: event.crewBase.rawValue,
            ldtTimeZoneIdentifier: event.crewBase.timeZone.identifier,
            reserveType: event.code.rawValue,
            windowStartUtc: event.startUTC,
            windowEndUtc: event.endUTC
        )
    }

    static func trainingPayload(from event: ManualOperationalEvent, tz: TimeZone) -> TrainingPayload {
        TrainingPayload(
            eventName: event.code.rawValue,
            startUtc: event.startUTC,
            startLdtFormatted: formatHHmm(event.startUTC, tz: tz) + " LDT",
            dateLabelFormatted: formatShortDayLabel(event.startUTC, tz: tz)
        )
    }

    static func offDutyPayload(
        manualEvents: [ManualOperationalEvent],
        tripWindows: [TripWindow],
        tz: TimeZone,
        now: Date
    ) -> OffDutyPayload? {
        let nextManual = manualEvents.filter { $0.startUTC > now }.min { $0.startUTC < $1.startUTC }
        let nextTrip = tripWindows.filter { $0.dutyStartUTC > now }.min { $0.dutyStartUTC < $1.dutyStartUTC }

        switch (nextManual, nextTrip) {
        case let (.some(m), .some(t)):
            return m.startUTC <= t.dutyStartUTC ? offDutyFromManual(m, tz: tz) : offDutyFromTrip(t, tz: tz)
        case let (.some(m), .none):
            return offDutyFromManual(m, tz: tz)
        case let (.none, .some(t)):
            return offDutyFromTrip(t, tz: tz)
        case (.none, .none):
            return nil
        }
    }

    static func offDutyFromManual(_ event: ManualOperationalEvent, tz: TimeZone) -> OffDutyPayload {
        OffDutyPayload(
            nextDutyStartUtc: event.startUTC,
            nextDutyType: event.code.watchDutyTypeLabel,
            dutyTimeLabel: event.code.watchDutyTypeLabel,
            reportLdtFormatted: formatHHmm(event.startUTC, tz: tz) + " LDT",
            dateLabelFormatted: formatDateLabel(event.startUTC, tz: tz),
            dayOfWeekFormatted: formatDayOfWeek(event.startUTC, tz: tz)
        )
    }

    static func offDutyFromTrip(_ trip: TripWindow, tz: TimeZone) -> OffDutyPayload {
        OffDutyPayload(
            nextDutyStartUtc: trip.dutyStartUTC,
            nextDutyType: "TRIP",
            dutyTimeLabel: trip.dutyTimeLabel,
            reportLdtFormatted: formatHHmm(trip.dutyStartUTC, tz: tz) + " LDT",
            dateLabelFormatted: formatDateLabel(trip.dutyStartUTC, tz: tz),
            dayOfWeekFormatted: formatDayOfWeek(trip.dutyStartUTC, tz: tz)
        )
    }
}

// MARK: - Formatting helpers

private extension WatchSnapshotGenerator {

    static func formatHHmm(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.string(from: date)
    }

    static func formatDateLabel(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.string(from: date).uppercased()
    }

    static func formatDayOfWeek(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.string(from: date)
    }

    static func formatShortDayLabel(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.string(from: date)
    }
}

// MARK: - ManualOperationalCode Watch classification

private extension ManualOperationalCode {

    var isWatchReserveMode: Bool {
        switch self {
        case .reserveA, .reserveB, .reserveC, .reserveD, .lco, .rcid: return true
        case .hot, .cq12, .cq6: return false
        }
    }

    var isWatchTrainingMode: Bool {
        switch self {
        case .cq12, .cq6: return true
        default: return false
        }
    }

    var watchDutyTypeLabel: String {
        switch self {
        case .reserveA, .reserveB, .reserveC, .reserveD: return "RSV"
        case .lco:  return "LCO"
        case .rcid: return "RCID"
        case .hot:  return "HOT"
        case .cq12, .cq6: return "CQ"
        }
    }
}
