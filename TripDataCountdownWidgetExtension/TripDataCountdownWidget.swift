import SwiftUI
import WidgetKit
import ActivityKit

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
        FlightCountdownSnapshot(
            updatedAtUTC: now,
            phase: .widget,
            legID: "preview",
            flightNumber: "5X750",
            isDeadhead: false,
            departureAirportIATA: "SGN",
            arrivalAirportIATA: "NRT",
            scheduledDepartureUTC: now.addingTimeInterval(2 * 60 * 60 + 11 * 60),
            scheduledArrivalUTC: now.addingTimeInterval(9 * 60 * 60 + 41 * 60),
            departureTimeZoneID: "Asia/Ho_Chi_Minh",
            arrivalTimeZoneID: "Asia/Tokyo",
            departureDateText: "Mar 13",
            departureTimeText: "07:50",
            arrivalDateText: "Mar 13",
            arrivalTimeText: "15:20"
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
        let refreshDate: Date
        switch snapshot.phase {
        case .widget:
            refreshDate = snapshot.scheduledDepartureUTC.addingTimeInterval(-(6 * 60 * 60) + 1)
        case .liveCountdown, .liveDelayed, .finished, .none:
            refreshDate = now.addingTimeInterval(30 * 60)
        }

        completion(Timeline(entries: [current], policy: .after(refreshDate)))
    }
}

private struct FlightCountdownWidgetEntryView: View {
    let entry: FlightCountdownEntry

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.phase == .widget {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.departureDateText.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(routeText(snapshot))
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    statusLine(snapshot)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func statusLine(_ snapshot: FlightCountdownSnapshot) -> some View {
        HStack(spacing: 4) {
            Text("Departure in")
            Text(timerInterval: entry.date...snapshot.scheduledDepartureUTC, countsDown: true)
        }
        .monospacedDigit()
    }
}

private struct FlightCountdownLiveActivityView: View {
    let state: FlightCountdownAttributes.ContentState

    private static let localDateWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d (EEE)"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let displayMode = mode(at: timeline.date)
            VStack(alignment: .leading, spacing: 8) {
                Text("Flight: \(displayFlightNumber)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(state.departureAirportIATA) \(state.departureTimeText)")
                    Spacer(minLength: 0)
                    Text("・・・✈・・・")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(state.arrivalAirportIATA) \(state.arrivalTimeText)")
                }
                .font(.title3.weight(.semibold))
                .monospacedDigit()

                HStack(spacing: 8) {
                    Text(localDateText(date: state.scheduledDepartureUTC, timeZoneID: state.departureTimeZoneID))
                    Spacer(minLength: 12)
                    Text(localDateText(date: state.scheduledArrivalUTC, timeZoneID: state.arrivalTimeZoneID))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(activityStatusText(mode: displayMode, now: timeline.date))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(displayMode == .delayed ? .red : .green)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
        }
    }

    private func mode(at date: Date) -> CountdownMode {
        if date >= state.scheduledDepartureUTC.addingTimeInterval(6 * 60 * 60) {
            return .finished
        }
        if date >= state.scheduledDepartureUTC {
            return .delayed
        }
        return .countdown
    }

    private enum CountdownMode {
        case countdown
        case delayed
        case finished
    }

    private var displayFlightNumber: String {
        let trimmed = state.flightNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return state.isDeadhead ? "DH" : "UNKNOWN"
        }
        let normalized: String
        if let first = trimmed.unicodeScalars.first, CharacterSet.letters.contains(first) {
            normalized = trimmed.uppercased()
        } else {
            normalized = "5X\(trimmed)"
        }
        return state.isDeadhead ? "DH \(normalized)" : normalized
    }

    private func localDateText(date: Date, timeZoneID: String) -> String {
        Self.localDateWeekdayFormatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
        return Self.localDateWeekdayFormatter.string(from: date)
    }

    private func activityStatusText(mode: CountdownMode, now: Date) -> String {
        switch mode {
        case .countdown:
            return "Departure in \(durationText(from: now, to: state.scheduledDepartureUTC))"
        case .delayed:
            return "+\(durationText(from: state.scheduledDepartureUTC, to: now)) past STD"
        case .finished:
            return "Completed"
        }
    }

    private func durationText(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start)) / 60)
        return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
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
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    FlightCountdownLiveActivityView(state: context.state)
                }
            } compactLeading: {
                Text("✈ \(compactFlightNumber(for: context.state))")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } compactTrailing: {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    if timeline.date >= context.state.scheduledDepartureUTC {
                        Text("+\(shortDurationText(from: context.state.scheduledDepartureUTC, to: timeline.date)) STD")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text("Dep in \(shortDurationText(from: timeline.date, to: context.state.scheduledDepartureUTC))")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            } minimal: {
                Text("✈ \(compactFlightNumber(for: context.state))")
                    .font(.caption2.weight(.bold))
            }
        }
    }

    private func shortDurationText(from start: Date, to end: Date) -> String {
        let totalMinutes = max(0, Int(end.timeIntervalSince(start)) / 60)
        return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
    }

    private func compactFlightNumber(for state: FlightCountdownAttributes.ContentState) -> String {
        let trimmed = state.flightNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return state.isDeadhead ? "DH" : "Flight"
        }
        if let first = trimmed.unicodeScalars.first, CharacterSet.letters.contains(first) {
            return trimmed.uppercased()
        }
        let normalized = "5X\(trimmed)"
        return state.isDeadhead ? "DH \(normalized)" : normalized
    }
}

@main
struct TripDataCountdownWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripDataCountdownWidget()
        FlightCountdownLiveActivityWidget()
    }
}
