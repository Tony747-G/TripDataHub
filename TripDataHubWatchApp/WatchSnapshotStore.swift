import Foundation

enum WatchSnapshotStore {
    private static let key = "watch_snapshot_v1"

    static func save(_ snapshot: WatchOperationalSnapshot) {
        guard let data = try? snapshot.encode() else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> WatchOperationalSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? WatchOperationalSnapshot.decode(from: data) else { return nil }
        return snapshot
    }
}
