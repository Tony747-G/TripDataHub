import Foundation

enum ImportFingerprintLedgerState: String, Codable, Equatable {
    case active
    case consumed
    case dismissed
}

enum ImportFingerprintClaimResult: Equatable {
    case accepted
    case suppressed(ImportFingerprintLedgerState)
}

/// Cross-delivery content identity for CrewAccess imports.
///
/// URL/file-name gates remain cheap burst filters. This ledger is the authoritative identity layer
/// shared by browser imports, external-open URLs, and App Group handoffs.
final class ImportFingerprintLedger: @unchecked Sendable {
    private struct Entry: Codable {
        var state: ImportFingerprintLedgerState
        var updatedAt: Date
    }

    static let burstWindow: TimeInterval = 120
    private static let storageKey = "crewaccess_import_fingerprint_ledger_v2"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var entries: [String: Entry]

    init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }

        // A preview is not restored across process launch. An interrupted active claim therefore
        // becomes a short dismissed-burst guard instead of suppressing the content indefinitely.
        let recoveryDate = now()
        for fingerprint in entries.keys where entries[fingerprint]?.state == .active {
            entries[fingerprint] = Entry(state: .dismissed, updatedAt: recoveryDate)
        }
        pruneAndPersist(now: recoveryDate)
    }

    func claim(_ fingerprint: String) -> ImportFingerprintClaimResult {
        lock.lock()
        defer { lock.unlock() }
        let currentDate = now()
        prune(now: currentDate)
        if let entry = entries[fingerprint] {
            switch entry.state {
            case .active:
                persist()
                return .suppressed(.active)
            case .consumed, .dismissed:
                if currentDate.timeIntervalSince(entry.updatedAt) < Self.burstWindow {
                    persist()
                    return .suppressed(entry.state)
                }
            }
        }
        entries[fingerprint] = Entry(state: .active, updatedAt: currentDate)
        persist()
        return .accepted
    }

    func suppressionState(for fingerprint: String) -> ImportFingerprintLedgerState? {
        lock.lock()
        defer { lock.unlock() }
        let currentDate = now()
        prune(now: currentDate)
        persist()
        guard let entry = entries[fingerprint] else { return nil }
        if entry.state == .active || currentDate.timeIntervalSince(entry.updatedAt) < Self.burstWindow {
            return entry.state
        }
        return nil
    }

    func markConsumed(_ fingerprint: String) {
        transition(fingerprint, to: .consumed)
    }

    func markDismissed(_ fingerprint: String) {
        transition(fingerprint, to: .dismissed)
    }

    /// Releases a claim whose import ended before it could be consumed or dismissed.
    ///
    /// A terminal commit failure is not a delivery burst outcome: the user must be able to retry
    /// the same PDF immediately. Only `.active` is removable here so this cannot weaken the
    /// 120-second suppression contract for successfully consumed or explicitly dismissed content.
    func releaseActiveClaim(_ fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        let currentDate = now()
        prune(now: currentDate)
        guard entries[fingerprint]?.state == .active else {
            persist()
            return
        }
        entries.removeValue(forKey: fingerprint)
        persist()
    }

    private func transition(_ fingerprint: String, to state: ImportFingerprintLedgerState) {
        lock.lock()
        defer { lock.unlock() }
        let currentDate = now()
        prune(now: currentDate)
        entries[fingerprint] = Entry(state: state, updatedAt: currentDate)
        persist()
    }

    private func pruneAndPersist(now currentDate: Date) {
        lock.lock()
        defer { lock.unlock() }
        prune(now: currentDate)
        persist()
    }

    private func prune(now currentDate: Date) {
        entries = entries.filter { _, entry in
            entry.state == .active || currentDate.timeIntervalSince(entry.updatedAt) < Self.burstWindow
        }
    }

    private func persist() {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
