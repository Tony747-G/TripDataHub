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
        let legs = schedules
            .flatMap(\.legs)
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

        let dayStart = Calendar.current.startOfDay(for: now)

        return order.map { key in
            let isPast: Bool
            if let day = SharedDateFormatters.localDayInput.date(from: key) {
                isPast = day < dayStart
            } else {
                isPast = false
            }

            return TimelineDaySection(
                id: key,
                label: ScheduleDateText.dayHeaderLabel(from: key),
                isPast: isPast,
                legs: grouped[key] ?? []
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
    /// Returns true when the gap between arrival and next departure is ≥ 3 h (same pairing).
    static func shouldShow(arrDate: Date?, nextDepDate: Date?, samePairing: Bool) -> Bool {
        guard samePairing, let arr = arrDate, let dep = nextDepDate else { return false }
        return Int(dep.timeIntervalSince(arr) / 60) >= 180
    }

    /// "H:MM" duration string from UTC dates, falling back to the stored field.
    static func durationText(arrDate: Date?, nextDepDate: Date?, fallbackDuration: String?) -> String {
        if let arr = arrDate, let dep = nextDepDate {
            let mins = max(0, Int(dep.timeIntervalSince(arr) / 60))
            return "\(mins / 60):\(String(format: "%02d", mins % 60))"
        }
        return fallbackDuration ?? ""
    }
}

/// "+Nd" / "−Nd" day-shift label suffix, or empty string for zero shift.
func timelineDiffLabel(_ diff: Int) -> String {
    guard diff != 0 else { return "" }
    let sign = diff > 0 ? "+" : ""
    return " (\(sign)\(diff)d)"
}
