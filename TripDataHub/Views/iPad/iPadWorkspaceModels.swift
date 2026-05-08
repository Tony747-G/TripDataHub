import Foundation

// MARK: - Calendar Grid Day

/// CalendarDay + overflow flag for BP26-07 (4-week BP) extended display.
/// Overflow days come from the next BP and are rendered dimmed.
struct IPadCalendarGridDay {
    let calendarDay: CalendarDay
    let isOverflow: Bool
}

// MARK: - Trip merge

/// Merges crewAccess (PDF import) and a supplemental schedule list (typically
/// `AppViewModel.schedules`, which is itself a CloudKit/BidPro merged set).
/// For the same pairing+payPeriod key, the source with the newer `updatedAt` wins.
///
/// Naming note: `supplemental` is intentionally not "cloudKit" — `viewModel.schedules` is
/// not CloudKit-only, it is the existing app's primary merged schedule. In practice crewAccess
/// tends to win because fresh PDF imports carry a recent timestamp, but supplemental data
/// is retained when its `updatedAt` is demonstrably newer.
func mergedCalendarTrips(
    crewAccess: [PayPeriodSchedule],
    supplemental: [PayPeriodSchedule]
) -> [CalendarTrip] {
    let crewAccessTrips = normalizeCalendarTrips(from: crewAccess)
    let supplementalTrips = normalizeCalendarTrips(from: supplemental)
    let crewAccessIDs = Set(crewAccessTrips.map(\.id))

    // Determine effective updatedAt per trip ID from each source
    let crewAccessUpdatedAt = updatedAtByTripID(schedules: crewAccess)
    let supplementalUpdatedAt = updatedAtByTripID(schedules: supplemental)

    // Keep supplemental trips only when they have no crewAccess counterpart,
    // or when supplemental data is demonstrably newer.
    let retainedSupplemental = supplementalTrips.filter { trip in
        guard crewAccessIDs.contains(trip.id) else { return true }
        let crewDate = crewAccessUpdatedAt[trip.id] ?? .distantPast
        let suppDate = supplementalUpdatedAt[trip.id] ?? .distantPast
        return suppDate > crewDate
    }

    // Remove crewAccess trips that were beaten by supplemental above
    let supplementalWinnerIDs = Set(retainedSupplemental.map(\.id))
    let retainedCrewAccess = crewAccessTrips.filter { !supplementalWinnerIDs.contains($0.id) }

    return retainedCrewAccess + retainedSupplemental
}

private func updatedAtByTripID(schedules: [PayPeriodSchedule]) -> [String: Date] {
    var result: [String: Date] = [:]
    for schedule in schedules {
        let legGroups = Dictionary(grouping: schedule.legs) { "\($0.payPeriod)|\($0.pairing)" }
        for tripID in legGroups.keys {
            let existing = result[tripID] ?? .distantPast
            if schedule.updatedAt > existing {
                result[tripID] = schedule.updatedAt
            }
        }
    }
    return result
}

// MARK: - 8-Week Grid Builder

/// Builds a 56-cell grid for any bid period.
/// For normal BPs (8 weeks): all 56 days are active.
/// For BP26-07 (4 weeks): rows 0-3 are active, rows 4-7 are overflow from the next BP.
///
/// IMPORTANT (Phase 1 limitation): Overflow rows reuse `CalendarDay.index` values from the
/// next bid period, which restart at 0. The current `IPadBidPeriodCalendarView` keys
/// `segmentsByDayIndex` on `CalendarDay.index`, so trip segments belonging to the next BP
/// (overflow region) would collide with active-day indices 0-27 of the *current* BP.
/// Phase 1 mitigates this by rendering overflow cells as date-only (no trip bars overlaid),
/// and `currentBidPeriod` only ever requests trips for the active BP's range. If a future
/// phase needs to draw trip bars on overflow rows, introduce a grid-local index (e.g.
/// `gridPosition: 0..<56`) on `IPadCalendarGridDay` and key segment lookup on that instead.
func iPadCalendarGrid(
    for bidPeriod: CalendarBidPeriod,
    domicile: String = DomicileSupport.defaultDomicile
) -> [IPadCalendarGridDay] {
    let activeDays = bidPeriod.days
    let targetCount = 56

    if activeDays.count >= targetCount {
        return activeDays.prefix(targetCount).map { IPadCalendarGridDay(calendarDay: $0, isOverflow: false) }
    }

    // Short BP: fill remaining cells from the next bid period's days
    var grid = activeDays.map { IPadCalendarGridDay(calendarDay: $0, isOverflow: false) }
    let needed = targetCount - activeDays.count

    if let nextBP = nextBidPeriod(after: bidPeriod, domicile: domicile) {
        let overflowDays = nextBP.days.prefix(needed)
        grid += overflowDays.map { IPadCalendarGridDay(calendarDay: $0, isOverflow: true) }
    } else {
        // Fallback: generate synthetic days continuing from last active day
        let lastDay = activeDays.last
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        for i in 0..<needed {
            guard let base = lastDay,
                  let startUTC = utcCalendar.date(byAdding: .day, value: i + 1, to: base.dayStartUTC),
                  let endUTC = utcCalendar.date(byAdding: .day, value: 1, to: startUTC) else { continue }
            let syntheticIndex = base.index + i + 1
            let synthetic = CalendarDay(
                index: syntheticIndex,
                weekIndex: syntheticIndex / 7,
                weekdayIndex: syntheticIndex % 7,
                payPeriodIndex: syntheticIndex / 28,
                dayStartUTC: startUTC,
                dayEndUTC: endUTC,
                displayDateKey: ""
            )
            grid.append(IPadCalendarGridDay(calendarDay: synthetic, isOverflow: true))
        }
    }

    return grid
}

// MARK: - Next Bid Period

private func nextBidPeriod(after current: CalendarBidPeriod, domicile: String) -> CalendarBidPeriod? {
    bidPeriod(for: current.endDateUTC, domicile: domicile)
}

// MARK: - Trip Bar Label

/// Returns "DEP → ARR" using first departure and last arrival airports.
func tripBarLabel(for trip: CalendarTrip) -> String {
    guard let dep = trip.legs.first?.depAirport,
          let arr = trip.legs.last?.arrAirport else {
        return trip.pairing
    }
    return "\(dep) → \(arr)"
}
