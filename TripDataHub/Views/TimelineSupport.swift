import Foundation

struct TimelineDaySection: Identifiable {
    let id: String
    let label: String
    let isPast: Bool
    let legs: [TripLeg]
}

struct TimelineLegData {
    let allLegs: [TripLeg]
    let nextLegByID: [UUID: TripLeg]
    let daySections: [TimelineDaySection]

    init(schedules: [PayPeriodSchedule], now: Date = Date()) {
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
                if lhs.depLocal == rhs.depLocal {
                    return lhs.flight < rhs.flight
                }
                return lhs.depLocal < rhs.depLocal
            }

        allLegs = legs
        let suffixMap = Self.pairingSuffixByPairingAndPeriod(from: legs)
        nextLegByID = Self.buildNextLegMap(from: legs, suffixMap: suffixMap)
        daySections = Self.buildDaySections(from: legs, now: now)
    }

    private static func buildDaySections(from legs: [TripLeg], now: Date) -> [TimelineDaySection] {
        var order: [String] = []
        var grouped: [String: [TripLeg]] = [:]

        for leg in legs {
            let key = ScheduleDateText.datePart(from: leg.depLocal)
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(leg)
        }

        return order.map { key in
            let sectionLegs = grouped[key] ?? []
            // INV-001: isPast uses UTC source of truth.
            // Use the latest UTC arrival (or departure) across legs in this section.
            let latestUTC = sectionLegs.compactMap {
                LegConnectionTextBuilder.parseUTC($0.arrUTC)
                    ?? LegConnectionTextBuilder.parseUTC($0.depUTC)
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
                legs: sectionLegs
            )
        }
    }

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
        if normalized == "DH" || normalized == "CML" { return 58729 }
        return 58681
    }

    static func fallbackSystemName(for status: String) -> String {
        let normalized = status.uppercased()
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
    /// The next duty starts 90m before departure, except flights wholly inside
    /// CONUS-48, Asia, or Europe, where report is 60m before departure.
    static func restInfo(arrDate: Date?, nextLeg: TripLeg?) -> RestInfo? {
        guard let arr = arrDate,
              let nextLeg,
              let dep = LegConnectionTextBuilder.parseUTC(nextLeg.depUTC)
        else {
            return nil
        }
        let dutyEnd = arr.addingTimeInterval(30 * 60)
        let reportLeadMinutes = reportLeadMinutes(for: nextLeg)
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

    private static func reportLeadMinutes(for nextLeg: TripLeg) -> Int {
        flightIsWhollyInsideReducedReportRegion(nextLeg) ? 60 : 90
    }

    private static func flightIsWhollyInsideReducedReportRegion(_ leg: TripLeg) -> Bool {
        guard let depRegion = reportRegion(for: leg.depAirport),
              let arrRegion = reportRegion(for: leg.arrAirport)
        else {
            return false
        }
        return depRegion == arrRegion
    }

    private static func reportRegion(for airport: String) -> String? {
        let normalized = airport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let tzID = IATATimeZoneResolver.shared.resolve(normalized) else { return nil }
        if tzID.hasPrefix("Asia/") { return "asia" }
        if tzID.hasPrefix("Europe/") { return "europe" }
        if lower48TimeZoneIDs.contains(tzID) { return "conus48" }
        return nil
    }

    private static let lower48TimeZoneIDs: Set<String> = [
        "America/New_York",
        "America/Detroit",
        "America/Kentucky/Louisville",
        "America/Kentucky/Monticello",
        "America/Indiana/Indianapolis",
        "America/Indiana/Knox",
        "America/Indiana/Vincennes",
        "America/Chicago",
        "America/Menominee",
        "America/North_Dakota/Center",
        "America/North_Dakota/New_Salem",
        "America/North_Dakota/Beulah",
        "America/Denver",
        "America/Boise",
        "America/Phoenix",
        "America/Los_Angeles"
    ]
}

/// "+Nd" / "−Nd" day-shift label suffix, or empty string for zero shift.
func timelineDiffLabel(_ diff: Int) -> String {
    guard diff != 0 else { return "" }
    let sign = diff > 0 ? "+" : ""
    return " (\(sign)\(diff)d)"
}
