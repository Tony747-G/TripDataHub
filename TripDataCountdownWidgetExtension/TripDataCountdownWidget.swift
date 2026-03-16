import SwiftUI
import WidgetKit
import ActivityKit

// MARK: - Shared helpers (file-private)

/// Single flight number formatter used by both the live activity view and compact Dynamic Island.
/// Falls back to "DH" for deadhead legs with no number, or `unknownFallback` for non-deadhead.
/// Handles three cases:
///   - Already prefixed (e.g. "5X76")  → kept as-is ("5X76")
///   - Other airline prefix (e.g. "UA123") → uppercased ("UA123")
///   - Numeric only (e.g. "76") → UPS prefix prepended ("5X76")
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

/// Compact "H:MM" format for narrow Dynamic Island slots where "Xh Xm" doesn't fit.
private func compactDurationText(from start: Date, to end: Date) -> String {
    let mins = max(0, Int(end.timeIntervalSince(start)) / 60)
    return "\(mins / 60):\(String(format: "%02d", mins % 60))"
}

/// Lock covers both dictionary access and the formatting call so no formatter
/// is ever used outside the lock — avoiding the DateFormatter thread-safety ambiguity.
private let liveActivityFormatterLock = NSLock()
private var liveActivityDateFormatterCache: [String: DateFormatter] = [:]

private func liveActivityLocalDateText(_ date: Date, tzID: String) -> String {
    liveActivityFormatterLock.lock(); defer { liveActivityFormatterLock.unlock() }
    let f: DateFormatter
    if let existing = liveActivityDateFormatterCache[tzID] {
        f = existing
    } else {
        let newF = DateFormatter()
        newF.calendar = Calendar(identifier: .gregorian)
        newF.locale = Locale(identifier: "en_US_POSIX")
        newF.dateFormat = "MMM d (EEE)"
        newF.timeZone = TimeZone(identifier: tzID) ?? TimeZone(secondsFromGMT: 0)
        liveActivityDateFormatterCache[tzID] = newF
        f = newF
    }
    return f.string(from: date)
}

// MARK: - Snapshot store

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

// MARK: - Timeline provider

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
        let effectivePhase = FlightCountdownSharedStore.phase(
            scheduledDepartureUTC: snapshot.scheduledDepartureUTC,
            now: now
        )
        let refreshDate: Date
        switch effectivePhase {
        case .widget:
            // Refresh just after the widget-to-live-activity transition boundary
            refreshDate = snapshot.scheduledDepartureUTC.addingTimeInterval(-FlightCountdownSharedStore.liveLeadTime + 1)
        case .liveCountdown, .liveDelayed, .finished, .none:
            refreshDate = now.addingTimeInterval(30 * 60)
        }

        completion(Timeline(entries: [current], policy: .after(refreshDate)))
    }
}

// MARK: - Widget view

private struct FlightCountdownWidgetEntryView: View {
    let entry: FlightCountdownEntry

    var body: some View {
        if let snapshot = entry.snapshot,
           FlightCountdownSharedStore.phase(
               scheduledDepartureUTC: snapshot.scheduledDepartureUTC,
               now: entry.date
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

// MARK: - Live activity view

private struct FlightCountdownLiveActivityView: View {
    let state: FlightCountdownAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let displayMode = mode(at: timeline.date)
            VStack(alignment: .leading, spacing: 8) {
                Text("Flight: \(formattedFlightNumber(state.flightNumber, isDeadhead: state.isDeadhead, unknownFallback: "UNKNOWN"))")
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
        if date >= state.scheduledDepartureUTC.addingTimeInterval(FlightCountdownSharedStore.delayedTailTime) {
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

    private func localDateText(date: Date, timeZoneID: String) -> String {
        liveActivityLocalDateText(date, tzID: timeZoneID)
    }

    private func activityStatusText(mode: CountdownMode, now: Date) -> String {
        switch mode {
        case .countdown:
            return "Departure in \(FlightCountdownSharedStore.durationText(from: now, to: state.scheduledDepartureUTC))"
        case .delayed:
            return "Delayed \(FlightCountdownSharedStore.durationText(from: state.scheduledDepartureUTC, to: now))"
        case .finished:
            return "Completed"
        }
    }
}

// MARK: - Widget declarations

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
                Text("✈ \(formattedFlightNumber(context.state.flightNumber, isDeadhead: context.state.isDeadhead, unknownFallback: "Flight"))")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } compactTrailing: {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    if timeline.date >= context.state.scheduledDepartureUTC {
                        Text("+\(compactDurationText(from: context.state.scheduledDepartureUTC, to: timeline.date)) STD")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text("Dep in \(compactDurationText(from: timeline.date, to: context.state.scheduledDepartureUTC))")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            } minimal: {
                Text("✈ \(formattedFlightNumber(context.state.flightNumber, isDeadhead: context.state.isDeadhead, unknownFallback: "Flight"))")
                    .font(.caption2.weight(.bold))
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
