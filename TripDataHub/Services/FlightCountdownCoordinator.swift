import Foundation
import os

private let logger = Logger(subsystem: "com.sfune.TripDataHub", category: "FlightCountdown")

enum LiveActivityRefreshMode: Sendable {
    case reconcile
    case destructiveRebuild
}

struct FlightCountdownActivityRecord: Equatable, Sendable {
    let id: String
    let legID: String
}

protocol FlightCountdownActivityClient: Sendable {
    func waitForInitialActivityPopulation() async
    func activitiesEnabled() async -> Bool
    func activities() async -> [FlightCountdownActivityRecord]
    func update(activityID: String, snapshot: FlightCountdownSnapshot) async
    func request(snapshot: FlightCountdownSnapshot) async throws
    func end(activityID: String) async
}

protocol FlightCountdownSnapshotClient: Sendable {
    func persist(_ snapshot: FlightCountdownSnapshot?) async
    func reloadWidgets() async
}

#if os(iOS)
import ActivityKit
import WidgetKit

struct SystemFlightCountdownActivityClient: FlightCountdownActivityClient {
    private static let activityID = "next-flight-countdown"

    /// ActivityKit has no explicit "initial enumeration complete" callback. Require a launch
    /// grace period and two stable reads before the coordinator may reconcile an empty set.
    func waitForInitialActivityPopulation() async {
        var previousIDs: Set<String>?
        for attempt in 0..<8 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            } else {
                await Task.yield()
            }
            let currentIDs = Set(liveActivities().map(\.id))
            if attempt >= 2, currentIDs == previousIDs {
                return
            }
            previousIDs = currentIDs
        }
    }

    func activitiesEnabled() async -> Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func activities() async -> [FlightCountdownActivityRecord] {
        liveActivities().map {
            FlightCountdownActivityRecord(id: $0.id, legID: $0.content.state.legID)
        }
    }

    func update(activityID: String, snapshot: FlightCountdownSnapshot) async {
        guard let activity = liveActivities().first(where: { $0.id == activityID }) else { return }
        await activity.update(activityContent(for: snapshot))
    }

    func request(snapshot: FlightCountdownSnapshot) async throws {
        _ = try Activity.request(
            attributes: FlightCountdownAttributes(activityID: Self.activityID),
            content: activityContent(for: snapshot)
        )
    }

    func end(activityID: String) async {
        guard let activity = liveActivities().first(where: { $0.id == activityID }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func liveActivities() -> [Activity<FlightCountdownAttributes>] {
        Activity<FlightCountdownAttributes>.activities.filter {
            $0.attributes.activityID == Self.activityID
        }
    }

    private func activityContent(
        for snapshot: FlightCountdownSnapshot
    ) -> ActivityContent<FlightCountdownAttributes.ContentState> {
        ActivityContent(
            state: FlightCountdownAttributes.ContentState(
                legID: snapshot.legID,
                state: snapshot.state,
                flightNumber: snapshot.flightNumber,
                isDeadhead: snapshot.isDeadhead,
                departureAirportIATA: snapshot.departureAirportIATA,
                arrivalAirportIATA: snapshot.arrivalAirportIATA,
                plannedDepartureUTC: snapshot.plannedDepartureUTC,
                plannedArrivalUTC: snapshot.plannedArrivalUTC,
                reportTimeUTC: snapshot.reportTimeUTC,
                presentation: snapshot.presentation,
                departureTimeZoneID: snapshot.departureTimeZoneID,
                arrivalTimeZoneID: snapshot.arrivalTimeZoneID,
                departureDateText: snapshot.departureDateText,
                departureTimeText: snapshot.departureTimeText,
                arrivalDateText: snapshot.arrivalDateText,
                arrivalTimeText: snapshot.arrivalTimeText
            ),
            staleDate: FlightCountdownActivityLifecyclePolicy.staleDate(
                plannedDepartureUTC: snapshot.plannedDepartureUTC
            )
        )
    }
}

enum FlightCountdownActivityLifecyclePolicy {
    static func staleDate(plannedDepartureUTC: Date) -> Date {
        plannedDepartureUTC.addingTimeInterval(FlightOperationalState.expirationInterval)
    }
}

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
            logger.error("[FlightCountdown] snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reloadWidgets() async {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#else
struct SystemFlightCountdownActivityClient: FlightCountdownActivityClient {
    func waitForInitialActivityPopulation() async {}
    func activitiesEnabled() async -> Bool { false }
    func activities() async -> [FlightCountdownActivityRecord] { [] }
    func update(activityID: String, snapshot: FlightCountdownSnapshot) async {}
    func request(snapshot: FlightCountdownSnapshot) async throws {}
    func end(activityID: String) async {}
}

struct AppGroupFlightCountdownSnapshotClient: FlightCountdownSnapshotClient {
    func persist(_ snapshot: FlightCountdownSnapshot?) async {}
    func reloadWidgets() async {}
}
#endif

actor FlightCountdownCoordinator {
    private let activityClient: any FlightCountdownActivityClient
    private let snapshotClient: any FlightCountdownSnapshotClient
    private var initialPopulationWaitTask: Task<Void, Never>?

    init(
        activityClient: any FlightCountdownActivityClient = SystemFlightCountdownActivityClient(),
        snapshotClient: any FlightCountdownSnapshotClient = AppGroupFlightCountdownSnapshotClient()
    ) {
        self.activityClient = activityClient
        self.snapshotClient = snapshotClient
    }

    func refresh(
        output: CountdownEngineOutput?,
        mode: LiveActivityRefreshMode,
        nowUTC: Date = Date()
    ) async {
        await ensureInitialActivityPopulation()

        let candidate = output.map { makeSnapshot(from: $0, nowUTC: nowUTC) }
        let snapshot = candidate.flatMap {
            $0.state == .expired ? nil : $0
        }

        switch mode {
        case .reconcile:
            await reconcile(snapshot: snapshot)
        case .destructiveRebuild:
            await destructiveRebuild(snapshot: snapshot)
        }
    }

    /// Every entry point shares this one-time barrier. Storing the task before awaiting it closes
    /// the actor-reentrancy window where a concurrent scene refresh could enumerate Activities
    /// while the launch refresh was still waiting for ActivityKit to populate.
    private func ensureInitialActivityPopulation() async {
        if let initialPopulationWaitTask {
            await initialPopulationWaitTask.value
            return
        }

        let activityClient = self.activityClient
        let task = Task {
            await activityClient.waitForInitialActivityPopulation()
        }
        initialPopulationWaitTask = task
        await task.value
    }

    private func reconcile(snapshot: FlightCountdownSnapshot?) async {
        await snapshotClient.persist(snapshot)
        await snapshotClient.reloadWidgets()

        let activities = await activityClient.activities()
        guard let snapshot, snapshot.visibility == .liveActivity else {
            await end(activities)
            return
        }
        guard await activityClient.activitiesEnabled() else {
            await end(activities)
            return
        }

        if let matching = activities.first(where: { $0.legID == snapshot.legID }) {
            await end(activities.filter { $0.id != matching.id })
            await activityClient.update(activityID: matching.id, snapshot: snapshot)
            return
        }

        await end(activities)
        await request(snapshot)
    }

    private func destructiveRebuild(snapshot: FlightCountdownSnapshot?) async {
        // Replacement teardown is unconditional: never rely on revised leg identity to find old
        // artifacts. Clear the shared snapshot before rebuilding from the revised source.
        await snapshotClient.persist(nil)
        await snapshotClient.reloadWidgets()
        await end(await activityClient.activities())

        guard let snapshot else { return }
        await snapshotClient.persist(snapshot)
        await snapshotClient.reloadWidgets()
        guard snapshot.visibility == .liveActivity,
              await activityClient.activitiesEnabled() else { return }
        await request(snapshot)
    }

    private func request(_ snapshot: FlightCountdownSnapshot) async {
        do {
            try await activityClient.request(snapshot: snapshot)
        } catch {
            logger.error("[FlightCountdown] live activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end(_ activities: [FlightCountdownActivityRecord]) async {
        for activity in activities {
            await activityClient.end(activityID: activity.id)
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
