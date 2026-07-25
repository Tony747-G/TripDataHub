import Foundation

enum BidPeriodCalendarRuleEventCategory: String, Codable, Equatable, Sendable {
    case bid
    case financial
}

enum BidPeriodCalendarRuleEventKind: String, Codable, Equatable, Sendable {
    case bidPackageOut
    case scheduleBidClose
    case vtoPublished
    case vtoBidClose
    case littAccepted
    case payDay
    case enhancedPayDay
}

struct BidPeriodCalendarRuleEvent: Codable, Equatable, Sendable {
    let id: String
    let category: BidPeriodCalendarRuleEventCategory
    let kind: BidPeriodCalendarRuleEventKind
    let title: String
    let compactTitle: String
    let dateKey: String
}

enum BidPeriodCalendarEventService {
    private static let smallCheckBase = "2025-12-29"
    private static let bigCheckBase = "2026-01-12"

    private static let bidPackageOutByBP: [(String, String)] = [
        ("2025-12-25", "BP26-02"),
        ("2026-02-19", "BP26-03"),
        ("2026-04-16", "BP26-04"),
        ("2026-06-11", "BP26-05"),
        ("2026-08-06", "BP26-06"),
        ("2026-10-01", "BP26-07"),
        ("2026-10-29", "BP27-01"),
        ("2026-12-24", "BP27-02")
    ]

    private static let caBidCloseByBP: [(String, String)] = [
        ("2026-01-01", "BP26-02"),
        ("2026-02-26", "BP26-03"),
        ("2026-04-23", "BP26-04"),
        ("2026-06-18", "BP26-05"),
        ("2026-08-13", "BP26-06"),
        ("2026-10-08", "BP26-07"),
        ("2026-11-05", "BP27-01"),
        ("2026-12-31", "BP27-02")
    ]

    private static let smallCheckBaseDay = epochDay(from: smallCheckBase)
    private static let bigCheckBaseDay = epochDay(from: bigCheckBase)
    private static let captainBidEvents = buildBidEvents(qualification: .captain)
    private static let firstOfficerBidEvents = buildBidEvents(qualification: .firstOfficer)

    static func events(
        in bidPeriod: CalendarBidPeriod,
        qualification: PilotQualification
    ) -> [BidPeriodCalendarRuleEvent] {
        let dateKeys = Set(bidPeriod.days.map(\.displayDateKey))
        return dateKeys
            .flatMap { events(on: $0, qualification: qualification) }
            .sorted(by: eventSort)
    }

    static func events(
        on dateKey: String,
        qualification: PilotQualification
    ) -> [BidPeriodCalendarRuleEvent] {
        bidEvents(on: dateKey, qualification: qualification) + financialEvents(on: dateKey)
    }

    static func bidEvents(
        on dateKey: String,
        qualification: PilotQualification
    ) -> [BidPeriodCalendarRuleEvent] {
        cachedBidEvents(for: qualification)
            .filter { $0.dateKey == dateKey }
            .sorted(by: eventSort)
    }

    private static func cachedBidEvents(
        for qualification: PilotQualification
    ) -> [BidPeriodCalendarRuleEvent] {
        switch qualification {
        case .captain: captainBidEvents
        case .firstOfficer: firstOfficerBidEvents
        }
    }

    static func financialEvents(on dateKey: String) -> [BidPeriodCalendarRuleEvent] {
        guard let day = epochDay(from: dateKey) else { return [] }
        var events: [BidPeriodCalendarRuleEvent] = []
        if let base = smallCheckBaseDay, day >= base, (day - base) % 28 == 0 {
            events.append(BidPeriodCalendarRuleEvent(
                id: "financial-pay-day-\(dateKey)",
                category: .financial,
                kind: .payDay,
                title: "Pay Day",
                compactTitle: "PAY DAY",
                dateKey: dateKey
            ))
        }
        if let base = bigCheckBaseDay, day >= base, (day - base) % 28 == 0 {
            events.append(BidPeriodCalendarRuleEvent(
                id: "financial-enhanced-pay-day-\(dateKey)",
                category: .financial,
                kind: .enhancedPayDay,
                title: "+Pay Day",
                compactTitle: "+PAY DAY",
                dateKey: dateKey
            ))
        }
        return events.sorted(by: eventSort)
    }

    private static func buildBidEvents(
        qualification: PilotQualification
    ) -> [BidPeriodCalendarRuleEvent] {
        var events: [BidPeriodCalendarRuleEvent] = bidPackageOutByBP.map { dateKey, bp in
            BidPeriodCalendarRuleEvent(
                id: "bid-package-\(bp)",
                category: .bid,
                kind: .bidPackageOut,
                title: "Bid Package Out \(bp)",
                compactTitle: "BID PACKAGE OUT",
                dateKey: dateKey
            )
        }

        for (closeDate, bp) in caBidCloseByBP {
            for definition in derivedBidEvents(for: qualification) {
                guard let dateKey = dateKey(byAddingDays: definition.offset, to: closeDate) else {
                    continue
                }
                events.append(BidPeriodCalendarRuleEvent(
                    id: "\(definition.idPrefix)-\(bp)",
                    category: .bid,
                    kind: definition.kind,
                    title: "\(definition.title) \(bp)",
                    compactTitle: definition.compactTitle,
                    dateKey: dateKey
                ))
            }
        }
        return events.sorted(by: eventSort)
    }

    private static func derivedBidEvents(
        for qualification: PilotQualification
    ) -> [(offset: Int, title: String, compactTitle: String, idPrefix: String, kind: BidPeriodCalendarRuleEventKind)] {
        switch qualification {
        case .captain:
            return [
                (0, "Schedule Bid Close", "SCHD BID CLOSE", "ca-bid-close", .scheduleBidClose),
                (10, "VTO Published", "VTO PUBLISHED", "ca-vto-published", .vtoPublished),
                (12, "VTO Bid Close", "VTO BID CLOSE", "ca-vto-close", .vtoBidClose),
                (18, "LITT Accepted", "LITT ACCEPT", "ca-litt", .littAccepted)
            ]
        case .firstOfficer:
            return [
                (4, "Schedule Bid Close", "SCHD BID CLOSE", "fo-bid-close", .scheduleBidClose),
                (11, "VTO Published", "VTO PUBLISHED", "fo-vto-published", .vtoPublished),
                (13, "VTO Bid Close", "VTO BID CLOSE", "fo-vto-close", .vtoBidClose),
                (20, "LITT Accepted", "LITT ACCEPT", "fo-litt", .littAccepted)
            ]
        }
    }

    private static func eventSort(
        _ lhs: BidPeriodCalendarRuleEvent,
        _ rhs: BidPeriodCalendarRuleEvent
    ) -> Bool {
        (lhs.dateKey, lhs.category.rawValue, lhs.title, lhs.id)
            < (rhs.dateKey, rhs.category.rawValue, rhs.title, rhs.id)
    }

    private static func epochDay(from dateKey: String) -> Int? {
        guard let date = dateFormatter.date(from: dateKey) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    private static func dateKey(byAddingDays days: Int, to baseKey: String) -> String? {
        guard let base = dateFormatter.date(from: baseKey),
              let result = calendar.date(byAdding: .day, value: days, to: base) else {
            return nil
        }
        return dateFormatter.string(from: result)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
