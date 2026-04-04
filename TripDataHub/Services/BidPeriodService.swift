import Foundation

private struct BidPeriodDefinition {
    let id: String
    let startDateUTC: Date
    let payPeriodCount: Int
}

private let bidPeriodDefinitions: [BidPeriodDefinition] = [
    .init(id: "BP26-01", startDateUTC: bidPeriodUTCDate("2025-11-30"), payPeriodCount: 2),
    .init(id: "BP26-02", startDateUTC: bidPeriodUTCDate("2026-01-25"), payPeriodCount: 2),
    .init(id: "BP26-03", startDateUTC: bidPeriodUTCDate("2026-03-22"), payPeriodCount: 2),
    .init(id: "BP26-04", startDateUTC: bidPeriodUTCDate("2026-05-17"), payPeriodCount: 2),
    .init(id: "BP26-05", startDateUTC: bidPeriodUTCDate("2026-07-12"), payPeriodCount: 2),
    .init(id: "BP26-06", startDateUTC: bidPeriodUTCDate("2026-09-06"), payPeriodCount: 2),
    .init(id: "BP26-07", startDateUTC: bidPeriodUTCDate("2026-11-01"), payPeriodCount: 1),
    .init(id: "BP27-01", startDateUTC: bidPeriodUTCDate("2026-11-29"), payPeriodCount: 2),
    .init(id: "BP27-02", startDateUTC: bidPeriodUTCDate("2027-01-24"), payPeriodCount: 2),
    .init(id: "BP27-03", startDateUTC: bidPeriodUTCDate("2027-03-21"), payPeriodCount: 2),
    .init(id: "BP27-04", startDateUTC: bidPeriodUTCDate("2027-05-16"), payPeriodCount: 2),
    .init(id: "BP27-05", startDateUTC: bidPeriodUTCDate("2027-07-11"), payPeriodCount: 2),
    .init(id: "BP27-06", startDateUTC: bidPeriodUTCDate("2027-09-05"), payPeriodCount: 2)
]

private let bidPeriodUTCCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

private func bidPeriodUTCDate(_ raw: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = bidPeriodUTCCalendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = bidPeriodUTCCalendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: raw) else {
        preconditionFailure("Invalid bid period date: \(raw)")
    }
    return date
}

func bidPeriod(for dateUTC: Date) -> CalendarBidPeriod? {
    let matchingDefinition = bidPeriodDefinitions
        .filter { definition in
            let endDateUTC = bidPeriodUTCCalendar.date(byAdding: .day, value: definition.payPeriodCount * 28, to: definition.startDateUTC) ?? definition.startDateUTC
            return definition.startDateUTC <= dateUTC && dateUTC < endDateUTC
        }
        .max(by: { $0.startDateUTC < $1.startDateUTC })

    guard let matchingDefinition else {
        return nil
    }

    let days = generateBidPeriodDays(startUTC: matchingDefinition.startDateUTC, payPeriodCount: matchingDefinition.payPeriodCount)
    return CalendarBidPeriod(
        id: matchingDefinition.id,
        startDateUTC: matchingDefinition.startDateUTC,
        endDateUTC: days.last?.dayEndUTC ?? matchingDefinition.startDateUTC,
        days: days
    )
}

func generateBidPeriodDays(startUTC: Date, payPeriodCount: Int = 2) -> [CalendarDay] {
    let normalizedStartUTC = bidPeriodUTCCalendar.startOfDay(for: startUTC)
    return (0..<(payPeriodCount * 28)).compactMap { index in
        guard let dayStartUTC = bidPeriodUTCCalendar.date(byAdding: .day, value: index, to: normalizedStartUTC),
              let dayEndUTC = bidPeriodUTCCalendar.date(byAdding: .day, value: 1, to: dayStartUTC)
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
            displayDateKey: dayKey(from: dayStartUTC, timeZone: bidPeriodUTCCalendar.timeZone)
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

func retainedBidPeriodOrders(currentDateUTC: Date, previousCount: Int) -> Set<Int>? {
    guard previousCount >= 0,
          let currentBidPeriod = bidPeriod(for: currentDateUTC),
          let currentIndex = bidPeriodDefinitions.firstIndex(where: { $0.id == currentBidPeriod.id }) else {
        return nil
    }

    let startIndex = max(0, currentIndex - previousCount)
    let retainedDefinitions = bidPeriodDefinitions[startIndex...]
    return Set(retainedDefinitions.compactMap { bidPeriodOrder(for: $0.id) })
}
