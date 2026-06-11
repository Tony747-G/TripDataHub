import Foundation

/// Shared App Group handoff contract between the main app and the share extension.
/// Both targets compile this file, so the identifiers and the file format can
/// never drift apart.
///
/// Each share writes its own queue file (`pending-share-<uuid>.json`, one entry).
/// One-file-per-share means there is no read-modify-write anywhere: the extension
/// only ever creates new files, and the app only deletes queue files it has already
/// read. A shared mutable manifest would race — the app could read `[A]`, the
/// extension append `B`, and the app then delete the whole manifest, silently
/// losing `B`. With per-share files the worst case is that a file written during
/// consumption is picked up on the next foreground instead — never lost.
enum AppGroupImportHandoff {
    static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    static let directoryName = "CrewAccessSharedImports"

    /// Single-slot manifest written by pre-queue versions of the extension.
    /// Still read (and then deleted) on consume so an app update that lands
    /// mid-handoff imports the pending share. New code never writes it.
    static let legacyManifestFileName = "pending_import.json"

    static let queueFilePrefix = "pending-share-"
    static let queueFileExtension = "json"

    struct Entry: Codable, Equatable {
        let fileName: String
        let createdAtISO8601: String?
    }

    /// Unique name for a new share's queue file.
    static func makeQueueFileName() -> String {
        "\(queueFilePrefix)\(UUID().uuidString).\(queueFileExtension)"
    }

    static func isQueueFileName(_ name: String) -> Bool {
        name.hasPrefix(queueFilePrefix) && name.hasSuffix(".\(queueFileExtension)")
    }

    /// Accepts a single-entry queue file, plus the legacy array and legacy
    /// single-object manifest formats.
    static func decodeEntries(from data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        if let entries = try? decoder.decode([Entry].self, from: data) {
            return entries
        }
        if let single = try? decoder.decode(Entry.self, from: data) {
            return [single]
        }
        return []
    }

    static func encodeEntry(_ entry: Entry) throws -> Data {
        try JSONEncoder().encode(entry)
    }
}
