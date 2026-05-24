import Foundation
import WatchConnectivity

final class WatchSessionReceiver: NSObject, ObservableObject {
    @Published private(set) var latestSnapshot: WatchOperationalSnapshot?

    /// Snapshot older than this is considered stale for display purposes.
    /// Production UI currently shows stale snapshots as-is; this constant is
    /// reserved for a future staleness indicator or refresh trigger.
    static let staleThreshold: TimeInterval = 4 * 60 * 60  // 4 hours

    func activate() {
        guard WCSession.isSupported() else { return }
        latestSnapshot = WatchSnapshotStore.load()
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }
}

extension WatchSessionReceiver: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Re-read context delivered while app was not running
        let context = session.receivedApplicationContext
        applyContext(context)
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
    }

    private func applyContext(_ context: [String: Any]) {
        guard let data = context[WatchTransportKey.snapshot] as? Data,
              let snapshot = try? WatchOperationalSnapshot.decode(from: data) else { return }

        // Deduplicate: skip update if operational content is identical
        if let current = latestSnapshot, snapshot.contentEquals(current) { return }

        DispatchQueue.main.async { [weak self] in
            self?.latestSnapshot = snapshot
            WatchSnapshotStore.save(snapshot)
        }
    }
}
