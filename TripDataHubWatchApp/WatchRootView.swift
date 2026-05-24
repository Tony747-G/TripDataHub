import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var receiver: WatchSessionReceiver

    var body: some View {
        #if DEBUG
        DebugModePicker(liveSnapshot: receiver.latestSnapshot)
        #else
        modeView(for: receiver.latestSnapshot)
        #endif
    }

    @ViewBuilder
    func modeView(for snapshot: WatchOperationalSnapshot?) -> some View {
        switch snapshot?.mode {
        case .trip:
            if let p = snapshot?.trip { WatchTripModeView(payload: p) }
            else { WatchEmptyStateView() }
        case .reserve:
            if let p = snapshot?.reserve { WatchReserveModeView(payload: p) }
            else { WatchEmptyStateView() }
        case .training:
            if let p = snapshot?.training { WatchTrainingModeView(payload: p) }
            else { WatchEmptyStateView() }
        case .offDuty:
            if let p = snapshot?.offDuty { WatchOffDutyModeView(payload: p) }
            else { WatchEmptyStateView() }
        case nil:
            WatchEmptyStateView()
        }
    }
}

#if DEBUG
private struct DebugModePicker: View {
    let liveSnapshot: WatchOperationalSnapshot?
    @EnvironmentObject private var receiver: WatchSessionReceiver

    var body: some View {
        NavigationStack {
            List {
                // MARK: Live data
                if let snap = liveSnapshot {
                    Section("Live — \(snap.mode.rawValue)") {
                        NavigationLink("▶ View Live Data") {
                            WatchRootView().modeView(for: snap)
                                .environmentObject(receiver)
                        }
                        Text("Age: \(snapshotAgeLabel(snap))")
                            .font(.caption2)
                            .foregroundStyle(isStale(snap) ? .orange : .secondary)
                    }
                } else {
                    Section("Live snapshot") {
                        Text("No snapshot yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Mock data
                Section("Mock") {
                    NavigationLink("Trip (mock)",
                        destination: WatchTripModeView(payload: WatchOperationalSnapshot.mockTrip.trip!))
                    NavigationLink("Reserve (mock)",
                        destination: WatchReserveModeView(payload: WatchOperationalSnapshot.mockReserve.reserve!))
                    NavigationLink("Training (mock)",
                        destination: WatchTrainingModeView(payload: WatchOperationalSnapshot.mockTraining.training!))
                    NavigationLink("Off-Duty (mock)",
                        destination: WatchOffDutyModeView(payload: WatchOperationalSnapshot.mockOffDuty.offDuty!))
                    NavigationLink("Empty State", destination: WatchEmptyStateView())
                }
            }
            .navigationTitle("Watch Debug")
        }
    }

    private func snapshotAgeLabel(_ snap: WatchOperationalSnapshot) -> String {
        let seconds = Date().timeIntervalSince(snap.generatedAtUTC)
        if seconds < 60 { return "<1m ago" }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h \(minutes % 60)m ago"
    }

    private func isStale(_ snap: WatchOperationalSnapshot) -> Bool {
        Date().timeIntervalSince(snap.generatedAtUTC) > WatchSessionReceiver.staleThreshold
    }
}
#endif
