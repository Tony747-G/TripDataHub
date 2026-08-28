import Foundation
import SwiftUI
import WidgetKit

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
                        HomeWidgetOperationalStatusView(presentation: presentation)
                            .foregroundStyle(.green)
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

private struct HomeWidgetOperationalStatusView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    let presentation: OperationalCountdownPresentation

    @ViewBuilder
    var body: some View {
        if widgetFamily == .systemSmall {
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.prefix)
                    .lineLimit(1)
                OperationalCountdownStatusView(
                    presentation: presentation,
                    showsPrefix: false
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .font(.caption.weight(.semibold))
        } else {
            OperationalCountdownStatusView(presentation: presentation)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
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

@main
struct TripDataCountdownWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripDataCountdownWidget()
    }
}
