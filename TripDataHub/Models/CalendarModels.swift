import Foundation

struct CalendarBidPeriod: Equatable {
    let id: String
    let startDateUTC: Date
    let endDateUTC: Date
    let days: [CalendarDay]
}

struct CalendarDay: Equatable {
    let index: Int
    let weekIndex: Int
    let weekdayIndex: Int
    let payPeriodIndex: Int
    let dayStartUTC: Date
    let dayEndUTC: Date
    let displayDateKey: String
}

struct CalendarTrip: Equatable {
    let id: String
    let pairing: String
    let payPeriod: String
    let legs: [TripLeg]
    let startUTC: Date
    let endUTC: Date
}

struct CalendarSegment: Equatable {
    let tripID: String
    let weekIndex: Int
    let dayIndex: Int
    let segmentStartUTC: Date
    let startFraction: Double
    let endFraction: Double
    var lane: Int
    let hasLocalTimeRegression: Bool
    let regressedRange: ClosedRange<Double>?
}
