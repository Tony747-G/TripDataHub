import Foundation
import SwiftUI

enum FlightPresentationVisibility: String, Codable, Hashable {
    case hidden
    case widget
}

struct OperationalCountdownPresentation: Codable, Equatable, Hashable {
    let state: FlightOperationalState
    let prefix: String
    let anchorUTC: Date

    static func make(
        state: FlightOperationalState,
        plannedDepartureUTC: Date,
        reportTimeUTC: Date?
    ) -> OperationalCountdownPresentation? {
        switch state {
        case .preReport:
            guard let reportTimeUTC else { return nil }
            return OperationalCountdownPresentation(
                state: state,
                prefix: "Report in",
                anchorUTC: reportTimeUTC
            )
        case .preDeparture:
            return OperationalCountdownPresentation(
                state: state,
                prefix: "Dep in",
                anchorUTC: plannedDepartureUTC
            )
        case .departureTimePassed, .expired:
            return nil
        }
    }
}

struct FlightCountdownSnapshot: Codable, Equatable, Hashable {
    let updatedAtUTC: Date
    let state: FlightOperationalState
    let visibility: FlightPresentationVisibility
    let legID: String
    let flightNumber: String?
    let isDeadhead: Bool
    let departureAirportIATA: String
    let arrivalAirportIATA: String
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let reportTimeUTC: Date?
    let presentation: OperationalCountdownPresentation?
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
    let departureDateText: String
    let departureTimeText: String
    let arrivalDateText: String
    let arrivalTimeText: String
}

enum FlightPresentationPolicy {
    /// T-12h: Home Screen Widget presentation begins.
    static let widgetLeadTime: TimeInterval = 12 * 60 * 60
    /// T-6h: Home Screen Widget presentation ends.
    static let widgetEndLeadTime: TimeInterval = 6 * 60 * 60

    /// Presentation windows decide only surface visibility; they never decide operational state.
    static func visibility(
        for state: FlightOperationalState,
        plannedDepartureUTC: Date,
        nowUTC: Date
    ) -> FlightPresentationVisibility {
        guard state != .expired else {
            return .hidden
        }
        if nowUTC < plannedDepartureUTC.addingTimeInterval(-widgetLeadTime) {
            return .hidden
        }
        guard nowUTC < plannedDepartureUTC.addingTimeInterval(-widgetEndLeadTime) else {
            return .hidden
        }
        return .widget
    }

    static func nextVisibilityBoundary(
        plannedDepartureUTC: Date,
        nowUTC: Date
    ) -> Date? {
        let widgetStart = plannedDepartureUTC.addingTimeInterval(-widgetLeadTime)
        if nowUTC < widgetStart {
            return widgetStart
        }
        let widgetEnd = plannedDepartureUTC.addingTimeInterval(-widgetEndLeadTime)
        if nowUTC < widgetEnd {
            return widgetEnd
        }
        return nil
    }
}

enum FlightCountdownTimerContract {
    static let maxFieldCount = 2
    static let maxPrecision = Duration.seconds(60)

    static func countdownInterval(endingAt targetUTC: Date) -> Range<Date> {
        Date.distantPast..<targetUTC
    }
}

struct OperationalCountdownStatusView: View {
    let presentation: OperationalCountdownPresentation
    var showsPrefix = true
    var prioritizesPrefix = false

    var body: some View {
        HStack(spacing: prioritizesPrefix ? 2 : 4) {
            if showsPrefix {
                Text(presentation.prefix)
                    .layoutPriority(prioritizesPrefix ? 1 : 0)
            }
            Text(
                .currentDate,
                format: .timer(
                    countingDownIn: FlightCountdownTimerContract.countdownInterval(
                        endingAt: presentation.anchorUTC
                    ),
                    showsHours: true,
                    maxFieldCount: FlightCountdownTimerContract.maxFieldCount,
                    maxPrecision: FlightCountdownTimerContract.maxPrecision
                )
            )
        }
        .monospacedDigit()
    }
}

enum FlightCountdownSharedStore {
    static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    static let widgetSnapshotFileName = "flight_countdown_snapshot.json"
}

#if DEBUG
enum HomeWidgetDebugClockStore {
    private struct Payload: Codable {
        let effectiveNowUTC: Date
    }

    private static let fileName = "home_widget_debug_clock.json"

    static func load() -> Date? {
        guard let fileURL = fileURL(),
              let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data).effectiveNowUTC
    }

    static func save(_ effectiveNowUTC: Date?) {
        guard let fileURL = fileURL() else { return }
        guard let effectiveNowUTC else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(effectiveNowUTC: effectiveNowUTC)) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FlightCountdownSharedStore.appGroupIdentifier
        )?.appendingPathComponent(fileName)
    }
}
#endif

// MARK: - Always-operational Home Screen Widget

enum HomeWidgetOperationalState: String, Codable, Equatable, Hashable {
    case nextTripReport
    case activeTripNextFlight
    case activeTripFinalLeg
}

struct HomeWidgetAirportCoordinate: Codable, Equatable, Hashable {
    let latitude: Double
    let longitude: Double
}

struct HomeWidgetLeg: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let flightNumber: String
    let departureAirportIATA: String
    let arrivalAirportIATA: String
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let departureTimeZoneID: String
    let arrivalTimeZoneID: String
    let arrivalCoordinate: HomeWidgetAirportCoordinate?
    let layoverAfterMinutes: Int?
}

struct HomeWidgetTrip: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let tripID: String
    let reportTimeUTC: Date
    let reportTimeZoneID: String
    let releaseBoundaryUTC: Date?
    let legs: [HomeWidgetLeg]
}

struct HomeWidgetScheduleSnapshot: Codable, Equatable, Hashable {
    let updatedAtUTC: Date
    let trips: [HomeWidgetTrip]
}

struct HomeWidgetSelection: Codable, Equatable, Hashable {
    let state: HomeWidgetOperationalState
    let trip: HomeWidgetTrip
    let displayedLeg: HomeWidgetLeg?
}

struct HomeWidgetTimeText: Codable, Equatable, Hashable {
    let local: String
    let utc: String
}

struct HomeWidgetPresentation: Codable, Equatable, Hashable {
    let state: HomeWidgetOperationalState
    let tripID: String
    let flightNumber: String?
    let departureAirportIATA: String?
    let arrivalAirportIATA: String?
    let reportTime: HomeWidgetTimeText?
    let departureTime: HomeWidgetTimeText?
    let arrivalTime: HomeWidgetTimeText?
    let arrivalUTC: Date?
    let arrivalCoordinate: HomeWidgetAirportCoordinate?
    let layoverAfterMinutes: Int?
}

struct HomeWidgetWeatherHour: Equatable, Hashable {
    let date: Date
    let temperatureCelsius: Double
    let symbolName: String
}

struct HomeWidgetWeatherSnapshot: Codable, Equatable, Hashable {
    let destinationAirportIATA: String
    let forecastDateUTC: Date
    let symbolName: String
    let temperatureCelsius: Double
    let temperatureText: String
}

struct HomeWidgetWeatherAttribution: Equatable, Hashable {
    let combinedMarkDarkData: Data
    let combinedMarkLightData: Data
    let legalPageURL: URL
}

/// The Home Screen Widget ships Small and Medium only. Large was withdrawn as a product
/// decision, so there is no third presentation to keep in sync.
enum HomeWidgetFamily: Equatable, Hashable {
    case small
    case medium

    var showsArrivalTime: Bool { self == .medium }
    /// Small carries the report-location / departure Local time only; the UTC line costs a row
    /// that the enlarged Local time uses better at that size.
    var showsUTCTime: Bool { self == .medium }
    var showsDestinationWeather: Bool { self == .medium }
    var showsLayover: Bool { self == .medium }
}

struct HomeWidgetTimelinePoint: Equatable, Hashable {
    let date: Date
    let presentation: HomeWidgetPresentation?
}

struct HomeWidgetEnrichedTimelinePoint<Enrichment> {
    let point: HomeWidgetTimelinePoint
    let enrichment: Enrichment?
}

enum HomeWidgetTimelineEnrichmentPolicy {
    static let maximumWeatherEnrichmentCount = 1

    static func enrich<Enrichment>(
        points: [HomeWidgetTimelinePoint],
        allowsWeather: Bool,
        enrichment: (HomeWidgetPresentation?) async -> Enrichment?
    ) async -> [HomeWidgetEnrichedTimelinePoint<Enrichment>] {
        var enriched: [HomeWidgetEnrichedTimelinePoint<Enrichment>] = []
        enriched.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            let value = allowsWeather && index < maximumWeatherEnrichmentCount
                ? await enrichment(point.presentation)
                : nil
            enriched.append(.init(point: point, enrichment: value))
        }
        return enriched
    }
}

enum HomeWidgetDomain {
    static let postFinalArrivalInterval: TimeInterval = 30 * 60
    static let hourlyForecastHorizon: TimeInterval = 10 * 24 * 60 * 60
    static let timelineHorizon: TimeInterval = 48 * 60 * 60
    static let maximumTimelineEntryCount = 12

    static func selection(
        from snapshot: HomeWidgetScheduleSnapshot,
        nowUTC: Date
    ) -> HomeWidgetSelection? {
        let orderedTrips = snapshot.trips
            .filter { $0.releaseBoundaryUTC != nil && !$0.legs.isEmpty }
            .sorted(by: tripOrder)
        let activeTrips = orderedTrips.filter { trip in
            guard trip.reportTimeUTC <= nowUTC else { return false }
            guard let releaseBoundaryUTC = trip.releaseBoundaryUTC else { return false }
            return nowUTC < releaseBoundaryUTC
        }

        if let activeTrip = activeTrips.max(by: tripOrder) {
            let orderedLegs = activeTrip.legs.sorted(by: legOrder)
            if let nextLeg = orderedLegs.first(where: { $0.plannedDepartureUTC > nowUTC }) {
                return HomeWidgetSelection(
                    state: .activeTripNextFlight,
                    trip: activeTrip,
                    displayedLeg: nextLeg
                )
            }
            return HomeWidgetSelection(
                state: .activeTripFinalLeg,
                trip: activeTrip,
                displayedLeg: orderedLegs.last
            )
        }

        guard let nextTrip = orderedTrips.first(where: { $0.reportTimeUTC > nowUTC }) else {
            return nil
        }
        return HomeWidgetSelection(
            state: .nextTripReport,
            trip: nextTrip,
            displayedLeg: nil
        )
    }

    static func nextBoundary(
        from snapshot: HomeWidgetScheduleSnapshot,
        after nowUTC: Date
    ) -> Date? {
        guard let selection = selection(from: snapshot, nowUTC: nowUTC) else { return nil }
        switch selection.state {
        case .nextTripReport:
            return selection.trip.reportTimeUTC > nowUTC ? selection.trip.reportTimeUTC : nil
        case .activeTripNextFlight:
            guard let departure = selection.displayedLeg?.plannedDepartureUTC,
                  departure > nowUTC else { return nil }
            return departure
        case .activeTripFinalLeg:
            guard let release = selection.trip.releaseBoundaryUTC,
                  release > nowUTC else { return nil }
            return release
        }
    }

    static func presentation(
        from snapshot: HomeWidgetScheduleSnapshot,
        nowUTC: Date
    ) -> HomeWidgetPresentation? {
        guard let selection = selection(from: snapshot, nowUTC: nowUTC) else { return nil }
        switch selection.state {
        case .nextTripReport:
            return HomeWidgetPresentation(
                state: selection.state,
                tripID: selection.trip.tripID,
                flightNumber: nil,
                departureAirportIATA: nil,
                arrivalAirportIATA: nil,
                reportTime: timeText(
                    selection.trip.reportTimeUTC,
                    localTimeZoneID: selection.trip.reportTimeZoneID
                ),
                departureTime: nil,
                arrivalTime: nil,
                arrivalUTC: nil,
                arrivalCoordinate: nil,
                layoverAfterMinutes: nil
            )
        case .activeTripNextFlight, .activeTripFinalLeg:
            guard let leg = selection.displayedLeg else { return nil }
            return HomeWidgetPresentation(
                state: selection.state,
                tripID: selection.trip.tripID,
                flightNumber: leg.flightNumber,
                departureAirportIATA: leg.departureAirportIATA,
                arrivalAirportIATA: leg.arrivalAirportIATA,
                reportTime: nil,
                departureTime: timeText(
                    leg.plannedDepartureUTC,
                    localTimeZoneID: leg.departureTimeZoneID
                ),
                arrivalTime: timeText(
                    leg.plannedArrivalUTC,
                    localTimeZoneID: leg.arrivalTimeZoneID
                ),
                arrivalUTC: leg.plannedArrivalUTC,
                arrivalCoordinate: leg.arrivalCoordinate,
                layoverAfterMinutes: leg.layoverAfterMinutes
            )
        }
    }

    static func timeline(
        from snapshot: HomeWidgetScheduleSnapshot,
        nowUTC: Date
    ) -> [HomeWidgetTimelinePoint] {
        var points = [
            HomeWidgetTimelinePoint(
                date: nowUTC,
                presentation: presentation(from: snapshot, nowUTC: nowUTC)
            )
        ]
        var cursor = nowUTC
        var visitedBoundaries: Set<Date> = []
        let horizonEnd = nowUTC.addingTimeInterval(timelineHorizon)

        while let boundary = nextBoundary(from: snapshot, after: cursor),
              boundary > cursor,
              boundary <= horizonEnd,
              points.count < maximumTimelineEntryCount,
              visitedBoundaries.insert(boundary).inserted {
            points.append(
                HomeWidgetTimelinePoint(
                    date: boundary,
                    presentation: presentation(from: snapshot, nowUTC: boundary)
                )
            )
            cursor = boundary
        }
        return points
    }

    static func nearestWeather(
        to arrivalUTC: Date,
        destinationAirportIATA: String,
        hours: [HomeWidgetWeatherHour]
    ) -> HomeWidgetWeatherSnapshot? {
        guard let nearest = hours.min(by: {
            abs($0.date.timeIntervalSince(arrivalUTC))
                < abs($1.date.timeIntervalSince(arrivalUTC))
        }) else {
            return nil
        }
        let temperature = nearest.temperatureCelsius
        return HomeWidgetWeatherSnapshot(
            destinationAirportIATA: destinationAirportIATA,
            forecastDateUTC: nearest.date,
            symbolName: nearest.symbolName,
            temperatureCelsius: temperature,
            temperatureText: "\(Int(temperature.rounded()))°C"
        )
    }

    static func canRequestArrivalForecast(arrivalUTC: Date, nowUTC: Date) -> Bool {
        arrivalUTC >= nowUTC.addingTimeInterval(-60 * 60)
            && arrivalUTC <= nowUTC.addingTimeInterval(hourlyForecastHorizon)
    }

    static func layoverDurationText(minutes: Int) -> String {
        let safeMinutes = max(0, minutes)
        return "\(safeMinutes / 60)h \(safeMinutes % 60)m"
    }

    private static func timeText(_ date: Date, localTimeZoneID: String) -> HomeWidgetTimeText {
        HomeWidgetTimeText(
            local: formatted(date, timeZoneID: localTimeZoneID),
            utc: formatted(date, timeZoneID: "UTC")
        )
    }

    private static func formatted(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM dd HH:mm"
        return formatter.string(from: date).uppercased()
    }

    private static func tripOrder(_ lhs: HomeWidgetTrip, _ rhs: HomeWidgetTrip) -> Bool {
        if lhs.reportTimeUTC != rhs.reportTimeUTC {
            return lhs.reportTimeUTC < rhs.reportTimeUTC
        }
        return lhs.id < rhs.id
    }

    private static func legOrder(_ lhs: HomeWidgetLeg, _ rhs: HomeWidgetLeg) -> Bool {
        if lhs.plannedDepartureUTC != rhs.plannedDepartureUTC {
            return lhs.plannedDepartureUTC < rhs.plannedDepartureUTC
        }
        return lhs.id < rhs.id
    }
}
