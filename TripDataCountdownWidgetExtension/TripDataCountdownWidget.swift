import ActivityKit
import SwiftUI
import WidgetKit

private func formattedFlightNumber(
    _ number: String?,
    isDeadhead: Bool,
    unknownFallback: String
) -> String {
    let trimmed = number?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
        return isDeadhead ? "DH" : unknownFallback
    }
    let upper = trimmed.uppercased()
    let normalized: String
    if upper.hasPrefix("5X") {
        normalized = upper
    } else if let firstScalar = trimmed.unicodeScalars.first, CharacterSet.letters.contains(firstScalar) {
        normalized = upper
    } else {
        normalized = "5X\(upper)"
    }
    return isDeadhead ? "DH \(normalized)" : normalized
}

private let liveActivityFormatterLock = NSLock()
private var liveActivityDateFormatterCache: [String: DateFormatter] = [:]

private func liveActivityLocalDateText(_ date: Date, tzID: String) -> String {
    liveActivityFormatterLock.lock(); defer { liveActivityFormatterLock.unlock() }
    let formatter: DateFormatter
    if let existing = liveActivityDateFormatterCache[tzID] {
        formatter = existing
    } else {
        let newFormatter = DateFormatter()
        newFormatter.calendar = Calendar(identifier: .gregorian)
        newFormatter.locale = Locale(identifier: "en_US_POSIX")
        newFormatter.dateFormat = "MMM d (EEE)"
        newFormatter.timeZone = TimeZone(identifier: tzID) ?? TimeZone(secondsFromGMT: 0)
        liveActivityDateFormatterCache[tzID] = newFormatter
        formatter = newFormatter
    }
    return formatter.string(from: date)
}

private struct LiveActivityOperationalStatusView: View {
    let presentation: OperationalCountdownPresentation?
    var showsPrefix = true
    var prioritizesPrefix = false

    @ViewBuilder
    var body: some View {
        if let presentation {
            OperationalCountdownStatusView(
                presentation: presentation,
                showsPrefix: showsPrefix,
                prioritizesPrefix: prioritizesPrefix
            )
        }
    }
}

private struct FlightCountdownEntry: TimelineEntry {
    let date: Date
    let snapshot: FlightCountdownSnapshot?
}

private enum FlightCountdownSnapshotStore {
    static func load() -> FlightCountdownSnapshot? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FlightCountdownSharedStore.appGroupIdentifier
        ) else {
            return nil
        }
        let fileURL = containerURL.appendingPathComponent(FlightCountdownSharedStore.widgetSnapshotFileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FlightCountdownSnapshot.self, from: data)
    }

    static func placeholderSnapshot(now: Date = Date()) -> FlightCountdownSnapshot {
        let departure = now.addingTimeInterval(2 * 60 * 60 + 11 * 60)
        return FlightCountdownSnapshot(
            updatedAtUTC: now,
            state: .preDeparture,
            visibility: .widget,
            legID: "preview",
            flightNumber: "5X750",
            isDeadhead: false,
            departureAirportIATA: "SGN",
            arrivalAirportIATA: "NRT",
            plannedDepartureUTC: departure,
            plannedArrivalUTC: now.addingTimeInterval(9 * 60 * 60 + 41 * 60),
            reportTimeUTC: nil,
            presentation: OperationalCountdownPresentation.make(
                state: .preDeparture,
                plannedDepartureUTC: departure,
                reportTimeUTC: nil
            ),
            departureTimeZoneID: "Asia/Ho_Chi_Minh",
            arrivalTimeZoneID: "Asia/Tokyo",
            departureDateText: "Mar 13",
            departureTimeText: "07:50",
            arrivalDateText: "Mar 13",
            arrivalTimeText: "15:20",
        )
    }
}

private struct FlightCountdownProvider: TimelineProvider {
    func placeholder(in context: Context) -> FlightCountdownEntry {
        FlightCountdownEntry(date: Date(), snapshot: FlightCountdownSnapshotStore.placeholderSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (FlightCountdownEntry) -> Void) {
        let snapshot = FlightCountdownSnapshotStore.load() ?? FlightCountdownSnapshotStore.placeholderSnapshot()
        completion(FlightCountdownEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlightCountdownEntry>) -> Void) {
        let now = Date()
        guard let snapshot = FlightCountdownSnapshotStore.load() else {
            completion(Timeline(entries: [FlightCountdownEntry(date: now, snapshot: nil)], policy: .after(now.addingTimeInterval(30 * 60))))
            return
        }

        let current = FlightCountdownEntry(date: now, snapshot: snapshot)
        let refreshDate = FlightPresentationPolicy.nextVisibilityBoundary(
            plannedDepartureUTC: snapshot.plannedDepartureUTC,
            nowUTC: now
        )?.addingTimeInterval(1) ?? now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: [current], policy: .after(refreshDate)))
    }
}

private struct FlightCountdownWidgetEntryView: View {
    let entry: FlightCountdownEntry

    var body: some View {
        if let snapshot = entry.snapshot,
           FlightPresentationPolicy.visibility(
               for: snapshot.state,
               plannedDepartureUTC: snapshot.plannedDepartureUTC,
               nowUTC: entry.date
           ) == .widget {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.departureDateText.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(routeText(snapshot))
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if let presentation = snapshot.presentation {
                        OperationalCountdownStatusView(presentation: presentation)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // This surface owns its background, therefore it must own its foreground.
            // Semantic colors resolve against the system appearance, not this tint;
            // changing either declaration requires reviewing the other.
            .environment(\.colorScheme, .dark)
            .containerBackground(for: .widget) {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.12, blue: 0.18),
                        Color(red: 0.04, green: 0.05, blue: 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No active countdown")
                    .font(.headline)
                Text("The next scheduled leg will appear from T-12h to T-6h.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                Color(.systemBackground)
            }
        }
    }

    private func routeText(_ snapshot: FlightCountdownSnapshot) -> String {
        "\(snapshot.departureAirportIATA) \(snapshot.departureTimeText) -> \(snapshot.arrivalDateText) \(snapshot.arrivalTimeText) \(snapshot.arrivalAirportIATA)"
    }
}

private struct FlightCountdownLiveActivityView: View {
    let state: FlightCountdownAttributes.ContentState
    var verticalPadding: CGFloat = 6
    var prioritizesStatusPrefix = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlightCountdownExpandedLayoutView(
                flightText: "Flight: \(formattedFlightNumber(state.flightNumber, isDeadhead: state.isDeadhead, unknownFallback: "UNKNOWN"))",
                departureDateText: liveActivityLocalDateText(
                    state.plannedDepartureUTC,
                    tzID: state.departureTimeZoneID
                ),
                departureAirportTimeText: "\(state.departureAirportIATA) \(state.departureTimeText)",
                arrivalDateText: liveActivityLocalDateText(
                    state.plannedArrivalUTC,
                    tzID: state.arrivalTimeZoneID
                ),
                arrivalAirportTimeText: "\(state.arrivalAirportIATA) \(state.arrivalTimeText)"
            ) {
                LiveActivityOperationalStatusView(
                    presentation: state.presentation,
                    prioritizesPrefix: prioritizesStatusPrefix
                )
                    .foregroundStyle(statusColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, verticalPadding)
    }

    private var statusColor: Color {
        switch state.state {
        case .departureTimePassed:
            return .orange
        case .preReport, .preDeparture:
            return .green
        case .expired:
            return .secondary
        }
    }
}

struct TripDataCountdownWidget: Widget {
    let kind = "TripDataCountdownWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FlightCountdownProvider()) { entry in
            FlightCountdownWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next Flight Countdown")
        .description("Shows the next scheduled leg during the widget countdown window.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FlightCountdownLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightCountdownAttributes.self) { context in
            FlightCountdownLiveActivityView(state: context.state)
                // This surface owns its background, therefore it must own its foreground.
                // Semantic colors resolve against the system appearance, not this tint;
                // changing either declaration requires reviewing the other.
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    FlightCountdownLiveActivityView(
                        state: context.state,
                        verticalPadding: 0,
                        prioritizesStatusPrefix: true
                    )
                }
                .contentMargins(.top, 0)
            } compactLeading: {
                Text("✈ \(formattedFlightNumber(context.state.flightNumber, isDeadhead: context.state.isDeadhead, unknownFallback: "Flight"))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } compactTrailing: {
                LiveActivityOperationalStatusView(
                    presentation: context.state.presentation,
                    showsPrefix: false
                )
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
            } minimal: {
                Text("✈ \(formattedFlightNumber(context.state.flightNumber, isDeadhead: context.state.isDeadhead, unknownFallback: "Flight"))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

@main
struct TripDataCountdownWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripDataCountdownWidget()
        FlightCountdownLiveActivityWidget()
    }
}
