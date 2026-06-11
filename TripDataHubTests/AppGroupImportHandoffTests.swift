import XCTest
@testable import TripDataHub

/// Verifies the App Group handoff contract shared by the app and the share
/// extension: one queue file per share (no read-modify-write anywhere, so a
/// share can never race the app's consumption), plus legacy-manifest decoding.
final class AppGroupImportHandoffTests: XCTestCase {

    // MARK: - Queue file naming

    func test_makeQueueFileName_isRecognizedAndUnique() {
        let first = AppGroupImportHandoff.makeQueueFileName()
        let second = AppGroupImportHandoff.makeQueueFileName()

        XCTAssertTrue(AppGroupImportHandoff.isQueueFileName(first))
        XCTAssertTrue(AppGroupImportHandoff.isQueueFileName(second))
        XCTAssertNotEqual(first, second, "Two shares must never collide on the same queue file")
    }

    func test_isQueueFileName_rejectsOtherDirectoryContents() {
        XCTAssertFalse(
            AppGroupImportHandoff.isQueueFileName(AppGroupImportHandoff.legacyManifestFileName),
            "The legacy manifest is handled by its own code path"
        )
        XCTAssertFalse(AppGroupImportHandoff.isQueueFileName("ABC123-Trip_Information.pdf"))
        XCTAssertFalse(AppGroupImportHandoff.isQueueFileName("pending-share-incomplete"))
    }

    // MARK: - Entry decoding

    func test_decodeEntries_readsSingleQueueFileEntry() throws {
        let entry = AppGroupImportHandoff.Entry(
            fileName: "Shared.pdf",
            createdAtISO8601: "2026-06-11T10:00:00Z"
        )
        let data = try AppGroupImportHandoff.encodeEntry(entry)

        XCTAssertEqual(AppGroupImportHandoff.decodeEntries(from: data), [entry])
    }

    func test_decodeEntries_readsLegacyArrayManifest() {
        let json = """
        [
            {"fileName": "A.pdf", "createdAtISO8601": "2026-06-11T10:00:00Z"},
            {"fileName": "B.pdf", "createdAtISO8601": "2026-06-11T10:00:05Z"}
        ]
        """
        let entries = AppGroupImportHandoff.decodeEntries(from: Data(json.utf8))

        XCTAssertEqual(entries.map(\.fileName), ["A.pdf", "B.pdf"])
    }

    func test_decodeEntries_readsLegacySingleObjectManifest() {
        // Format written by the original (pre-manifest) extension.
        let json = """
        {"fileName": "Legacy.pdf", "createdAtISO8601": "2026-06-01T08:00:00Z"}
        """
        let entries = AppGroupImportHandoff.decodeEntries(from: Data(json.utf8))

        XCTAssertEqual(entries.map(\.fileName), ["Legacy.pdf"])
    }

    func test_decodeEntries_returnsEmptyForGarbage() {
        XCTAssertTrue(AppGroupImportHandoff.decodeEntries(from: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(AppGroupImportHandoff.decodeEntries(from: Data()).isEmpty)
    }

    // MARK: - Concurrent share safety (the race the design exists to prevent)

    func test_concurrentShare_isNeverLostWhenConsumerDeletesOnlyReadFiles() throws {
        // Simulates: app lists the directory and reads share A; extension writes
        // share B concurrently; app deletes only the queue files it read.
        // With per-share files, B's queue file must survive for the next consume.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff_race_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func writeShare(_ pdfName: String) throws -> URL {
            let url = directory.appendingPathComponent(AppGroupImportHandoff.makeQueueFileName())
            let entry = AppGroupImportHandoff.Entry(fileName: pdfName, createdAtISO8601: nil)
            try AppGroupImportHandoff.encodeEntry(entry).write(to: url, options: .atomic)
            return url
        }

        func listQueueFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { AppGroupImportHandoff.isQueueFileName($0.lastPathComponent) }
        }

        let shareA = try writeShare("A.pdf")
        let consumedSnapshot = try listQueueFiles()           // app reads the directory
        _ = try writeShare("B.pdf")                           // extension writes B mid-consume
        for url in consumedSnapshot {                         // app deletes only what it read
            try FileManager.default.removeItem(at: url)
        }

        let remaining = try listQueueFiles()
        XCTAssertEqual(remaining.count, 1, "Share B must survive the concurrent consume")
        let survivingEntry = try XCTUnwrap(
            AppGroupImportHandoff.decodeEntries(from: Data(contentsOf: XCTUnwrap(remaining.first))).first
        )
        XCTAssertEqual(survivingEntry.fileName, "B.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareA.path))
    }
}
