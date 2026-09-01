import CoreLocation
import Foundation
import SwiftUI
import UIKit
import WeatherKit
import WidgetKit

private struct HomeWidgetEntry: TimelineEntry {
    let date: Date
    let presentation: HomeWidgetPresentation?
    let weather: HomeWidgetWeatherSnapshot?
    let weatherAttribution: HomeWidgetWeatherAttribution?
}

private enum HomeWidgetSnapshotStore {
    static func load() -> HomeWidgetScheduleSnapshot? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FlightCountdownSharedStore.appGroupIdentifier
        ) else {
            return nil
        }
        let fileURL = containerURL.appendingPathComponent(
            FlightCountdownSharedStore.widgetSnapshotFileName
        )
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HomeWidgetScheduleSnapshot.self, from: data)
    }

    static func placeholder(nowUTC: Date = Date()) -> HomeWidgetPresentation {
        HomeWidgetPresentation(
            state: .activeTripNextFlight,
            tripID: "A70639",
            flightNumber: "5X456",
            departureAirportIATA: "SDF",
            arrivalAirportIATA: "NRT",
            reportTime: nil,
            departureTime: .init(local: "AUG 31 18:10", utc: "AUG 31 22:10"),
            arrivalTime: .init(local: "SEP 01 21:15", utc: "SEP 01 12:15"),
            arrivalUTC: nowUTC.addingTimeInterval(12 * 60 * 60),
            arrivalCoordinate: .init(latitude: 35.76858, longitude: 140.388714),
            layoverAfterMinutes: 18 * 60 + 25
        )
    }
}

private actor HomeWidgetWeatherEnricher {
    static let shared = HomeWidgetWeatherEnricher()

    struct Enrichment {
        let weather: HomeWidgetWeatherSnapshot?
        let attribution: HomeWidgetWeatherAttribution?
    }

    private struct CacheKey: Hashable {
        let airport: String
        let arrivalUTC: Date
    }

    private struct CacheValue {
        let enrichment: Enrichment
        let expiresAtUTC: Date
    }

    private let weatherService = WeatherService.shared
    private var cache: [CacheKey: CacheValue] = [:]
    private var attributionCache: HomeWidgetWeatherAttribution?

    func enrichment(
        for presentation: HomeWidgetPresentation?,
        nowUTC: Date
    ) async -> Enrichment {
        guard let presentation,
              presentation.state != .nextTripReport,
              let destination = presentation.arrivalAirportIATA,
              let arrivalUTC = presentation.arrivalUTC,
              let coordinate = presentation.arrivalCoordinate,
              HomeWidgetDomain.canRequestArrivalForecast(
                arrivalUTC: arrivalUTC,
                nowUTC: nowUTC
              )
        else {
            return Enrichment(weather: nil, attribution: nil)
        }

        let key = CacheKey(airport: destination, arrivalUTC: arrivalUTC)
        if let cached = cache[key], cached.expiresAtUTC > nowUTC {
            return cached.enrichment
        }

        do {
            let location = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            let forecast: Forecast<HourWeather> = try await weatherService.weather(
                for: location,
                including: .hourly(
                    startDate: arrivalUTC.addingTimeInterval(-60 * 60),
                    endDate: arrivalUTC.addingTimeInterval(2 * 60 * 60)
                )
            )
            let hours = forecast.map {
                HomeWidgetWeatherHour(
                    date: $0.date,
                    temperatureCelsius: $0.temperature.converted(to: .celsius).value,
                    symbolName: $0.symbolName
                )
            }
            guard let weather = HomeWidgetDomain.nearestWeather(
                to: arrivalUTC,
                destinationAirportIATA: destination,
                hours: hours
            ),
            let attribution = try await attribution()
            else {
                let unavailable = Enrichment(weather: nil, attribution: nil)
                cache[key] = CacheValue(
                    enrichment: unavailable,
                    expiresAtUTC: nowUTC.addingTimeInterval(15 * 60)
                )
                return unavailable
            }

            let enrichment = Enrichment(weather: weather, attribution: attribution)
            cache[key] = CacheValue(
                enrichment: enrichment,
                expiresAtUTC: nowUTC.addingTimeInterval(30 * 60)
            )
            return enrichment
        } catch {
            let unavailable = Enrichment(weather: nil, attribution: nil)
            cache[key] = CacheValue(
                enrichment: unavailable,
                expiresAtUTC: nowUTC.addingTimeInterval(15 * 60)
            )
            return unavailable
        }
    }

    private func attribution() async throws -> HomeWidgetWeatherAttribution? {
        if let attributionCache { return attributionCache }
        let attribution = try await weatherService.attribution
        async let darkMarkResponse = URLSession.shared.data(
            from: attribution.combinedMarkDarkURL
        )
        async let lightMarkResponse = URLSession.shared.data(
            from: attribution.combinedMarkLightURL
        )
        let ((darkMarkData, darkResponse), (lightMarkData, lightResponse)) = try await (
            darkMarkResponse,
            lightMarkResponse
        )
        guard !darkMarkData.isEmpty,
              !lightMarkData.isEmpty,
              (darkResponse as? HTTPURLResponse)?.statusCode == 200,
              (lightResponse as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }
        let value = HomeWidgetWeatherAttribution(
            combinedMarkDarkData: darkMarkData,
            combinedMarkLightData: lightMarkData,
            legalPageURL: attribution.legalPageURL
        )
        attributionCache = value
        return value
    }
}

private struct HomeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeWidgetEntry {
        HomeWidgetEntry(
            date: Date(),
            presentation: HomeWidgetSnapshotStore.placeholder(),
            weather: nil,
            weatherAttribution: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeWidgetEntry) -> Void) {
        let wallNow = Date()
        let now = effectiveNowUTC(wallNowUTC: wallNow)
        let presentation = HomeWidgetSnapshotStore.load().flatMap {
            HomeWidgetDomain.presentation(from: $0, nowUTC: now)
        } ?? HomeWidgetSnapshotStore.placeholder(nowUTC: now)
        completion(
            HomeWidgetEntry(
                date: wallNow,
                presentation: presentation,
                weather: nil,
                weatherAttribution: nil
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeWidgetEntry>) -> Void) {
        let wallNow = Date()
        let now = effectiveNowUTC(wallNowUTC: wallNow)
        guard let snapshot = HomeWidgetSnapshotStore.load() else {
            completion(
                Timeline(
                    entries: [
                        HomeWidgetEntry(
                            date: wallNow,
                            presentation: nil,
                            weather: nil,
                            weatherAttribution: nil
                        )
                    ],
                    policy: .after(wallNow.addingTimeInterval(30 * 60))
                )
            )
            return
        }

        let points: [HomeWidgetTimelinePoint]
        if usesDebugClock {
            points = [
                HomeWidgetTimelinePoint(
                    date: wallNow,
                    presentation: HomeWidgetDomain.presentation(from: snapshot, nowUTC: now)
                )
            ]
        } else {
            points = HomeWidgetDomain.timeline(from: snapshot, nowUTC: now)
        }
        Task {
            let enrichedPoints: [HomeWidgetEnrichedTimelinePoint<HomeWidgetWeatherEnricher.Enrichment>] =
                await HomeWidgetTimelineEnrichmentPolicy.enrich(
                    points: points,
                    allowsWeather: context.family == .systemMedium
                ) { presentation in
                    await HomeWidgetWeatherEnricher.shared.enrichment(
                        for: presentation,
                        nowUTC: now
                    )
                }
            let entries = enrichedPoints.map { item in
                HomeWidgetEntry(
                    date: item.point.date,
                    presentation: item.point.presentation,
                    weather: item.enrichment?.weather,
                    weatherAttribution: item.enrichment?.attribution
                )
            }
            // Weather is decoration and never sets the reload cadence; entry dates already carry
            // every operational boundary, so both families keep the pre-existing hourly reload.
            let refreshDate = wallNow.addingTimeInterval(60 * 60)
            completion(Timeline(entries: entries, policy: .after(refreshDate)))
        }
    }

    private var usesDebugClock: Bool {
#if DEBUG
        HomeWidgetDebugClockStore.load() != nil
#else
        false
#endif
    }

    private func effectiveNowUTC(wallNowUTC: Date) -> Date {
#if DEBUG
        HomeWidgetDebugClockStore.load() ?? wallNowUTC
#else
        wallNowUTC
#endif
    }
}

/// TripDataHub's warm-brown identity, expressed as widget roles rather than literal colors at
/// each call site.
///
/// The three anchor values are the app's canonical browns from `ScheduleColors` in
/// `TripDataHub/Views/ViewShared.swift`, which already colors the in-app Timeline date headers:
/// `dateDark` (0.78/0.62/0.45) is the dark-theme accent, `timelineDateLight` (0.38/0.22/0.12) the
/// light-theme accent, and `openTimeDateLight` (0.24/0.10/0.06) the light-theme primary. They are
/// restated here rather than imported because `ViewShared.swift` belongs to the app target only;
/// the widget extension compiles just the shared operational model. If these ever need to move,
/// the shared model file is the place — not a new app-wide design system.
///
/// Every remaining role is derived in the same hue family so the widget reads as two or three text
/// levels plus one restrained accent, never a different color per line.
private struct HomeWidgetPalette {
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let subduedAccent: Color
    let surfaceTint: Color
    let separator: Color
    let backgroundTop: Color
    let backgroundBottom: Color

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            // Warm off-white on espresso, with the canonical sand accent carrying flight number
            // and airport codes.
            primaryText = Color(red: 0.96, green: 0.94, blue: 0.90)
            secondaryText = Color(red: 0.72, green: 0.66, blue: 0.59)
            accent = Color(red: 0.78, green: 0.62, blue: 0.45)
            subduedAccent = Color(red: 0.66, green: 0.55, blue: 0.43)
            surfaceTint = Color(red: 0.45, green: 0.32, blue: 0.20).opacity(0.10)
            separator = Color(red: 0.55, green: 0.44, blue: 0.33).opacity(0.24)
            backgroundTop = Color(red: 0.11, green: 0.090, blue: 0.075)
            backgroundBottom = Color(red: 0.055, green: 0.043, blue: 0.035)
        case .light:
            // Espresso on warm off-white. Deliberately not an inversion of the dark ramp: the
            // accent darkens to chestnut so it still reads as emphasis against a pale ground.
            primaryText = Color(red: 0.24, green: 0.10, blue: 0.06)
            secondaryText = Color(red: 0.45, green: 0.36, blue: 0.30)
            accent = Color(red: 0.38, green: 0.22, blue: 0.12)
            subduedAccent = Color(red: 0.52, green: 0.38, blue: 0.26)
            surfaceTint = Color(red: 0.55, green: 0.40, blue: 0.26).opacity(0.07)
            separator = Color(red: 0.45, green: 0.33, blue: 0.22).opacity(0.20)
            backgroundTop = Color(red: 0.99, green: 0.975, blue: 0.955)
            backgroundBottom = Color(red: 0.95, green: 0.925, blue: 0.89)
        @unknown default:
            primaryText = Color(red: 0.24, green: 0.10, blue: 0.06)
            secondaryText = Color(red: 0.45, green: 0.36, blue: 0.30)
            accent = Color(red: 0.38, green: 0.22, blue: 0.12)
            subduedAccent = Color(red: 0.52, green: 0.38, blue: 0.26)
            surfaceTint = Color(red: 0.55, green: 0.40, blue: 0.26).opacity(0.07)
            separator = Color(red: 0.45, green: 0.33, blue: 0.22).opacity(0.20)
            backgroundTop = Color(red: 0.99, green: 0.975, blue: 0.955)
            backgroundBottom = Color(red: 0.95, green: 0.925, blue: 0.89)
        }
    }
}

private struct HomeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.colorScheme) private var colorScheme

    let entry: HomeWidgetEntry

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            if let presentation = entry.presentation {
                switch widgetFamily {
                case .systemSmall:
                    HomeWidgetSmallView(presentation: presentation)
                case .systemMedium:
                    HomeWidgetMediumView(
                        presentation: presentation,
                        weather: entry.weather,
                        attribution: entry.weatherAttribution
                    )
                default:
                    HomeWidgetMediumView(
                        presentation: presentation,
                        weather: entry.weather,
                        attribution: entry.weatherAttribution
                    )
                }
            } else {
                HomeWidgetEmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(8)
        .foregroundStyle(palette.primaryText)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [palette.accent.opacity(0.75), palette.accent.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .accessibilityHidden(true)
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct HomeWidgetSmallView: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HomeWidgetPresentation

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch presentation.state {
            case .nextTripReport:
                HomeWidgetSmallReportView(presentation: presentation)
            case .activeTripNextFlight, .activeTripFinalLeg:
                Text(presentation.flightNumber ?? "FLIGHT")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(palette.surfaceTint, in: Capsule())
                HomeWidgetRouteTimeGrid(presentation: presentation)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                if presentation.state == .activeTripFinalLeg {
                    Text("TRIP IN PROGRESS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HomeWidgetSmallReportView: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HomeWidgetPresentation

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.tripID)
                .font(.headline.weight(.bold))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("REPORT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.secondaryText)
            // Small carries the report-location Local time only. The UTC row costs a line that
            // the enlarged Local time uses better at this size; Medium still shows both.
            if let reportTime = presentation.reportTime {
                HomeWidgetSmallProminentTime(value: reportTime.local)
                    .padding(.top, 1)
            }
        }
    }
}

private struct HomeWidgetMediumView: View {
    let presentation: HomeWidgetPresentation
    let weather: HomeWidgetWeatherSnapshot?
    let attribution: HomeWidgetWeatherAttribution?

    var body: some View {
        switch presentation.state {
        case .nextTripReport:
            HomeWidgetReportView(presentation: presentation, spacious: true)
        case .activeTripNextFlight, .activeTripFinalLeg:
            HomeWidgetFlightBody(
                presentation: presentation,
                weather: weather,
                attribution: attribution
            )
        }
    }
}

/// The Medium active presentation: flight number, the DEP/airplane/ARR route-time grid, and an
/// optional supplemental layover/weather line.
private struct HomeWidgetFlightBody: View {
    let presentation: HomeWidgetPresentation
    let weather: HomeWidgetWeatherSnapshot?
    let attribution: HomeWidgetWeatherAttribution?

    /// The supplemental row is decoration. It is only worth a line when it says something the
    /// route-time grid does not already show.
    private var hasSupplementalRow: Bool {
        presentation.layoverAfterMinutes != nil || weather != nil
    }

    var body: some View {
        stack(includesSupplementalRow: hasSupplementalRow)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stack(includesSupplementalRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeWidgetFlightHeader(presentation: presentation)
            HomeWidgetRouteTimeGrid(presentation: presentation)
            if includesSupplementalRow {
                HomeWidgetDestinationLine(
                    presentation: presentation,
                    weather: weather,
                    attribution: attribution
                )
                .dynamicTypeSize(...DynamicTypeSize.large)
            }
        }
    }
}

private struct HomeWidgetReportView: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HomeWidgetPresentation
    let spacious: Bool

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            reportContent(
                spacing: spacious ? 12 : 5,
                labelFont: .caption,
                tripFont: .title2,
                compactsTripID: false
            )
            .fixedSize(horizontal: false, vertical: true)

            reportContent(
                spacing: 4,
                labelFont: .caption2,
                tripFont: .title3,
                compactsTripID: true
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reportContent(
        spacing: CGFloat,
        labelFont: Font,
        tripFont: Font,
        compactsTripID: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text("TRIP ID")
                .font(labelFont.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
            Text(presentation.tripID)
                .font(tripFont.weight(.bold))
                .foregroundStyle(palette.accent)
                .lineLimit(compactsTripID ? 1 : nil)
                .minimumScaleFactor(compactsTripID ? 0.75 : 1)
            Text("REPORT TIME")
                .font(labelFont.weight(.bold))
                .foregroundStyle(palette.secondaryText)
            if let reportTime = presentation.reportTime {
                HomeWidgetStampedTime(
                    value: reportTime.local,
                    marker: "L",
                    font: .subheadline.monospacedDigit().weight(.semibold)
                )
                HomeWidgetStampedTime(
                    value: reportTime.utc,
                    marker: "Z",
                    font: .subheadline.monospacedDigit().weight(.semibold)
                )
            }
        }
    }
}

private struct HomeWidgetFlightHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HomeWidgetPresentation

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.flightNumber ?? "FLIGHT")
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(palette.surfaceTint, in: Capsule())
            Spacer(minLength: 8)
            // "NEXT FLIGHT" restated what the widget always shows. Only the final-leg state
            // carries information the route and times do not already give.
            if presentation.state == .activeTripFinalLeg {
                Text("TRIP IN PROGRESS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One datetime plus its zone marker, e.g. `SEP 01 05:05(L)`. The marker replaces the previous
/// `LCL` / `UTC` label column, which cost a full column of width on every row.
private struct HomeWidgetStampedTime: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String
    let marker: String
    let font: Font

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        Text("\(value)(\(marker))")
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsTightening(true)
            .foregroundStyle(marker == "Z" ? palette.secondaryText : palette.primaryText)
    }
}

/// Medium is departure on the left, arrival right-aligned on the right, three rows deep:
///
///     SDF          airplane          NRT
///     SEP 01 05:05(L)   SEP 02 07:30(L)
///     SEP 01 09:05(Z)   SEP 01 22:30(Z)
///
/// Small keeps the same route row but carries only the Local departure beneath it:
///
///     SDF          airplane          NRT
///     SEP 01
///     05:05(L)
///
/// The airplane is an overlay rather than a third HStack item so the two airport codes stay
/// pinned to the edges and the symbol stays centred regardless of glyph widths.
private struct HomeWidgetRouteTimeGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var widgetFamily

    let presentation: HomeWidgetPresentation

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    private var codeFont: Font {
        Font.title3.weight(.bold)
    }

    private var timeFont: Font {
        Font.caption.monospacedDigit().weight(.semibold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(presentation.departureAirportIATA ?? "---")
                    .font(codeFont)
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text(presentation.arrivalAirportIATA ?? "---")
                    .font(codeFont)
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .overlay(alignment: .center) {
                Image(systemName: "airplane")
                    .font(Font.caption)
                    .foregroundStyle(palette.subduedAccent)
                    .accessibilityHidden(true)
            }

            if widgetFamily == .systemSmall {
                // Small drops the UTC row and both arrival times. At this size the Local
                // departure is the one value worth reading at a glance, so it takes the
                // vertical space those rows used to cost. The arrival airport code stays in
                // the route row above.
                if let departureLocal = presentation.departureTime?.local {
                    HomeWidgetSmallProminentTime(value: departureLocal)
                        .padding(.top, 1)
                }
            } else {
                timeRow(
                    departure: presentation.departureTime?.local,
                    arrival: presentation.arrivalTime?.local,
                    marker: "L"
                )
                timeRow(
                    departure: presentation.departureTime?.utc,
                    arrival: presentation.arrivalTime?.utc,
                    marker: "Z"
                )
            }
        }
        .background(palette.surfaceTint, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func timeRow(departure: String?, arrival: String?, marker: String) -> some View {
        HStack(spacing: 4) {
            if let departure {
                HomeWidgetStampedTime(value: departure, marker: marker, font: timeFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let arrival {
                HomeWidgetStampedTime(value: arrival, marker: marker, font: timeFont)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// The Small widget's single operational value — the Local departure while a Trip is active, the
/// Local report time before it — split across two lines so the time can be set large without
/// truncating. Splitting the already-formatted display string keeps this purely presentational:
/// no Date is re-derived and no timezone decision is made here.
private struct HomeWidgetSmallProminentTime: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    private var components: (date: String, time: String) {
        guard let separator = value.lastIndex(of: " ") else {
            return ("", value)
        }
        return (
            String(value[..<separator]),
            String(value[value.index(after: separator)...])
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !components.date.isEmpty {
                Text(components.date)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(components.time)
                    .font(.title.monospacedDigit().weight(.bold))
                    .foregroundStyle(palette.primaryText)
                Text("(L)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .allowsTightening(true)
    }
}

private struct HomeWidgetDestinationLine: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: HomeWidgetPresentation
    let weather: HomeWidgetWeatherSnapshot?
    let attribution: HomeWidgetWeatherAttribution?

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let layoverMinutes = presentation.layoverAfterMinutes {
                Text(
                    "LAYOVER @\(presentation.arrivalAirportIATA ?? "") "
                        + HomeWidgetDomain.layoverDurationText(minutes: layoverMinutes)
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.subduedAccent)
            } else {
                Text(presentation.arrivalAirportIATA ?? "DESTINATION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.subduedAccent)
            }

            if let weather {
                Image(systemName: weather.symbolName)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text(weather.temperatureText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(palette.primaryText)
            }

            Spacer(minLength: 4)

            if weather != nil,
               let attribution,
               let mark = UIImage(
                    data: colorScheme == .dark
                        ? attribution.combinedMarkDarkData
                        : attribution.combinedMarkLightData
               ) {
                Link(destination: attribution.legalPageURL) {
                    Image(uiImage: mark)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 74, maxHeight: 18)
                }
                .accessibilityLabel("Apple Weather attribution")
                .accessibilityHint("Opens weather data-source legal information")
            }
        }
        .padding(.top, 3)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.separator)
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .contain)
    }
}

private struct HomeWidgetEmptyView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HomeWidgetPalette {
        HomeWidgetPalette(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No upcoming trip")
                .font(.headline)
            Text("Trip and next-flight details will appear after schedule import.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TripDataCountdownWidget: Widget {
    let kind = "TripDataCountdownWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeWidgetProvider()) { entry in
            HomeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Trip Operations")
        .description("Shows the next Trip report or the next scheduled flight.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TripDataCountdownWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripDataCountdownWidget()
    }
}
