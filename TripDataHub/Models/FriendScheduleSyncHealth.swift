import Foundation

/// How healthy a single friend's shared schedule is, as shown by the dot next to their name.
///
/// Deliberately not stored on `FriendConnection`: it is derived per refresh, and adding a property
/// to that Codable type would change the persisted cache shape. `AppViewModel` keeps the per-friend
/// fetch outcome and this enum is computed from it, so 1.2.4 caches decode unchanged.
enum FriendScheduleSyncHealth: Equatable {
    /// Latest sync succeeded and the friend has published at least one trip operating tomorrow or later.
    case synchronizedWithUpcomingSchedule
    /// Latest sync succeeded but nothing is published for tomorrow onwards. An empty schedule that
    /// was fetched cleanly belongs here, not in `failed`.
    case synchronizedWithoutUpcomingSchedule
    /// The latest refresh of this friend could not produce trustworthy data.
    case failed
}

/// Why a friend's schedule could not be synchronized.
///
/// Only `fetchError` exists because it is the only cause this app can establish with certainty.
/// In particular **an account deletion is not detectable and is not claimed here**: the account
/// delete path clears the friend-link approval bits, which is exactly what an unfriend from the
/// other side does, so the two are indistinguishable from the viewer's side with the current
/// schema. Both simply drop the friend out of `acceptedFriendConnections`. Distinguishing them
/// would need a durable deletion marker on the profile or link record — a schema change that is
/// deliberately out of scope.
enum FriendScheduleSyncFailure: String, Equatable {
    case fetchError
}

/// The outcome of the most recent attempt to refresh one friend.
enum FriendScheduleSyncOutcome: Equatable {
    case succeeded
    case failed(FriendScheduleSyncFailure)
}

enum FriendScheduleHealthEvaluator {

    /// Start of tomorrow in the viewer's current calendar.
    ///
    /// `autoupdatingCurrent` so a timezone change mid-trip is reflected without relaunching.
    static func startOfTomorrow(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
    }

    /// True when any leg of any schedule is still operating at, or starts after, the start of
    /// tomorrow. A trip that departs today and lands tomorrow counts — the comparison is against
    /// each leg's real UTC operating window, not a calendar-day bucket.
    static func hasUpcomingSchedule(
        _ schedules: [PayPeriodSchedule],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let threshold = startOfTomorrow(now: now, calendar: calendar)
        for schedule in schedules {
            for leg in schedule.legs {
                let departure = LegConnectionTextBuilder.parseUTC(leg.depUTC)
                let arrival = LegConnectionTextBuilder.parseUTC(leg.arrUTC)
                // Starts tomorrow or later.
                if let departure, departure >= threshold { return true }
                // Or is still in the air when tomorrow begins.
                if let departure, let arrival, departure < threshold, arrival >= threshold { return true }
                // Arrival-only data is enough to know it reaches tomorrow.
                if departure == nil, let arrival, arrival >= threshold { return true }
            }
        }
        return false
    }

    /// The single decision function used by both the iPhone and iPad friend lists.
    static func health(
        outcome: FriendScheduleSyncOutcome,
        schedules: [PayPeriodSchedule],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> FriendScheduleSyncHealth {
        switch outcome {
        case .failed:
            return .failed
        case .succeeded:
            // An empty but cleanly fetched schedule is amber, never red.
            return hasUpcomingSchedule(schedules, now: now, calendar: calendar)
                ? .synchronizedWithUpcomingSchedule
                : .synchronizedWithoutUpcomingSchedule
        }
    }
}

extension FriendScheduleSyncHealth {
    /// VoiceOver value. The dot alone conveys nothing to a screen reader.
    var accessibilityValue: String {
        switch self {
        case .synchronizedWithUpcomingSchedule:
            return "Schedule synchronized"
        case .synchronizedWithoutUpcomingSchedule:
            return "Synchronized, no upcoming schedule"
        case .failed:
            return "Schedule sync failed"
        }
    }
}
