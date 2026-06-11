import Foundation

private struct BidPeriodDefinition {
    let id: String
    let startDateString: String
    let payPeriodCount: Int
    let ppLabels: [String]
}

private let bidPeriodDefinitions: [BidPeriodDefinition] = [
    .init(id: "BP26-01", startDateString: "2025-11-30", payPeriodCount: 2, ppLabels: ["PP25-13", "PP26-01"]),
    .init(id: "BP26-02", startDateString: "2026-01-25", payPeriodCount: 2, ppLabels: ["PP26-02", "PP26-03"]),
    .init(id: "BP26-03", startDateString: "2026-03-22", payPeriodCount: 2, ppLabels: ["PP26-04", "PP26-05"]),
    .init(id: "BP26-04", startDateString: "2026-05-17", payPeriodCount: 2, ppLabels: ["PP26-06", "PP26-07"]),
    .init(id: "BP26-05", startDateString: "2026-07-12", payPeriodCount: 2, ppLabels: ["PP26-08", "PP26-09"]),
    .init(id: "BP26-06", startDateString: "2026-09-06", payPeriodCount: 2, ppLabels: ["PP26-10", "PP26-11"]),
    .init(id: "BP26-07", startDateString: "2026-11-01", payPeriodCount: 1, ppLabels: ["PP26-12"]),
    .init(id: "BP27-01", startDateString: "2026-11-29", payPeriodCount: 2, ppLabels: ["PP26-13", "PP27-01"]),
    .init(id: "BP27-02", startDateString: "2027-01-24", payPeriodCount: 2, ppLabels: ["PP27-02", "PP27-03"]),
    .init(id: "BP27-03", startDateString: "2027-03-21", payPeriodCount: 2, ppLabels: ["PP27-04", "PP27-05"]),
    .init(id: "BP27-04", startDateString: "2027-05-16", payPeriodCount: 2, ppLabels: ["PP27-06", "PP27-07"]),
    .init(id: "BP27-05", startDateString: "2027-07-11", payPeriodCount: 2, ppLabels: ["PP27-08", "PP27-09"]),
    .init(id: "BP27-06", startDateString: "2027-09-05", payPeriodCount: 2, ppLabels: ["PP27-10", "PP27-11"]),
    .init(id: "BP27-07", startDateString: "2027-10-31", payPeriodCount: 2, ppLabels: ["PP27-12", "PP27-13"])
]

/// Returns the Pay Period label ("PP26-05") for the given UTC date and domicile
/// by looking up the BP and using payPeriodIndex (0 = first PP, 1 = second PP).
/// Falls back to nil if the date is outside all defined BPs.
func resolvePayPeriodLabel(for dateUTC: Date, domicile: String = DomicileSupport.defaultDomicile) -> String? {
    guard let bp = bidPeriod(for: dateUTC, domicile: domicile),
          let matchingDef = bidPeriodDefinitions.first(where: { $0.id == bp.id })
    else { return nil }

    let calendar = bidPeriodDomicileCalendar(for: domicile)
    let startBoundaryUTC = bidPeriodStartBoundaryUTC(for: matchingDef, domicile: domicile)
    let ppIndex = (0..<matchingDef.ppLabels.count).last { index in
        guard let boundary = calendar.date(byAdding: .day, value: index * 28, to: startBoundaryUTC) else {
            return false
        }
        return boundary <= dateUTC
    } ?? 0
    guard ppIndex < matchingDef.ppLabels.count else { return nil }
    return matchingDef.ppLabels[ppIndex]
}

private let bidPeriodUTCCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

/// Bid-period definitions are a fixed table and domiciles are a small fixed set,
/// so every derived value (calendar, boundary date, full CalendarBidPeriod) is
/// deterministic and cacheable forever. Uncached, one bidPeriod(for:) lookup
/// created ~42 DateFormatters (14 definitions × 3 boundary computations) — the
/// dominant cost behind slow calendar opens.
private final class BidPeriodComputationCache: @unchecked Sendable {
    static let shared = BidPeriodComputationCache()
    private let lock = NSLock()
    private var calendarsByTimeZoneID: [String: Calendar] = [:]
    private var boundariesByKey: [String: Date] = [:]
    private var bidPeriodsByKey: [String: CalendarBidPeriod] = [:]

    func calendar(for timeZone: TimeZone) -> Calendar {
        lock.lock()
        defer { lock.unlock() }
        if let cached = calendarsByTimeZoneID[timeZone.identifier] { return cached }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendarsByTimeZoneID[timeZone.identifier] = calendar
        return calendar
    }

    func boundary(raw: String, timeZone: TimeZone, compute: () -> Date) -> Date {
        let key = "\(raw)|\(timeZone.identifier)"
        lock.lock()
        if let cached = boundariesByKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        boundariesByKey[key] = value
        lock.unlock()
        return value
    }

    func bidPeriod(id: String, timeZone: TimeZone, compute: () -> CalendarBidPeriod) -> CalendarBidPeriod {
        let key = "\(id)|\(timeZone.identifier)"
        lock.lock()
        if let cached = bidPeriodsByKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = compute()
        lock.lock()
        bidPeriodsByKey[key] = value
        lock.unlock()
        return value
    }
}

private func bidPeriodDomicileCalendar(for domicile: String?) -> Calendar {
    BidPeriodComputationCache.shared.calendar(for: DomicileSupport.timeZone(for: domicile))
}

private func bidPeriodBoundaryUTCDate(_ raw: String, domicile: String?) -> Date {
    let calendar = bidPeriodDomicileCalendar(for: domicile)
    return BidPeriodComputationCache.shared.boundary(raw: raw, timeZone: calendar.timeZone) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        // PP/BP operational boundaries are 03:00 Local Domicile Time for the pilot's base.
        // The returned Date is UTC absolute time.
        guard let date = formatter.date(from: "\(raw) 03:00") else {
            preconditionFailure("Invalid bid period date: \(raw)")
        }
        return date
    }
}

private func bidPeriodStartBoundaryUTC(for definition: BidPeriodDefinition, domicile: String?) -> Date {
    bidPeriodBoundaryUTCDate(definition.startDateString, domicile: domicile)
}

private func bidPeriodEndBoundaryUTC(for definition: BidPeriodDefinition, domicile: String?) -> Date {
    let calendar = bidPeriodDomicileCalendar(for: domicile)
    let startBoundaryUTC = bidPeriodStartBoundaryUTC(for: definition, domicile: domicile)
    return calendar.date(
        byAdding: .day,
        value: definition.payPeriodCount * 28,
        to: startBoundaryUTC
    ) ?? startBoundaryUTC
}

func bidPeriod(for dateUTC: Date, domicile: String = DomicileSupport.defaultDomicile) -> CalendarBidPeriod? {
    let matchingDefinition = bidPeriodDefinitions
        .compactMap { definition -> (definition: BidPeriodDefinition, startBoundaryUTC: Date)? in
            let startBoundaryUTC = bidPeriodStartBoundaryUTC(for: definition, domicile: domicile)
            let endBoundaryUTC = bidPeriodEndBoundaryUTC(for: definition, domicile: domicile)
            guard startBoundaryUTC <= dateUTC, dateUTC < endBoundaryUTC else { return nil }
            return (definition, startBoundaryUTC)
        }
        .max(by: { $0.startBoundaryUTC < $1.startBoundaryUTC })?
        .definition

    guard let matchingDefinition else {
        return nil
    }

    return cachedBidPeriod(for: matchingDefinition, domicile: domicile)
}

private func cachedBidPeriod(for definition: BidPeriodDefinition, domicile: String) -> CalendarBidPeriod {
    let timeZone = DomicileSupport.timeZone(for: domicile)
    return BidPeriodComputationCache.shared.bidPeriod(id: definition.id, timeZone: timeZone) {
        let startBoundaryUTC = bidPeriodStartBoundaryUTC(for: definition, domicile: domicile)
        return CalendarBidPeriod(
            id: definition.id,
            startDateUTC: startBoundaryUTC,
            endDateUTC: bidPeriodEndBoundaryUTC(for: definition, domicile: domicile),
            days: generateBidPeriodDays(
                startUTC: startBoundaryUTC,
                payPeriodCount: definition.payPeriodCount,
                domicile: domicile
            )
        )
    }
}

func bidPeriod(identifier: String, domicile: String = DomicileSupport.defaultDomicile) -> CalendarBidPeriod? {
    let cleaned = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let definition = bidPeriodDefinitions.first(where: { $0.id == cleaned }) else {
        return nil
    }

    return cachedBidPeriod(for: definition, domicile: domicile)
}

func bidPeriodWindow(
    centeredOn center: CalendarBidPeriod,
    previousCount: Int,
    nextCount: Int,
    domicile: String = DomicileSupport.defaultDomicile
) -> [CalendarBidPeriod] {
    guard previousCount >= 0,
          nextCount >= 0,
          let centerIndex = bidPeriodDefinitions.firstIndex(where: { $0.id == center.id })
    else {
        return [center]
    }

    let lowerBound = max(0, centerIndex - previousCount)
    let upperBound = min(bidPeriodDefinitions.count - 1, centerIndex + nextCount)

    return bidPeriodDefinitions[lowerBound...upperBound].compactMap {
        bidPeriod(identifier: $0.id, domicile: domicile)
    }
}

func generateBidPeriodDays(startUTC: Date, payPeriodCount: Int = 2) -> [CalendarDay] {
    generateBidPeriodDays(
        startUTC: startUTC,
        payPeriodCount: payPeriodCount,
        domicile: DomicileSupport.defaultDomicile
    )
}

func generateBidPeriodDays(
    startUTC: Date,
    payPeriodCount: Int,
    domicile: String
) -> [CalendarDay] {
    let domicileCalendar = bidPeriodDomicileCalendar(for: domicile)
    let normalizedStartUTC = domicileCalendar.startOfDay(for: startUTC)
    return (0..<(payPeriodCount * 28)).compactMap { index in
        guard let dayStartUTC = domicileCalendar.date(byAdding: .day, value: index, to: normalizedStartUTC),
              let dayEndUTC = domicileCalendar.date(byAdding: .day, value: 1, to: dayStartUTC)
        else {
            return nil
        }

        return CalendarDay(
            index: index,
            weekIndex: index / 7,
            weekdayIndex: index % 7,
            payPeriodIndex: index / 28,
            dayStartUTC: dayStartUTC,
            dayEndUTC: dayEndUTC,
            displayDateKey: dayKey(from: dayStartUTC, timeZone: domicileCalendar.timeZone)
        )
    }
}

func bidPeriodOrder(for identifier: String) -> Int? {
    let cleaned = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let range = cleaned.range(of: #"BP(\d{2})-(\d{2})"#, options: .regularExpression)
    guard let range else { return nil }
    let match = String(cleaned[range])
    let parts = match.replacingOccurrences(of: "BP", with: "").split(separator: "-")
    guard parts.count == 2,
          let year = Int(parts[0]),
          let period = Int(parts[1]) else {
        return nil
    }
    return year * 100 + period
}

func retainedBidPeriodOrders(
    currentDateUTC: Date,
    previousCount: Int,
    domicile: String = DomicileSupport.defaultDomicile
) -> Set<Int>? {
    guard previousCount >= 0,
          let currentBidPeriod = bidPeriod(for: currentDateUTC, domicile: domicile),
          let currentIndex = bidPeriodDefinitions.firstIndex(where: { $0.id == currentBidPeriod.id }) else {
        return nil
    }

    let startIndex = max(0, currentIndex - previousCount)
    let retainedDefinitions = bidPeriodDefinitions[startIndex...]
    return Set(retainedDefinitions.compactMap { bidPeriodOrder(for: $0.id) })
}
