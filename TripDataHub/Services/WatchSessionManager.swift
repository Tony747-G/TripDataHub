import Foundation
import WatchConnectivity

// MARK: - Protocol (for testability)

protocol WatchSnapshotSending {
    func sendSnapshot(_ snapshot: WatchOperationalSnapshot) throws
}

// MARK: - Errors

enum WatchSendError: Error {
    case sessionNotSupported
    case notActivated
    case watchNotPaired
    case contextUpdateFailed(Error)
}

// MARK: - Production implementation

final class WatchSessionManager: NSObject, WatchSnapshotSending {
    static let shared = WatchSessionManager()
    private let pendingSnapshotLock = NSLock()
    private var pendingSnapshot: WatchOperationalSnapshot?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .notActivated else { return }
        session.delegate = self
        session.activate()
    }

    func sendSnapshot(_ snapshot: WatchOperationalSnapshot) throws {
        guard WCSession.isSupported() else { throw WatchSendError.sessionNotSupported }
        let session = WCSession.default
        guard session.activationState == .activated else {
            setPendingSnapshot(snapshot)
            throw WatchSendError.notActivated
        }
        guard session.isPaired else { throw WatchSendError.watchNotPaired }
        let data = try snapshot.encode()
        do {
            try session.updateApplicationContext([WatchTransportKey.snapshot: data])
            setPendingSnapshot(nil)
        } catch {
            throw WatchSendError.contextUpdateFailed(error)
        }
    }

    private func setPendingSnapshot(_ snapshot: WatchOperationalSnapshot?) {
        pendingSnapshotLock.lock()
        pendingSnapshot = snapshot
        pendingSnapshotLock.unlock()
    }

    private func takePendingSnapshot() -> WatchOperationalSnapshot? {
        pendingSnapshotLock.lock()
        defer { pendingSnapshotLock.unlock() }
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        return snapshot
    }
}

extension WatchSessionManager: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated, let pendingSnapshot = takePendingSnapshot() else { return }
        try? sendSnapshot(pendingSnapshot)
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
