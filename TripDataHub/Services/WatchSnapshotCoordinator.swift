import Foundation
import Combine

@MainActor
final class WatchSnapshotCoordinator {
    let transport: WatchSnapshotSending
    private var cancellables: Set<AnyCancellable> = []

    init(transport: WatchSnapshotSending = WatchSessionManager.shared) {
        self.transport = transport
        // Access AppViewModel.shared inside the @MainActor init body, not as a
        // default parameter value — default parameter values are evaluated in a
        // nonisolated context, which cannot reference @MainActor properties.
        let appViewModel = AppViewModel.shared
        appViewModel.$schedules
            .combineLatest(appViewModel.$manualOperationalEvents)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] schedules, events in
                self?.sendSnapshot(
                    schedules: schedules,
                    events: events,
                    crewBase: OperationalSettings.selectedCrewBase()
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: OperationalSettings.crewBaseDidChangeNotification)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sendSnapshot(
                    schedules: appViewModel.schedules,
                    events: appViewModel.manualOperationalEvents,
                    crewBase: OperationalSettings.selectedCrewBase()
                )
            }
            .store(in: &cancellables)
    }

    /// Testable entry point — bypasses the Combine subscription.
    func sendSnapshot(schedules: [PayPeriodSchedule],
                      events: [ManualOperationalEvent],
                      crewBase: CrewBase) {
        let snapshot = WatchSnapshotGenerator.generate(
            schedules: schedules,
            manualEvents: events,
            crewBase: crewBase
        )
        try? transport.sendSnapshot(snapshot)
    }
}
