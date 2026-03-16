import Foundation

#if os(iOS)
import ActivityKit
import WidgetKit

actor FlightCountdownCoordinator {
    private static let activityID = "next-flight-countdown"

    func refresh(output: CountdownEngineOutput?, nowUTC: Date = Date()) async {
        let snapshot = output.map { makeSnapshot(from: $0, nowUTC: nowUTC) }
        persistSnapshot(snapshot)
        reloadWidgets()
        await reconcileLiveActivity(with: snapshot)
    }

    private func makeSnapshot(from output: CountdownEngineOutput, nowUTC: Date) -> FlightCountdownSnapshot {
        FlightCountdownSnapshot(
            updatedAtUTC: nowUTC,
            phase: output.phase,
            legID: output.leg.id,
            flightNumber: output.leg.flightNumber,
            isDeadhead: output.leg.isDeadhead,
            departureAirportIATA: output.leg.departureAirportIATA,
            arrivalAirportIATA: output.leg.arrivalAirportIATA,
            scheduledDepartureUTC: output.leg.scheduledDepartureUTC,
            scheduledArrivalUTC: output.leg.scheduledArrivalUTC,
            departureTimeZoneID: output.leg.departureTimeZoneID,
            arrivalTimeZoneID: output.leg.arrivalTimeZoneID,
            departureDateText: output.display.departureDateText,
            departureTimeText: output.display.departureTimeText,
            arrivalDateText: output.display.arrivalDateText,
            arrivalTimeText: output.display.arrivalTimeText
        )
    }

    private func persistSnapshot(_ snapshot: FlightCountdownSnapshot?) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FlightCountdownSharedStore.appGroupIdentifier
        ) else {
            return
        }

        let fileURL = containerURL.appendingPathComponent(FlightCountdownSharedStore.widgetSnapshotFileName)
        if snapshot == nil {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[FlightCountdown] snapshot write failed: %@", error.localizedDescription)
        }
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func contentState(from snapshot: FlightCountdownSnapshot) -> FlightCountdownAttributes.ContentState {
        FlightCountdownAttributes.ContentState(
            legID: snapshot.legID,
            phase: snapshot.phase,
            flightNumber: snapshot.flightNumber,
            isDeadhead: snapshot.isDeadhead,
            departureAirportIATA: snapshot.departureAirportIATA,
            arrivalAirportIATA: snapshot.arrivalAirportIATA,
            scheduledDepartureUTC: snapshot.scheduledDepartureUTC,
            scheduledArrivalUTC: snapshot.scheduledArrivalUTC,
            departureTimeZoneID: snapshot.departureTimeZoneID,
            arrivalTimeZoneID: snapshot.arrivalTimeZoneID,
            departureDateText: snapshot.departureDateText,
            departureTimeText: snapshot.departureTimeText,
            arrivalDateText: snapshot.arrivalDateText,
            arrivalTimeText: snapshot.arrivalTimeText
        )
    }

    private func staleDate(for snapshot: FlightCountdownSnapshot) -> Date {
        snapshot.scheduledDepartureUTC.addingTimeInterval(6 * 60 * 60)
    }

    private func isLiveActivityPhase(_ phase: CountdownPresentationPhase) -> Bool {
        phase == .liveCountdown || phase == .liveDelayed
    }

    private func activityContent(for snapshot: FlightCountdownSnapshot) -> ActivityContent<FlightCountdownAttributes.ContentState> {
        ActivityContent(
            state: contentState(from: snapshot),
            staleDate: staleDate(for: snapshot)
        )
    }

    private func liveActivities() -> [Activity<FlightCountdownAttributes>] {
        Activity<FlightCountdownAttributes>.activities.filter { $0.attributes.activityID == Self.activityID }
    }

    private func end(_ activities: [Activity<FlightCountdownAttributes>]) async {
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func reconcileLiveActivity(with snapshot: FlightCountdownSnapshot?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let activities = liveActivities()
        guard let snapshot, isLiveActivityPhase(snapshot.phase) else {
            await end(activities)
            return
        }

        let content = activityContent(for: snapshot)
        let matching = activities.first { $0.content.state.legID == snapshot.legID }
        let nonMatching = activities.filter { $0.content.state.legID != snapshot.legID }
        if !nonMatching.isEmpty {
            await end(nonMatching)
        }

        if let matching {
            await matching.update(content)
            return
        }

        do {
            _ = try Activity.request(
                attributes: FlightCountdownAttributes(activityID: Self.activityID),
                content: content
            )
        } catch {
            NSLog("[FlightCountdown] live activity request failed: %@", error.localizedDescription)
        }
    }
}
#else
actor FlightCountdownCoordinator {
    func refresh(output: CountdownEngineOutput?, nowUTC: Date = Date()) async {}
}
#endif
