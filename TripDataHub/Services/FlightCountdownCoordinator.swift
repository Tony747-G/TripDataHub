import Foundation

enum FlightCountdownRefreshMode: Sendable {
    case reconcile
    case destructiveRebuild
}

protocol FlightCountdownSnapshotClient: Sendable {
    func persist(_ snapshot: FlightCountdownSnapshot?) async
    func persistHomeWidgetSchedule(_ snapshot: HomeWidgetScheduleSnapshot?) async
    func reloadWidgets() async
}

extension FlightCountdownSnapshotClient {
    func persistHomeWidgetSchedule(_ snapshot: HomeWidgetScheduleSnapshot?) async {}
}

#if os(iOS)
import WidgetKit

struct AppGroupFlightCountdownSnapshotClient: FlightCountdownSnapshotClient {
    func persist(_ snapshot: FlightCountdownSnapshot?) async {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FlightCountdownSharedStore.appGroupIdentifier
        ) else {
            return
        }

        let fileURL = containerURL.appendingPathComponent(
            FlightCountdownSharedStore.widgetSnapshotFileName
        )
        guard let snapshot else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A missing Home Screen Widget snapshot fails closed to its empty state.
        }
    }

    func persistHomeWidgetSchedule(_ snapshot: HomeWidgetScheduleSnapshot?) async {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FlightCountdownSharedStore.appGroupIdentifier
        ) else {
            return
        }
        let fileURL = containerURL.appendingPathComponent(
            FlightCountdownSharedStore.widgetSnapshotFileName
        )
        guard let snapshot else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // A missing Home Screen Widget schedule fails closed to its empty state.
        }
    }

    func reloadWidgets() async {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#else
struct AppGroupFlightCountdownSnapshotClient: FlightCountdownSnapshotClient {
    func persist(_ snapshot: FlightCountdownSnapshot?) async {}
    func persistHomeWidgetSchedule(_ snapshot: HomeWidgetScheduleSnapshot?) async {}
    func reloadWidgets() async {}
}
#endif

/// Publishes the shared countdown snapshot consumed by the Home Screen Widget.
///
/// Flight Countdown Live Activities were removed by product decision. This coordinator has no
/// ActivityKit dependency and cannot request, update, or end an Activity.
actor FlightCountdownCoordinator {
    private let snapshotClient: any FlightCountdownSnapshotClient

    init(
        snapshotClient: any FlightCountdownSnapshotClient = AppGroupFlightCountdownSnapshotClient()
    ) {
        self.snapshotClient = snapshotClient
    }

    func refresh(
        output: CountdownEngineOutput?,
        mode: FlightCountdownRefreshMode,
        nowUTC: Date = Date()
    ) async {
        let candidate = output.map { makeSnapshot(from: $0, nowUTC: nowUTC) }
        let snapshot = candidate.flatMap {
            $0.state == .expired ? nil : $0
        }

        switch mode {
        case .reconcile:
            await snapshotClient.persist(snapshot)
            await snapshotClient.reloadWidgets()
        case .destructiveRebuild:
            // Replacement teardown remains unconditional for the shared Widget snapshot. Clear
            // the old generation before publishing the revised generation.
            await snapshotClient.persist(nil)
            await snapshotClient.reloadWidgets()
            guard let snapshot else { return }
            await snapshotClient.persist(snapshot)
            await snapshotClient.reloadWidgets()
        }
    }

    func refreshHomeWidget(
        snapshot: HomeWidgetScheduleSnapshot?,
        mode: FlightCountdownRefreshMode
    ) async {
        switch mode {
        case .reconcile:
            await snapshotClient.persistHomeWidgetSchedule(snapshot)
            await snapshotClient.reloadWidgets()
        case .destructiveRebuild:
            await snapshotClient.persistHomeWidgetSchedule(nil)
            await snapshotClient.reloadWidgets()
            guard let snapshot else { return }
            await snapshotClient.persistHomeWidgetSchedule(snapshot)
            await snapshotClient.reloadWidgets()
        }
    }

    private func makeSnapshot(
        from output: CountdownEngineOutput,
        nowUTC: Date
    ) -> FlightCountdownSnapshot {
        FlightCountdownSnapshot(
            updatedAtUTC: nowUTC,
            state: output.state,
            visibility: output.visibility,
            legID: output.leg.id,
            flightNumber: output.leg.flightNumber,
            isDeadhead: output.leg.isDeadhead,
            departureAirportIATA: output.leg.departureAirportIATA,
            arrivalAirportIATA: output.leg.arrivalAirportIATA,
            plannedDepartureUTC: output.leg.plannedDepartureUTC,
            plannedArrivalUTC: output.leg.plannedArrivalUTC,
            reportTimeUTC: output.leg.reportTimeUTC,
            presentation: output.presentation,
            departureTimeZoneID: output.leg.departureTimeZoneID,
            arrivalTimeZoneID: output.leg.arrivalTimeZoneID,
            departureDateText: output.display.departureDateText,
            departureTimeText: output.display.departureTimeText,
            arrivalDateText: output.display.arrivalDateText,
            arrivalTimeText: output.display.arrivalTimeText
        )
    }
}
