import Foundation

struct FriendTimelineDaySection: Identifiable {
    let id: String
    let label: String
    let legs: [TripLeg]
}

struct FriendTimelineCardDaySection: Identifiable {
    let id: String
    let label: String
    let cards: [WebTimelineCard]
}

enum FriendTimelineSectionBuilder {
    static func build(from sharedSchedules: [PayPeriodSchedule]) -> [FriendTimelineDaySection] {
        let allLegs = sharedSchedules
            .flatMap(\.legs)
            .sorted { lhs, rhs in
                if lhs.depLocal == rhs.depLocal {
                    return lhs.flight < rhs.flight
                }
                return lhs.depLocal < rhs.depLocal
            }

        var order: [String] = []
        var grouped: [String: [TripLeg]] = [:]
        for leg in allLegs {
            let key = ScheduleDateText.datePart(from: leg.depLocal)
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(leg)
        }

        return order.map { key in
            FriendTimelineDaySection(
                id: key,
                label: ScheduleDateText.dayHeaderLabel(from: key),
                legs: grouped[key] ?? []
            )
        }
    }

    static func build(from timelineCards: [WebTimelineCard]) -> [FriendTimelineCardDaySection] {
        let sortedCards = timelineCards.sorted { lhs, rhs in
            if lhs.startUTC == rhs.startUTC {
                return lhs.id < rhs.id
            }
            return lhs.startUTC < rhs.startUTC
        }

        var order: [String] = []
        var grouped: [String: [WebTimelineCard]] = [:]
        for card in sortedCards {
            let key = card.dayKey
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(card)
        }

        return order.map { key in
            FriendTimelineCardDaySection(
                id: key,
                label: grouped[key]?.first?.dayLabel ?? key,
                cards: grouped[key] ?? []
            )
        }
    }
}
