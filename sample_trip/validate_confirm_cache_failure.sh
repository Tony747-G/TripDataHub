#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$script_dir/.." && pwd)
TMP_SWIFT="$(mktemp /tmp/crewaccess_confirm_cachefail.XXXXXX.swift)"
TMP_BIN="$(mktemp /tmp/crewaccess_confirm_cachefail.XXXXXX.bin)"
trap 'rm -f "$TMP_SWIFT" "$TMP_BIN"' EXIT

cat > "$TMP_SWIFT" <<'SWIFT'
import Foundation
import UserNotifications

final class MockSyncService: TripBoardSyncServiceProtocol {
    func sync(cookies: [HTTPCookie]) async throws -> [PayPeriodSchedule] { [] }
}

final class MockAuthService: TripBoardAuthServiceProtocol {
    func loadPersistedCookies() -> [HTTPCookie] { [] }
    func persistCookies(_ cookies: [HTTPCookie]) throws {}
    func clearPersistedCookies() throws {}
    func isAuthenticated(url: URL?, cookies: [HTTPCookie]) -> Bool { false }
    @MainActor func currentWebKitCookies() async -> [HTTPCookie] { [] }
    @MainActor func clearWebKitCookies() async {}
}

final class MockNotificationService: NextReportNotificationServiceProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
    }
}

final class ThrowingCacheService: ScheduleCacheServiceProtocol {
    private(set) var saveAttempts = 0

    func load() -> ScheduleCacheSnapshot? { nil }

    func save(_ snapshot: ScheduleCacheSnapshot) throws {
        saveAttempts += 1
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Intentional cache save failure"])
    }

    func clear() {}
}

@main
struct Main {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: validate_confirm_cache_failure <repo_root>\n", stderr)
            Foundation.exit(2)
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let pdfURL = root.appendingPathComponent("sample_trip/2026-03-04_A70878.pdf")
        let pdfData = try Data(contentsOf: pdfURL)
        let parser = CrewAccessPDFImportService()
        let preview = parser.analyzeTrip(pdfData: pdfData, sourceFileName: pdfURL.lastPathComponent)

        guard preview.errors.isEmpty,
              let _ = preview.parsedSchedule,
              let _ = preview.jsonPayload else {
            fputs("Precondition failed: parser must produce pending import for sample PDF\n", stderr)
            Foundation.exit(1)
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outDir = docs.appendingPathComponent("CrewAccessImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let finalName = "\(preview.tripId.replacingOccurrences(of: "/", with: "-"))_\(preview.tripDate).json"
        let finalURL = outDir.appendingPathComponent(finalName)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }

        let cache = ThrowingCacheService()
        let vm = await MainActor.run {
            AppViewModel(
                syncService: MockSyncService(),
                authService: MockAuthService(),
                cacheService: cache,
                notificationService: MockNotificationService(),
                crewAccessImportService: parser
            )
        }

        let beforeSchedules = await MainActor.run { vm.schedules }

        await MainActor.run {
            _ = vm.importCrewAccessPDFData(pdfData, sourceFileName: pdfURL.lastPathComponent)
            vm.confirmPendingImport()
        }

        let afterSchedules = await MainActor.run { vm.schedules }
        let pendingStillThere = await MainActor.run { vm.pendingImport != nil }
        let message = await MainActor.run { vm.crewAccessImportMessage ?? "" }
        let jsonExistsAfter = FileManager.default.fileExists(atPath: finalURL.path)

        let schedulesUnchanged = (beforeSchedules == afterSchedules)
        let cacheAttempted = cache.saveAttempts == 1
        let hasFailureMessage = message.contains("Import failed") && message.contains("No changes were applied")
        let jsonRolledBack = !jsonExistsAfter

        if schedulesUnchanged && cacheAttempted && pendingStillThere && hasFailureMessage && jsonRolledBack {
            print("PASS validate_confirm_cache_failure")
            print("- schedulesUnchanged=\(schedulesUnchanged)")
            print("- cacheSaveAttempts=\(cache.saveAttempts)")
            print("- pendingStillThere=\(pendingStillThere)")
            print("- jsonRolledBack=\(jsonRolledBack)")
            print("- message=\(message)")
        } else {
            fputs("FAIL validate_confirm_cache_failure\n", stderr)
            fputs("- schedulesUnchanged=\(schedulesUnchanged)\n", stderr)
            fputs("- cacheSaveAttempts=\(cache.saveAttempts)\n", stderr)
            fputs("- pendingStillThere=\(pendingStillThere)\n", stderr)
            fputs("- jsonExistsAfter=\(jsonExistsAfter)\n", stderr)
            fputs("- message=\(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
SWIFT

xcrun swiftc \
  -o "$TMP_BIN" \
  "$TMP_SWIFT" \
  "$ROOT/TripDataHub/Models/TripModels.swift" \
  "$ROOT/TripDataHub/Services/CrewAccessPDFImportService.swift" \
  "$ROOT/TripDataHub/Services/ScheduleCacheService.swift" \
  "$ROOT/TripDataHub/Services/TripBoardSyncService.swift" \
  "$ROOT/TripDataHub/Services/TripBoardAuthService.swift" \
  "$ROOT/TripDataHub/Services/KeychainService.swift" \
  "$ROOT/TripDataHub/Services/NextReportNotificationService.swift" \
  "$ROOT/TripDataHub/Services/NextReportWindowBuilder.swift" \
  "$ROOT/TripDataHub/ViewModels/AppViewModel.swift"

"$TMP_BIN" "$ROOT"
