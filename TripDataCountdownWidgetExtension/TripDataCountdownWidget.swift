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

private struct OperationalStatusView: View {
    let presentationStyle: FlightCountdownStatusPresentationStyle
    let state: FlightOperationalState
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let reportTimeUTC: Date?

    @ViewBuilder
    var body: some View {
        if presentationStyle.usesLiveActivitySystemTimer {
            LiveActivityOperationalStatusView(
                state: state,
                plannedDepartureUTC: plannedDepartureUTC,
                plannedArrivalUTC: plannedArrivalUTC,
                reportTimeUTC: reportTimeUTC
            )
        } else {
            LegacyOperationalStatusView(
                state: state,
                plannedDepartureUTC: plannedDepartureUTC,
                plannedArrivalUTC: plannedArrivalUTC,
                reportTimeUTC: reportTimeUTC
            )
        }
    }
}

private struct LegacyOperationalStatusView: View {
    let state: FlightOperationalState
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let reportTimeUTC: Date?

    var body: some View {
        switch state {
        case .preReport:
            if let reportTimeUTC, reportTimeUTC > Date.now {
                countdownLine(prefix: "Report in", target: reportTimeUTC)
            }
        case .postReportPreDeparture:
            if plannedDepartureUTC > Date.now {
                countdownLine(prefix: "Dep in", target: plannedDepartureUTC)
            }
        case .scheduledDeparturePassed:
            Text("Scheduled Departure Time Passed")
        case .inFlight:
            if plannedArrivalUTC > Date.now {
                countdownLine(prefix: "Arriving in", target: plannedArrivalUTC)
            }
        case .scheduledArrivalPassed:
            let staleBoundary = plannedArrivalUTC.addingTimeInterval(60 * 60)
            if Date.now < staleBoundary {
                HStack(spacing: 4) {
                    Text("Scheduled Arrival Time Passed")
                    Text(timerInterval: plannedArrivalUTC...staleBoundary, countsDown: false)
                }
                .monospacedDigit()
            }
        case .completed, .stale:
            EmptyView()
        }
    }

    private func countdownLine(prefix: String, target: Date) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
            Text(timerInterval: Date.now...target, countsDown: true)
        }
        .monospacedDigit()
    }
}

private struct LiveActivityOperationalStatusView: View {
    let state: FlightOperationalState
    let plannedDepartureUTC: Date
    let plannedArrivalUTC: Date
    let reportTimeUTC: Date?
    var showsPrefix = true

    var body: some View {
        switch state {
        case .preReport:
            if let reportTimeUTC, reportTimeUTC > Date.now {
                countdownLine(prefix: "Report in", target: reportTimeUTC)
            }
        case .postReportPreDeparture:
            if plannedDepartureUTC > Date.now {
                countdownLine(prefix: "Dep in", target: plannedDepartureUTC)
            }
        case .scheduledDeparturePassed:
            Text("Scheduled Departure Time Passed")
        case .inFlight:
            if plannedArrivalUTC > Date.now {
                countdownLine(prefix: "Arriving in", target: plannedArrivalUTC)
            }
        case .scheduledArrivalPassed:
            let staleBoundary = plannedArrivalUTC.addingTimeInterval(60 * 60)
            if Date.now < staleBoundary {
                HStack(spacing: 4) {
                    if showsPrefix {
                        Text("Scheduled Arrival Time Passed")
                    }
                    Text(
                        .currentDate,
                        format: .timer(
                            countingUpIn: FlightCountdownLiveActivityTimerContract.countUpInterval(
                                startingAt: plannedArrivalUTC,
                                staleAt: staleBoundary
                            ),
                            showsHours: true,
                            maxFieldCount: FlightCountdownLiveActivityTimerContract.maxFieldCount,
                            maxPrecision: FlightCountdownLiveActivityTimerContract.maxPrecision
                        )
                    )
                }
                .monospacedDigit()
            }
        case .completed, .stale:
            EmptyView()
        }
    }

    private func countdownLine(prefix: String, target: Date) -> some View {
        HStack(spacing: 4) {
            if showsPrefix {
                Text(prefix)
            }
            Text(
                .currentDate,
                format: .timer(
                    countingDownIn: FlightCountdownLiveActivityTimerContract.countdownInterval(
                        endingAt: target
                    ),
                    showsHours: true,
                    maxFieldCount: FlightCountdownLiveActivityTimerContract.maxFieldCount,
                    maxPrecision: FlightCountdownLiveActivityTimerContract.maxPrecision
                )
            )
        }
        .monospacedDigit()
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
            state: .postReportPreDeparture,
            visibility: .widget,
            legID: "preview",
            flightNumber: "5X750",
            isDeadhead: false,
            departureAirportIATA: "SGN",
            arrivalAirportIATA: "NRT",
            plannedDepartureUTC: departure,
            plannedArrivalUTC: now.addingTimeInterval(9 * 60 * 60 + 41 * 60),
            reportTimeUTC: nil,
            departureTimeZoneID: "Asia/Ho_Chi_Minh",
            arrivalTimeZoneID: "Asia/Tokyo",
            departureDateText: "Mar 13",
            departureTimeText: "07:50",
            arrivalDateText: "Mar 13",
            arrivalTimeText: "15:20",
            referenceText: nil
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
                    OperationalStatusView(
                        presentationStyle: .widget,
                        state: snapshot.state,
                        plannedDepartureUTC: snapshot.plannedDepartureUTC,
                        plannedArrivalUTC: snapshot.plannedArrivalUTC,
                        reportTimeUTC: snapshot.reportTimeUTC
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
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
                OperationalStatusView(
                    presentationStyle: .liveActivity,
                    state: state.state,
                    plannedDepartureUTC: state.plannedDepartureUTC,
                    plannedArrivalUTC: state.plannedArrivalUTC,
                    reportTimeUTC: state.reportTimeUTC
                )
                .foregroundStyle(statusColor)
            }

            if state.state == .scheduledArrivalPassed, let referenceText = state.referenceText {
                Text(referenceText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch state.state {
        case .scheduledDeparturePassed, .scheduledArrivalPassed:
            return .orange
        case .preReport, .postReportPreDeparture, .inFlight:
            return .green
        case .completed, .stale:
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
                    FlightCountdownLiveActivityView(state: context.state)
                }
            } compactLeading: {
                Text("✈ \(formattedFlightNumber(context.state.flightNumber, isDeadhead: context.state.isDeadhead, unknownFallback: "Flight"))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } compactTrailing: {
                LiveActivityOperationalStatusView(
                    state: context.state.state,
                    plannedDepartureUTC: context.state.plannedDepartureUTC,
                    plannedArrivalUTC: context.state.plannedArrivalUTC,
                    reportTimeUTC: context.state.reportTimeUTC,
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
