import CoreGraphics
import Foundation

private let calendarEngineUTCCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

// Calendar construction is expensive and this helper runs per day cell / per trip
// segment during calendar layout. Cache one calendar per timezone (small fixed set
// of domicile/airport zones). Lock-protected: layout helpers may run off-main.
private final class CalendarByTimeZoneCache: @unchecked Sendable {
    static let shared = CalendarByTimeZoneCache()
    private let lock = NSLock()
    private var calendars: [String: Calendar] = [:]

    func calendar(for timeZone: TimeZone) -> Calendar {
        lock.lock()
        defer { lock.unlock() }
        if let cached = calendars[timeZone.identifier] { return cached }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendars[timeZone.identifier] = calendar
        return calendar
    }
}

private func calendarInTimeZone(_ timeZone: TimeZone) -> Calendar {
    CalendarByTimeZoneCache.shared.calendar(for: timeZone)
}

private func localDateComponents(
    for utcDate: Date,
    in timeZone: TimeZone
) -> DateComponents {
    calendarInTimeZone(timeZone).dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: utcDate
    )
}

private func localDateTuple(from components: DateComponents) -> (Int, Int, Int, Int, Int, Int)? {
    guard let year = components.year,
          let month = components.month,
          let day = components.day,
          let hour = components.hour,
          let minute = components.minute,
          let second = components.second
    else {
        return nil
    }

    return (year, month, day, hour, minute, second)
}

private func clampFraction(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func fraction(from components: DateComponents) -> Double {
    let hour = Double(components.hour ?? 0)
    let minute = Double(components.minute ?? 0)
    let second = Double(components.second ?? 0)
    return clampFraction((hour + (minute / 60) + (second / 3600)) / 24)
}

private func dateKey(from components: DateComponents) -> String? {
    guard let year = components.year,
          let month = components.month,
          let day = components.day
    else {
        return nil
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}

private func fractionWithinCalendarDay(_ utcDate: Date, day: CalendarDay) -> Double {
    let duration = day.dayEndUTC.timeIntervalSince(day.dayStartUTC)
    guard duration > 0 else { return 0 }
    return clampFraction(utcDate.timeIntervalSince(day.dayStartUTC) / duration)
}

private func tripDisplayTimeZone(for trip: CalendarTrip) -> TimeZone? {
    guard let firstLeg = trip.legs.first else {
        return nil
    }
    return resolvedTimeZone(for: firstLeg.depAirport)
}

private func tripFinalArrivalTimeZone(for trip: CalendarTrip) -> TimeZone? {
    guard let finalLeg = trip.legs.last else {
        return nil
    }
    return resolvedTimeZone(for: finalLeg.arrAirport)
}

private func resolvedTimeZone(for airportCode: String) -> TimeZone? {
    guard let identifier = IATATimeZoneResolver.shared.resolve(airportCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) else {
        return nil
    }
    return TimeZone(identifier: identifier)
}

private func localDayStartUTC(
    at index: Int,
    timeZone: TimeZone,
    calendarDays: [CalendarDay]
) -> Date? {
    _ = timeZone
    return calendarDays.first(where: { $0.index == index })?.dayStartUTC
}

private func widestRange(
    existing: ClosedRange<Double>?,
    candidate: ClosedRange<Double>
) -> ClosedRange<Double> {
    guard let existing else {
        return candidate
    }
    let existingWidth = existing.upperBound - existing.lowerBound
    let candidateWidth = candidate.upperBound - candidate.lowerBound
    return candidateWidth > existingWidth ? candidate : existing
}

func normalizeCalendarTrips(from schedules: [PayPeriodSchedule]) -> [CalendarTrip] {
    let groupedLegs = Dictionary(grouping: schedules.flatMap(\.legs)) { leg in
        "\(leg.payPeriod)|\(leg.pairing)"
    }

    return groupedLegs.compactMap { tripID, grouped in
        guard let firstLeg = grouped.first else {
            return nil
        }

        let sortedLegs = grouped.sorted { lhs, rhs in
            guard let lhsDate = LegConnectionTextBuilder.parseUTC(lhs.depUTC),
                  let rhsDate = LegConnectionTextBuilder.parseUTC(rhs.depUTC)
            else {
                return lhs.leg < rhs.leg
            }
            if lhsDate == rhsDate {
                return lhs.leg < rhs.leg
            }
            return lhsDate < rhsDate
        }

        let departureDates = sortedLegs.compactMap { LegConnectionTextBuilder.parseUTC($0.depUTC) }
        let arrivalDates = sortedLegs.compactMap { LegConnectionTextBuilder.parseUTC($0.arrUTC) }

        guard departureDates.count == sortedLegs.count,
              arrivalDates.count == sortedLegs.count,
              let startUTC = departureDates.min(),
              let endUTC = arrivalDates.max(),
              startUTC <= endUTC,
              !firstLeg.payPeriod.isEmpty,
              !firstLeg.pairing.isEmpty
        else {
            return nil
        }

        return CalendarTrip(
            id: tripID,
            pairing: firstLeg.pairing,
            payPeriod: firstLeg.payPeriod,
            legs: sortedLegs,
            startUTC: startUTC,
            endUTC: endUTC
        )
    }
    .sorted { lhs, rhs in
        if lhs.startUTC == rhs.startUTC {
            return lhs.id < rhs.id
        }
        return lhs.startUTC < rhs.startUTC
    }
}

func visibleTrips(in bidPeriod: CalendarBidPeriod, trips: [CalendarTrip]) -> [CalendarTrip] {
    trips.filter { trip in
        trip.startUTC < bidPeriod.endDateUTC && trip.endUTC > bidPeriod.startDateUTC
    }
}

func visibleManualOperationalEvents(
    in bidPeriod: CalendarBidPeriod,
    events: [ManualOperationalEvent]
) -> [ManualOperationalEvent] {
    events.filter { event in
        event.startUTC < bidPeriod.endDateUTC && event.endUTC > bidPeriod.startDateUTC
    }
}

struct CalendarStackItem: Identifiable, Equatable {
    enum Layer: Equatable {
        case bid
        case personal
    }

    let id: String
    let title: String
    let compactTitle: String
    let layer: Layer
    let manualPersonalEventID: UUID?

    init(
        id: String,
        title: String,
        compactTitle: String,
        layer: Layer,
        manualPersonalEventID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.compactTitle = compactTitle
        self.layer = layer
        self.manualPersonalEventID = manualPersonalEventID
    }
}

struct CalendarStackSummary: Equatable {
    let representative: CalendarStackItem
    let overflowCount: Int
    let items: [CalendarStackItem]
}

func calendarStackItems(
    bidItems: [CalendarStackItem],
    personalItems: [CalendarStackItem]
) -> [CalendarStackItem] {
    bidItems + personalItems
}

func calendarStackSummary(
    bidItems: [CalendarStackItem],
    personalItems: [CalendarStackItem]
) -> CalendarStackSummary? {
    let items = calendarStackItems(bidItems: bidItems, personalItems: personalItems)
    guard let representative = items.first else { return nil }
    return CalendarStackSummary(
        representative: representative,
        overflowCount: max(items.count - 1, 0),
        items: items
    )
}

func manualPersonalStackItems(
    for day: CalendarDay,
    events: [ManualPersonalEvent]
) -> [CalendarStackItem] {
    events
        .filter { $0.endUTC > day.dayStartUTC && $0.startUTC < day.dayEndUTC }
        .sorted { lhs, rhs in
            if lhs.startUTC != rhs.startUTC { return lhs.startUTC < rhs.startUTC }
            return lhs.code.rawValue < rhs.code.rawValue
        }
        .map { event in
            CalendarStackItem(
                id: "manual-personal-\(event.id.uuidString)-\(day.displayDateKey)",
                title: event.code.rawValue,
                compactTitle: event.code.rawValue.uppercased(),
                layer: .personal,
                manualPersonalEventID: event.id
            )
        }
}

func resolveDayIndex(for utcDate: Date, timeZone: TimeZone, calendarDays: [CalendarDay]) -> Int? {
    _ = timeZone
    return calendarDays.first { day in
        day.dayStartUTC <= utcDate && utcDate < day.dayEndUTC
    }?.index
}

func localComponents(for utcDate: Date, timeZone: TimeZone) -> DateComponents {
    localDateComponents(for: utcDate, in: timeZone)
}

func dayKey(from utcDate: Date, timeZone: TimeZone) -> String {
    let components = localDateComponents(for: utcDate, in: timeZone)
    let year = components.year ?? 0
    let month = components.month ?? 0
    let day = components.day ?? 0
    return String(format: "%04d-%02d-%02d", year, month, day)
}

func startFraction(for utcDate: Date, timeZone: TimeZone) -> Double {
    fraction(from: localDateComponents(for: utcDate, in: timeZone))
}

func endFraction(for utcDate: Date, timeZone: TimeZone) -> Double {
    fraction(from: localDateComponents(for: utcDate, in: timeZone))
}

func localRegressionMetadata(for trip: CalendarTrip, days: [CalendarDay]) -> [Int: ClosedRange<Double>] {
    var result: [Int: ClosedRange<Double>] = [:]

    // Only show the local-time "clock moves backward" cue on the trip's final leg.
    // Intermediate timezone regressions add visual noise to the iPad BP calendar,
    // while the operationally meaningful case is usually a westbound return leg
    // back to domicile/base (for example Asia -> ANC).
    guard let leg = trip.legs.last,
          let departureUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
          let arrivalUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
          let departureTimeZone = resolvedTimeZone(for: leg.depAirport),
          let arrivalTimeZone = resolvedTimeZone(for: leg.arrAirport)
    else {
        return result
    }

    // Regressions only occur when the dep and arr are in different timezones.
    // A same-timezone overnight flight naturally crosses local midnight and is not
    // a regression — it would create a false positive if checked by fraction alone.
    guard departureTimeZone.identifier != arrivalTimeZone.identifier else {
        return result
    }

    let departureLocalAtDepartureAirport = localDateComponents(for: departureUTC, in: departureTimeZone)

    // Regression is an iPad calendar cue, not a schedule-timing source of truth:
    // compare the final leg's departure airport wall time against the actual
    // arrival time in the Domicile calendar cell. Example: HKG 19:38 -> ANC
    // 13:07 renders blue through 13:07 and orange from 13:07 to 19:38 on the
    // Domicile day. We intentionally do not convert the HKG wall clock to ANC.
    let departureOffset = departureTimeZone.secondsFromGMT(for: departureUTC)
    let arrivalOffset = arrivalTimeZone.secondsFromGMT(for: arrivalUTC)
    guard departureOffset != arrivalOffset,
          let arrivalDayIndex = resolveDayIndex(for: arrivalUTC, timeZone: arrivalTimeZone, calendarDays: days),
          let arrivalDay = days.first(where: { $0.index == arrivalDayIndex }),
          let departureWallDateKey = dateKey(from: departureLocalAtDepartureAirport),
          let visualEndDay = days.first(where: { $0.displayDateKey == departureWallDateKey })
    else {
        return result
    }

    let arrivalFraction = fractionWithinCalendarDay(arrivalUTC, day: arrivalDay)
    let visualEndFraction = fraction(from: departureLocalAtDepartureAirport)
    let arrivalPosition = Double(arrivalDay.index) + arrivalFraction
    let visualEndPosition = Double(visualEndDay.index) + visualEndFraction

    guard visualEndPosition > arrivalPosition else {
        return result
    }

    for dayIndex in arrivalDay.index...visualEndDay.index {
        let lower: Double = dayIndex == arrivalDay.index ? arrivalFraction : 0
        let upper: Double = dayIndex == visualEndDay.index ? visualEndFraction : 1
        guard upper > lower else { continue }
        result[dayIndex] = widestRange(
            existing: result[dayIndex],
            candidate: lower...upper
        )
    }

    return result
}

func buildSegments(trip: CalendarTrip, days: [CalendarDay]) -> [CalendarSegment] {
    // The trip's start/end UTC may fall before/after the displayed BP's days
    // (carry-in / carry-out). In that case we want to render a partial bar that
    // begins at the BP's left edge or extends to the BP's right edge rather than
    // dropping the trip entirely.
    guard let firstDay = days.first
    else {
        return []
    }
    let regressionByDay = localRegressionMetadata(for: trip, days: days)
    let secondsPerDay: TimeInterval = 86_400
    let rawStart = Int((trip.startUTC.timeIntervalSince(firstDay.dayStartUTC) / secondsPerDay).rounded(.down))
    let rawEnd = Int((trip.endUTC.timeIntervalSince(firstDay.dayStartUTC) / secondsPerDay).rounded(.down))
    let regressionMaxDayIndex = regressionByDay.keys.max()
    // Trip is entirely outside the BP range — nothing to render.
    guard max(rawEnd, regressionMaxDayIndex ?? rawEnd) >= 0, rawStart < days.count else { return [] }
    let startDayIndex = max(0, rawStart)
    let endDayIndex = min(days.count - 1, max(rawEnd, regressionMaxDayIndex ?? rawEnd))
    guard startDayIndex <= endDayIndex else { return [] }
    let isCarryIn = rawStart < 0
    let isCarryOut = rawEnd >= days.count

    var segments: [CalendarSegment] = []

    for dayIndex in startDayIndex...endDayIndex {
        let isFirstDay = dayIndex == startDayIndex
        let isLastDay = dayIndex == endDayIndex
        let start: Double
        if isFirstDay && !isCarryIn {
            if let day = days.first(where: { $0.index == dayIndex }) {
                start = fractionWithinCalendarDay(trip.startUTC, day: day)
            } else {
                start = 0
            }
        } else {
            // Either not the first day of the trip, or the trip carries in from
            // a previous BP — start at the cell's left edge.
            start = 0
        }

        let end: Double
        if isLastDay && !isCarryOut {
            if let day = days.first(where: { $0.index == dayIndex }) {
                let arrivalEnd = dayIndex == rawEnd ? fractionWithinCalendarDay(trip.endUTC, day: day) : 0
                let regressionEnd = regressionByDay[dayIndex]?.upperBound
                end = max(arrivalEnd, regressionEnd ?? arrivalEnd)
            } else {
                end = 1
            }
        } else {
            // Either not the last day, or the trip carries out into a later BP —
            // extend to the cell's right edge.
            end = 1
        }

        let segmentStartUTC: Date
        if isFirstDay && !isCarryIn {
            segmentStartUTC = trip.startUTC
        } else {
            // For carry-in OR for non-first cells, anchor to the cell's start.
            segmentStartUTC = localDayStartUTC(at: dayIndex, timeZone: calendarEngineUTCCalendar.timeZone, calendarDays: days) ?? trip.startUTC
        }

        let normalizedStart: Double
        let normalizedEnd: Double
        if startDayIndex == endDayIndex, start > end {
            normalizedStart = 0
            normalizedEnd = 1
        } else {
            normalizedStart = clampFraction(start)
            normalizedEnd = clampFraction(end)
        }

        guard let day = days.first(where: { $0.index == dayIndex }) else {
            continue
        }

        let regressedRange = regressionByDay[dayIndex]

        segments.append(
            CalendarSegment(
                tripID: trip.id,
                weekIndex: day.weekIndex,
                dayIndex: dayIndex,
                segmentStartUTC: segmentStartUTC,
                startFraction: normalizedStart,
                endFraction: normalizedEnd,
                lane: 0,
                hasLocalTimeRegression: regressedRange != nil,
                regressedRange: regressedRange
            )
        )
    }

    return segments.sorted { lhs, rhs in
        if lhs.segmentStartUTC == rhs.segmentStartUTC {
            return lhs.dayIndex < rhs.dayIndex
        }
        return lhs.segmentStartUTC < rhs.segmentStartUTC
    }
}

func buildSegments(event: ManualOperationalEvent, days: [CalendarDay]) -> [CalendarSegment] {
    buildOperationalSegments(
        id: manualOperationalSegmentID(for: event),
        startUTC: event.startUTC,
        endUTC: event.endUTC,
        days: days
    )
}

func manualOperationalSegmentID(for event: ManualOperationalEvent) -> String {
    "manual-operational-\(event.id.uuidString)"
}

private func buildOperationalSegments(
    id: String,
    startUTC: Date,
    endUTC: Date,
    days: [CalendarDay]
) -> [CalendarSegment] {
    guard let firstDay = days.first, endUTC > startUTC else {
        return []
    }

    let secondsPerDay: TimeInterval = 86_400
    let rawStart = Int((startUTC.timeIntervalSince(firstDay.dayStartUTC) / secondsPerDay).rounded(.down))
    let rawEnd = Int((endUTC.timeIntervalSince(firstDay.dayStartUTC) / secondsPerDay).rounded(.down))

    guard rawEnd >= 0, rawStart < days.count else { return [] }
    let startDayIndex = max(0, rawStart)
    let endDayIndex = min(days.count - 1, rawEnd)
    guard startDayIndex <= endDayIndex else { return [] }
    let isCarryIn = rawStart < 0
    let isCarryOut = rawEnd >= days.count

    var segments: [CalendarSegment] = []

    for dayIndex in startDayIndex...endDayIndex {
        guard let day = days.first(where: { $0.index == dayIndex }) else { continue }
        let isFirstDay = dayIndex == startDayIndex
        let isLastDay = dayIndex == endDayIndex

        let start = isFirstDay && !isCarryIn ? fractionWithinCalendarDay(startUTC, day: day) : 0
        let end = isLastDay && !isCarryOut ? fractionWithinCalendarDay(endUTC, day: day) : 1
        let normalizedStart: Double
        let normalizedEnd: Double
        if startDayIndex == endDayIndex, start > end {
            normalizedStart = 0
            normalizedEnd = 1
        } else {
            normalizedStart = clampFraction(start)
            normalizedEnd = clampFraction(end)
        }

        let segmentStartUTC: Date
        if isFirstDay && !isCarryIn {
            segmentStartUTC = startUTC
        } else {
            segmentStartUTC = localDayStartUTC(
                at: dayIndex,
                timeZone: calendarEngineUTCCalendar.timeZone,
                calendarDays: days
            ) ?? startUTC
        }

        guard normalizedEnd > normalizedStart else { continue }
        segments.append(
            CalendarSegment(
                tripID: id,
                weekIndex: day.weekIndex,
                dayIndex: dayIndex,
                segmentStartUTC: segmentStartUTC,
                startFraction: normalizedStart,
                endFraction: normalizedEnd,
                lane: 0,
                hasLocalTimeRegression: false,
                regressedRange: nil
            )
        )
    }

    return segments.sorted { lhs, rhs in
        if lhs.segmentStartUTC == rhs.segmentStartUTC {
            return lhs.dayIndex < rhs.dayIndex
        }
        return lhs.segmentStartUTC < rhs.segmentStartUTC
    }
}

func assignLanes(to segments: [CalendarSegment]) -> [CalendarSegment] {
    let sortedSegments = segments.sorted { lhs, rhs in
        if lhs.weekIndex != rhs.weekIndex {
            return lhs.weekIndex < rhs.weekIndex
        }
        if lhs.dayIndex != rhs.dayIndex {
            return lhs.dayIndex < rhs.dayIndex
        }
        if lhs.segmentStartUTC != rhs.segmentStartUTC {
            return lhs.segmentStartUTC < rhs.segmentStartUTC
        }
        return lhs.tripID < rhs.tripID
    }

    var assigned: [CalendarSegment] = []
    var tripLaneMap: [String: Int] = [:]

    func collides(_ candidate: CalendarSegment, in lane: Int) -> Bool {
        assigned.contains { existing in
            existing.lane == lane &&
            existing.weekIndex == candidate.weekIndex &&
            existing.dayIndex == candidate.dayIndex &&
            candidate.startFraction < existing.endFraction &&
            candidate.endFraction > existing.startFraction
        }
    }

    for segment in sortedSegments {
        var updated = segment

        if let existingLane = tripLaneMap[segment.tripID], !collides(segment, in: existingLane) {
            updated.lane = existingLane
        } else {
            var candidateLane = 0
            while collides(segment, in: candidateLane) {
                candidateLane += 1
            }
            updated.lane = candidateLane
        }

        tripLaneMap[segment.tripID] = updated.lane
        assigned.append(updated)
    }

    return assigned
}

func frameForSegment(
    _ segment: CalendarSegment,
    dayFrame: CGRect,
    laneHeight: CGFloat,
    laneSpacing: CGFloat
) -> CGRect {
    let xStart = dayFrame.minX + (CGFloat(segment.startFraction) * dayFrame.width)
    let xEnd = dayFrame.minX + (CGFloat(segment.endFraction) * dayFrame.width)
    let y = dayFrame.minY + (CGFloat(segment.lane) * (laneHeight + laneSpacing))

    return CGRect(
        x: xStart,
        y: y,
        width: xEnd - xStart,
        height: laneHeight
    )
}
