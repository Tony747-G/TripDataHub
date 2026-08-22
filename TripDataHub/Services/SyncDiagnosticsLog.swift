import CryptoKit
import Foundation

/// Stable machine-readable codes for the sync diagnostics ring buffer.
///
/// Values are matched by eye in a support conversation, so they must not be renamed casually.
enum SyncDiagnosticCode: String, Codable {
    // Lifecycle
    case appLaunched = "app_launched"
    case appForegrounded = "app_foregrounded"
    case startupRecoveryBegan = "startup_recovery_began"
    case startupRecoveryEnded = "startup_recovery_ended"
    case identityResolved = "identity_resolved"
    case identityUnavailable = "identity_unavailable"

    // Local mutation
    case manualEventSaved = "manual_event_saved"
    case manualEventDeleted = "manual_event_deleted"
    case localSnapshotLoaded = "local_snapshot_loaded"

    // Upload request lifecycle — one code per early exit so a silent return is never ambiguous.
    case uploadRequested = "upload_requested"
    case uploadAlreadyActive = "upload_already_active"
    case uploadCoalesced = "upload_coalesced"
    case identityNotVerified = "identity_not_verified"
    case verifiedIdentityMissing = "verified_identity_missing"
    case recordNameMissing = "record_name_missing"
    case fingerprintUnchanged = "fingerprint_unchanged"
    case uploadStarted = "upload_started"
    case uploadSucceeded = "upload_succeeded"
    case uploadFailed = "upload_failed"

    // Fetch / merge
    case fetchStarted = "fetch_started"
    case fetchSucceeded = "fetch_succeeded"
    case fetchFailed = "fetch_failed"
    case fetchNoRemoteRecord = "fetch_no_remote_record"
    case fetchSkippedWatermark = "fetch_skipped_watermark"
    case snapshotsMerged = "snapshots_merged"
    case mergedSnapshotPersisted = "merged_snapshot_persisted"
    case mergeNoChange = "merge_no_change"

    // Flight operational state
    case flightStateInputExcluded = "flight_state_input_excluded"

}

struct SyncDiagnosticEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let code: String
    /// Small, non-identifying key/value pairs. Never contains event titles, notes, dates of an
    /// event, a full GEMS ID or a full CloudKit record name.
    let fields: [String: String]

    init(id: UUID = UUID(), timestamp: Date = Date(), code: SyncDiagnosticCode, fields: [String: String]) {
        self.id = id
        self.timestamp = timestamp
        self.code = code.rawValue
        self.fields = fields
    }
}

/// On-device ring buffer of sync diagnostics, surfaced in Settings.
///
/// Persisted to disk because the questions we need to answer span a relaunch — what happened during
/// startup recovery *before* the restart is exactly the interesting part, and a company-managed iPad
/// cannot be attached to `log stream`.
///
/// Deliberately records no Personal Event content. Identifiers are reduced to short salted-free
/// SHA256 prefixes, which are enough to correlate the same event across two devices without
/// revealing it.
@MainActor
final class SyncDiagnosticsLog: ObservableObject {
    static let shared = SyncDiagnosticsLog()

    @Published private(set) var entries: [SyncDiagnosticEntry] = []

    private let capacity: Int
    private let fileURL: URL?

    init(directory: URL? = SyncDiagnosticsLog.defaultDirectory(), capacity: Int = 200) {
        self.capacity = capacity
        self.fileURL = directory?.appendingPathComponent("sync_diagnostics_v1.json")
        self.entries = loadPersisted()
    }

    private nonisolated static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    func record(_ code: SyncDiagnosticCode, _ fields: [String: String] = [:]) {
        entries.append(SyncDiagnosticEntry(code: code, fields: fields))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    /// Plain text for the Copy button. One line per entry, oldest first.
    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines = ["TripDataHub sync diagnostics", "entries=\(entries.count)", ""]
        for entry in entries {
            let fields = entry.fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append("\(formatter.string(from: entry.timestamp)) \(entry.code) \(fields)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Privacy helpers

    /// Short, stable, non-reversible tag for an identifier. Enough to line up the same event or
    /// account across two devices' logs; not enough to recover the value.
    nonisolated static func tag(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    nonisolated static func tag(_ value: UUID) -> String {
        tag(value.uuidString)
    }

    /// First 8 characters of an already-hashed fingerprint, or "nil".
    nonisolated static func shortFingerprint(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        return String(value.prefix(8))
    }

    // MARK: - Persistence

    private func loadPersisted() -> [SyncDiagnosticEntry] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SyncDiagnosticEntry].self, from: data)
        else { return [] }
        return decoded.suffix(capacity)
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
