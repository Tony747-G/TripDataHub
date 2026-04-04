import CoreGraphics
import Foundation

private let calendarEngineUTCCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

private func calendarInTimeZone(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
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
    guard let firstCalendarDay = calendarDays.first else {
        return nil
    }

    let localCalendar = calendarInTimeZone(timeZone)
    let firstLocalComponents = localCalendar.dateComponents([.year, .month, .day], from: firstCalendarDay.dayStartUTC)
    guard let firstLocalMidnight = localCalendar.date(from: firstLocalComponents) else {
        return nil
    }
    return localCalendar.date(byAdding: .day, value: index, to: firstLocalMidnight)
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

func resolveDayIndex(for utcDate: Date, timeZone: TimeZone, calendarDays: [CalendarDay]) -> Int? {
    guard let firstCalendarDay = calendarDays.first else {
        return nil
    }

    let localCalendar = calendarInTimeZone(timeZone)
    let firstLocalDayStart = localCalendar.startOfDay(for: firstCalendarDay.dayStartUTC)
    let targetLocalDayStart = localCalendar.startOfDay(for: utcDate)
    let dayOffset = localCalendar.dateComponents([.day], from: firstLocalDayStart, to: targetLocalDayStart).day

    guard let dayOffset, (0..<calendarDays.count).contains(dayOffset) else {
        return nil
    }
    return dayOffset
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

    for leg in trip.legs {
        guard let departureUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
              let arrivalUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
              let departureTimeZone = resolvedTimeZone(for: leg.depAirport),
              let arrivalTimeZone = resolvedTimeZone(for: leg.arrAirport)
        else {
            continue
        }

        let localDeparture = localDateComponents(for: departureUTC, in: departureTimeZone)
        let localArrival = localDateComponents(for: arrivalUTC, in: arrivalTimeZone)

        guard let localDepartureTuple = localDateTuple(from: localDeparture),
              let localArrivalTuple = localDateTuple(from: localArrival),
              localArrivalTuple < localDepartureTuple,
              let dayIndex = resolveDayIndex(for: arrivalUTC, timeZone: arrivalTimeZone, calendarDays: days)
        else {
            continue
        }

        let arrivalFraction = fraction(from: localArrival)
        let departureFraction = fraction(from: localDeparture)
        guard arrivalFraction < departureFraction else {
            continue
        }

        result[dayIndex] = widestRange(
            existing: result[dayIndex],
            candidate: arrivalFraction...departureFraction
        )
    }

    return result
}

func buildSegments(trip: CalendarTrip, days: [CalendarDay]) -> [CalendarSegment] {
    guard let displayTimeZone = tripDisplayTimeZone(for: trip),
          let finalArrivalTimeZone = tripFinalArrivalTimeZone(for: trip),
          let startDayIndex = resolveDayIndex(for: trip.startUTC, timeZone: displayTimeZone, calendarDays: days),
          let endDayIndex = resolveDayIndex(for: trip.endUTC, timeZone: displayTimeZone, calendarDays: days),
          startDayIndex <= endDayIndex
    else {
        return []
    }

    let regressionByDay = localRegressionMetadata(for: trip, days: days)
    var segments: [CalendarSegment] = []

    for dayIndex in startDayIndex...endDayIndex {
        let isFirstDay = dayIndex == startDayIndex
        let isLastDay = dayIndex == endDayIndex
        let hasRegression = regressionByDay[dayIndex] != nil
        let regressedRange = regressionByDay[dayIndex]

        let start: Double
        if isFirstDay {
            start = startFraction(for: trip.startUTC, timeZone: displayTimeZone)
        } else {
            start = 0
        }

        let end: Double
        if isLastDay {
            end = endFraction(for: trip.endUTC, timeZone: finalArrivalTimeZone)
        } else {
            end = 1
        }

        let segmentStartUTC = isFirstDay
            ? trip.startUTC
            : (localDayStartUTC(at: dayIndex, timeZone: displayTimeZone, calendarDays: days) ?? trip.startUTC)

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

        segments.append(
            CalendarSegment(
                tripID: trip.id,
                weekIndex: day.weekIndex,
                dayIndex: dayIndex,
                segmentStartUTC: segmentStartUTC,
                startFraction: normalizedStart,
                endFraction: normalizedEnd,
                lane: 0,
                hasLocalTimeRegression: hasRegression,
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
