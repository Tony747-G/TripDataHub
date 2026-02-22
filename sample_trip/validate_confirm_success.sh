#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$script_dir/.." && pwd)
TMP_SWIFT="$(mktemp /tmp/crewaccess_confirm_success.XXXXXX.swift)"
TMP_BIN="$(mktemp /tmp/crewaccess_confirm_success.XXXXXX.bin)"
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

final class TrackingCacheService: ScheduleCacheServiceProtocol {
    private(set) var saveCount = 0

    func load() -> ScheduleCacheSnapshot? { nil }

    func save(_ snapshot: ScheduleCacheSnapshot) throws {
        saveCount += 1
    }

    func clear() {}
}

@main
struct Main {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: validate_confirm_success <repo_root>\n", stderr)
            Foundation.exit(2)
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let pdfURL = root.appendingPathComponent("sample_trip/2026-03-04_A70878.pdf")
        let pdfData = try Data(contentsOf: pdfURL)
        let parser = CrewAccessPDFImportService()
        let preview = parser.analyzeTrip(pdfData: pdfData, sourceFileName: pdfURL.lastPathComponent)

        guard preview.errors.isEmpty,
              let parsedSchedule = preview.parsedSchedule,
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

        let cache = TrackingCacheService()
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
        }
        let beforeConfirmSchedules = await MainActor.run { vm.schedules }
        let jsonMissingBeforeConfirm = !FileManager.default.fileExists(atPath: finalURL.path)
        let cacheZeroBeforeConfirm = cache.saveCount == 0

        await MainActor.run {
            vm.confirmPendingImport()
        }

        let afterFirstConfirm = await MainActor.run { vm.schedules }
        let firstChanged = afterFirstConfirm != beforeSchedules
        let firstContainsTrip = afterFirstConfirm.flatMap(\.legs).contains { $0.pairing == preview.tripId }
        let firstLegCount = afterFirstConfirm.flatMap(\.legs).filter { $0.pairing == preview.tripId }.count
        let cacheOneAfterFirst = cache.saveCount == 1
        let jsonExistsAfterFirst = FileManager.default.fileExists(atPath: finalURL.path)

        let jsonMetaOK: Bool = {
            guard let data = try? Data(contentsOf: finalURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            let required = ["schemaVersion", "source", "sourceVersion", "mappingVersion", "generatedAt", "items"]
            return required.allSatisfy { obj[$0] != nil }
        }()

        await MainActor.run {
            _ = vm.importCrewAccessPDFData(pdfData, sourceFileName: pdfURL.lastPathComponent)
            vm.confirmPendingImport()
        }

        let afterSecondConfirm = await MainActor.run { vm.schedules }
        let secondLegCount = afterSecondConfirm.flatMap(\.legs).filter { $0.pairing == preview.tripId }.count
        let noSilentDup = secondLegCount == firstLegCount && firstLegCount == parsedSchedule.legs.count
        let cacheTwoAfterSecond = cache.saveCount == 2
        let jsonExistsAfterSecond = FileManager.default.fileExists(atPath: finalURL.path)

        let pass = beforeConfirmSchedules == beforeSchedules
            && jsonMissingBeforeConfirm
            && cacheZeroBeforeConfirm
            && firstChanged
            && firstContainsTrip
            && cacheOneAfterFirst
            && jsonExistsAfterFirst
            && jsonMetaOK
            && noSilentDup
            && cacheTwoAfterSecond
            && jsonExistsAfterSecond

        if pass {
            print("PASS validate_confirm_success")
            print("- unchangedBeforeConfirm=\(beforeConfirmSchedules == beforeSchedules)")
            print("- cacheZeroBeforeConfirm=\(cacheZeroBeforeConfirm)")
            print("- jsonMissingBeforeConfirm=\(jsonMissingBeforeConfirm)")
            print("- firstContainsTrip=\(firstContainsTrip)")
            print("- firstLegCount=\(firstLegCount)")
            print("- secondLegCount=\(secondLegCount)")
            print("- noSilentDup=\(noSilentDup)")
            print("- cacheSaveCount=\(cache.saveCount)")
            print("- jsonMetaOK=\(jsonMetaOK)")
        } else {
            fputs("FAIL validate_confirm_success\n", stderr)
            fputs("- unchangedBeforeConfirm=\(beforeConfirmSchedules == beforeSchedules)\n", stderr)
            fputs("- cacheZeroBeforeConfirm=\(cacheZeroBeforeConfirm)\n", stderr)
            fputs("- jsonMissingBeforeConfirm=\(jsonMissingBeforeConfirm)\n", stderr)
            fputs("- firstChanged=\(firstChanged)\n", stderr)
            fputs("- firstContainsTrip=\(firstContainsTrip)\n", stderr)
            fputs("- firstLegCount=\(firstLegCount)\n", stderr)
            fputs("- secondLegCount=\(secondLegCount)\n", stderr)
            fputs("- noSilentDup=\(noSilentDup)\n", stderr)
            fputs("- cacheSaveCount=\(cache.saveCount)\n", stderr)
            fputs("- jsonExistsAfterFirst=\(jsonExistsAfterFirst)\n", stderr)
            fputs("- jsonExistsAfterSecond=\(jsonExistsAfterSecond)\n", stderr)
            fputs("- jsonMetaOK=\(jsonMetaOK)\n", stderr)
            Foundation.exit(1)
        }
    }
}
SWIFT

xcrun swiftc \
  -o "$TMP_BIN" \
  "$TMP_SWIFT" \
  "$ROOT/BidProSchedule/Models/TripModels.swift" \
  "$ROOT/BidProSchedule/Services/CrewAccessPDFImportService.swift" \
  "$ROOT/BidProSchedule/Services/ScheduleCacheService.swift" \
  "$ROOT/BidProSchedule/Services/TripBoardSyncService.swift" \
  "$ROOT/BidProSchedule/Services/TripBoardAuthService.swift" \
  "$ROOT/BidProSchedule/Services/KeychainService.swift" \
  "$ROOT/BidProSchedule/Services/NextReportNotificationService.swift" \
  "$ROOT/BidProSchedule/Services/NextReportWindowBuilder.swift" \
  "$ROOT/BidProSchedule/ViewModels/AppViewModel.swift"

"$TMP_BIN" "$ROOT"
