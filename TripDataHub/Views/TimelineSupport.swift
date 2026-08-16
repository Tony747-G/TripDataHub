import Foundation

struct TimelineDaySection: Identifiable {
    let id: String
    let label: String
    let isPast: Bool
    let legs: [TripLeg]
    let entries: [TimelineDutyEntry]

    init(
        id: String,
        label: String,
        isPast: Bool,
        legs: [TripLeg],
        entries: [TimelineDutyEntry]? = nil
    ) {
        self.id = id
        self.label = label
        self.isPast = isPast
        self.legs = legs
        self.entries = entries ?? legs.map { .leg($0) }
    }
}

enum TimelineDutyEntry: Identifiable {
    case leg(TripLeg)
    case manualOperational(ManualOperationalEvent)

    var id: String {
        switch self {
        case .leg(let leg):
            return "leg-\(leg.id.uuidString)"
        case .manualOperational(let event):
            return "manual-operational-\(event.id.uuidString)"
        }
    }

    var startUTC: Date? {
        switch self {
        case .leg(let leg):
            return LegConnectionTextBuilder.parseUTC(leg.depUTC)
        case .manualOperational(let event):
            return event.startUTC
        }
    }

    var endUTC: Date? {
        switch self {
        case .leg(let leg):
            return LegConnectionTextBuilder.parseUTC(leg.arrUTC)
        case .manualOperational(let event):
            return event.endUTC
        }
    }

    var leg: TripLeg? {
        if case .leg(let leg) = self { return leg }
        return nil
    }
}

struct TimelineLegData {
    let allLegs: [TripLeg]
    let nextLegByID: [UUID: TripLeg]
    let daySections: [TimelineDaySection]

    init(
        schedules: [PayPeriodSchedule],
        manualOperationalEvents: [ManualOperationalEvent] = [],
        displayTimeZone: TimeZone? = nil,
        now: Date = Date()
    ) {
        // Primary dedup: UUID — catches the same TripLeg object appearing in multiple
        // PayPeriodSchedule objects (pay-period boundary carry-over).
        var seenIDs = Set<UUID>()
        // Secondary dedup: flight-identity key — catches legs that were imported more than
        // once (each import generates a fresh UUID, so UUID dedup alone misses them).
        var seenKeys = Set<String>()
        let legs = schedules
            .flatMap(\.legs)
            .filter { leg in
                guard seenIDs.insert(leg.id).inserted else { return false }
                let key = "\(leg.depUTC ?? "")|\(leg.flight)|\(leg.depAirport)|\(leg.arrAirport)"
                return seenKeys.insert(key).inserted
            }
            .sorted { lhs, rhs in
                let lhsUTC = LegConnectionTextBuilder.parseUTC(lhs.depUTC)
                let rhsUTC = LegConnectionTextBuilder.parseUTC(rhs.depUTC)
                if let lhsUTC, let rhsUTC, lhsUTC != rhsUTC {
                    return lhsUTC < rhsUTC
                }
                if lhs.depLocal == rhs.depLocal {
                    if lhs.leg != rhs.leg { return lhs.leg < rhs.leg }
                    return lhs.flight < rhs.flight
                }
                return lhs.depLocal < rhs.depLocal
            }

        allLegs = legs
        let suffixMap = Self.pairingSuffixByPairingAndPeriod(from: legs)
        nextLegByID = Self.buildNextLegMap(from: legs, suffixMap: suffixMap)
        daySections = Self.buildDaySections(
            from: legs,
            manualOperationalEvents: manualOperationalEvents,
            displayTimeZone: displayTimeZone,
            now: now
        )
    }

    private static func buildDaySections(
        from legs: [TripLeg],
        manualOperationalEvents: [ManualOperationalEvent],
        displayTimeZone: TimeZone?,
        now: Date
    ) -> [TimelineDaySection] {
        var order: [String] = []
        var grouped: [String: [TimelineDutyEntry]] = [:]
        let entries = (
            legs.map { TimelineDutyEntry.leg($0) }
                + manualOperationalEvents.map { TimelineDutyEntry.manualOperational($0) }
        )
        .sorted { lhs, rhs in
            let lhsStart = lhs.startUTC ?? .distantFuture
            let rhsStart = rhs.startUTC ?? .distantFuture
            if lhsStart == rhsStart { return lhs.id < rhs.id }
            return lhsStart < rhsStart
        }

        for entry in entries {
            let key = dayKey(for: entry, displayTimeZone: displayTimeZone)
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(entry)
        }

        return order.map { key in
            let sectionEntries = grouped[key] ?? []
            let sectionLegs = sectionEntries.compactMap(\.leg)
            // INV-001: isPast uses UTC source of truth.
            // Use the latest UTC end/start across entries in this section.
            let latestUTC = sectionEntries.compactMap { entry in
                entry.endUTC ?? entry.startUTC
            }.max()

            let isPast: Bool
            if let latestUTC {
                isPast = latestUTC < now
            } else {
                // Fallback when UTC is missing: compare day key as local midnight.
                // Calendar is created with explicit gregorian identifier per INV-002.
                let dayStart = Calendar(identifier: .gregorian).startOfDay(for: now)
                isPast = SharedDateFormatters.localDayInput.date(from: key).map { $0 < dayStart } ?? false
            }

            return TimelineDaySection(
                id: key,
                label: ScheduleDateText.dayHeaderLabel(from: key),
                isPast: isPast,
                legs: sectionLegs,
                entries: sectionEntries
            )
        }
    }

    private static func dayKey(for entry: TimelineDutyEntry, displayTimeZone: TimeZone?) -> String {
        switch entry {
        case .leg(let leg):
            return ScheduleDateText.datePart(from: leg.depLocal)
        case .manualOperational(let event):
            if let displayTimeZone {
                return localDayKeyFormatter(for: displayTimeZone.identifier).string(from: event.startUTC)
            }
            return localDayKeyFormatter(for: event.crewBase.timeZone.identifier).string(from: event.startUTC)
        }
    }

    private static func localDayKeyFormatter(for tzID: String) -> DateFormatter {
        if let cached = localDayKeyFormatters[tzID] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: tzID)
        formatter.dateFormat = "yyyy-MM-dd"
        localDayKeyFormatters[tzID] = formatter
        return formatter
    }

    private static var localDayKeyFormatters: [String: DateFormatter] = [:]

    private static func buildNextLegMap(from legs: [TripLeg], suffixMap: [String: String]) -> [UUID: TripLeg] {
        var map: [UUID: TripLeg] = [:]
        let grouped = Dictionary(grouping: legs) { leg in
            effectivePairingKey(for: leg, suffixMap: suffixMap)
        }

        for legsForPairing in grouped.values {
            let sorted = legsForPairing.sorted { lhs, rhs in
                let lhsUTC = LegConnectionTextBuilder.parseUTC(lhs.depUTC)
                let rhsUTC = LegConnectionTextBuilder.parseUTC(rhs.depUTC)
                if let lhsUTC, let rhsUTC {
                    if lhsUTC == rhsUTC { return lhs.leg < rhs.leg }
                    return lhsUTC < rhsUTC
                }
                if lhs.depLocal == rhs.depLocal { return lhs.leg < rhs.leg }
                return lhs.depLocal < rhs.depLocal
            }
            guard sorted.count > 1 else { continue }
            for i in 0..<(sorted.count - 1) {
                map[sorted[i].id] = sorted[i + 1]
            }
        }

        return map
    }

    private static func pairingSuffixByPairingAndPeriod(from legs: [TripLeg]) -> [String: String] {
        var periodsByPairing: [String: Set<String>] = [:]
        for leg in legs {
            periodsByPairing[leg.pairing, default: []].insert(leg.payPeriod)
        }

        var suffixByKey: [String: String] = [:]
        for (pairing, periodSet) in periodsByPairing {
            let periods = periodSet.sorted { lhs, rhs in
                payPeriodOrder(from: lhs) > payPeriodOrder(from: rhs)
            }
            for (index, period) in periods.enumerated() {
                let suffix: String
                if index == 0 {
                    suffix = ""
                } else if index == 1 {
                    suffix = "-past"
                } else {
                    suffix = "-past-\(index - 1)"
                }
                suffixByKey["\(pairing)|\(period)"] = suffix
            }
        }

        return suffixByKey
    }

    private static func effectivePairingKey(for leg: TripLeg, suffixMap: [String: String]) -> String {
        let suffix = suffixMap["\(leg.pairing)|\(leg.payPeriod)"] ?? ""
        return "\(leg.pairing)\(suffix)"
    }

    private static func payPeriodOrder(from label: String) -> Int {
        let cleaned = label.replacingOccurrences(of: "PP", with: "")
        let parts = cleaned.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let period = Int(parts[1])
        else {
            return 0
        }
        return year * 100 + period
    }
}

enum TimelineTripStartSupport {
    /// Returns the first chronological leg of each distinct pay-period/trip pair.
    /// `legs` is expected to be in Timeline order (UTC first, local time fallback).
    static func startLegIDs(in legs: [TripLeg]) -> Set<UUID> {
        var seenTrips = Set<String>()
        var result = Set<UUID>()
        for leg in legs {
            let tripKey = "\(leg.payPeriod)|\(leg.pairing)"
            if seenTrips.insert(tripKey).inserted {
                result.insert(leg.id)
            }
        }
        return result
    }
}

// MARK: - Shared rendering helpers

enum TimelinePastStateSupport {
    static func isPastFlightRow(
        arrivalUTC: Date?,
        departureUTC: Date?,
        fallbackArrival: Date? = nil,
        fallbackDeparture: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        let reference = arrivalUTC
            ?? fallbackArrival
            ?? departureUTC
            ?? fallbackDeparture
        return reference.map { $0 < now } ?? false
    }
}

/// Icon rendering helpers shared by TimelineTabView and ScheduleTimelineRendererView.
enum TimelineLegIconSupport {
    static func codePoint(for status: String) -> Int {
        let normalized = status.uppercased()
        if normalized == "GND" { return 58673 }
        if normalized == "DH" || normalized == "CML" { return 58729 }
        return 58681
    }

    static func fallbackSystemName(for status: String) -> String {
        let normalized = status.uppercased()
        if normalized == "GND" { return "car.fill" }
        if normalized == "DH" || normalized == "CML" { return "paperplane.fill" }
        return "airplane"
    }
}

/// Layover card logic shared by TimelineTabView and ScheduleTimelineRendererView.
enum TimelineLayoverSupport {
    struct RestInfo {
        let dutyEndUTC: Date
        let dutyStartUTC: Date
        let totalMinutes: Int

        func remainingMinutes(at now: Date = Date()) -> Int? {
            guard now >= dutyEndUTC, now < dutyStartUTC else { return nil }
            return max(0, Int(dutyStartUTC.timeIntervalSince(now) / 60))
        }

        func isPast(at now: Date = Date()) -> Bool {
            dutyStartUTC < now
        }
    }

    /// Returns true when the gap between arrival and next departure is ≥ 3 h (same pairing).
    static func shouldShow(arrDate: Date?, nextDepDate: Date?, samePairing: Bool) -> Bool {
        guard samePairing, let arr = arrDate, let dep = nextDepDate else { return false }
        return Int(dep.timeIntervalSince(arr) / 60) >= 180
    }

    /// Rest begins at duty end (arrival + 30m) and ends at the next duty start.
    /// The next duty starts 60m before departure only when both airports are in the Lower 48;
    /// Alaska, Hawaii, Asia, Europe, and unclassified routes use 90m.
    static func restInfo(arrDate: Date?, nextLeg: TripLeg?) -> RestInfo? {
        guard let arr = arrDate,
              let nextLeg,
              let dep = LegConnectionTextBuilder.parseUTC(nextLeg.depUTC)
        else {
            return nil
        }
        let dutyEnd = arr.addingTimeInterval(30 * 60)
        let reportLeadMinutes = ReportLeadTimePolicy.minutes(
            originAirport: nextLeg.depAirport,
            destinationAirport: nextLeg.arrAirport
        )
        let dutyStart = dep.addingTimeInterval(TimeInterval(-reportLeadMinutes * 60))
        guard dutyStart > dutyEnd else { return nil }
        return RestInfo(
            dutyEndUTC: dutyEnd,
            dutyStartUTC: dutyStart,
            totalMinutes: Int(dutyStart.timeIntervalSince(dutyEnd) / 60)
        )
    }

    /// "H:MM" rest string from duty-end/start rules, falling back to the stored field.
    static func durationText(arrDate: Date?, nextLeg: TripLeg?, fallbackDuration: String?) -> String {
        if let info = restInfo(arrDate: arrDate, nextLeg: nextLeg) {
            return durationText(minutes: info.totalMinutes)
        }
        return fallbackDuration ?? ""
    }

    static func remainingText(arrDate: Date?, nextLeg: TripLeg?, now: Date = Date()) -> String {
        guard let minutes = restInfo(arrDate: arrDate, nextLeg: nextLeg)?.remainingMinutes(at: now) else {
            return ""
        }
        return durationText(minutes: minutes)
    }

    static func isPastLayover(arrDate: Date?, nextLeg: TripLeg?, now: Date = Date()) -> Bool {
        if let info = restInfo(arrDate: arrDate, nextLeg: nextLeg) {
            return info.isPast(at: now)
        }
        guard let arrDate else { return false }
        return arrDate < now
    }

    private static func durationText(minutes: Int) -> String {
        let safeMinutes = max(0, minutes)
        return "\(safeMinutes / 60):\(String(format: "%02d", safeMinutes % 60))"
    }

}

/// "+Nd" / "−Nd" day-shift label suffix, or empty string for zero shift.
func timelineDiffLabel(_ diff: Int) -> String {
    guard diff != 0 else { return "" }
    let sign = diff > 0 ? "+" : ""
    return " (\(sign)\(diff)d)"
}
