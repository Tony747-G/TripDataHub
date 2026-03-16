#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$script_dir/.." && pwd)
TMP_SWIFT="$(mktemp /tmp/validate_timezone_regressions.XXXXXX.swift)"
TMP_BIN="$(mktemp /tmp/validate_timezone_regressions.XXXXXX.bin)"
trap 'rm -f "$TMP_SWIFT" "$TMP_BIN"' EXIT

cat > "$TMP_SWIFT" <<'SWIFT'
import Foundation
import UserNotifications

enum TimelineSourceFilter: String {
    case crewAccess
    case tripBoard
}

enum ExternalOpenLaunchGate {
    static func stableKey(for url: URL) -> String { url.absoluteString }
    static func reset() {}
}

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

final class MockCacheService: ScheduleCacheServiceProtocol {
    private let snapshot: ScheduleCacheSnapshotV2
    private(set) var savedSnapshots: [ScheduleCacheSnapshotV2] = []

    init(snapshot: ScheduleCacheSnapshotV2) {
        self.snapshot = snapshot
    }

    func load() -> ScheduleCacheSnapshotV2? { snapshot }

    func save(_ snapshot: ScheduleCacheSnapshotV2) throws {
        savedSnapshots.append(snapshot)
    }

    func clear() {}
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

func parseUTC(_ raw: String) -> Date {
    guard let date = LegConnectionTextBuilder.parseUTC(raw) else {
        fail("cannot parse UTC: \(raw)")
    }
    return date
}

func utcISO(_ date: Date) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = TimeZone(secondsFromGMT: 0)
    return iso.string(from: date)
}

func localToUTCString(localText: String, airport: String, resolver: IATATimeZoneResolving) -> String {
    guard let tzID = resolver.resolve(airport), let tz = TimeZone(identifier: tzID) else {
        fail("missing tz for \(airport)")
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = tz
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    guard let date = formatter.date(from: localText) else {
        fail("cannot parse local text \(localText) for \(airport)")
    }
    return utcISO(date)
}

@main
struct Main {
    static func main() async {
        // Regression 1: NextReportWindowBuilder must sort by UTC, not depLocal text.
        do {
            let anc = TimeZone(identifier: "America/Anchorage")!
            let earlyUTC = "2026-03-04T15:00:00Z"
            let lateUTC = "2026-03-04T17:00:00Z"
            let pairing = "A70878"

            // Intentionally inverted depLocal text ordering to catch lexical-sort regressions.
            let legEarly = TripLeg(
                payPeriod: "CA26-03-A70878",
                pairing: pairing,
                leg: 1,
                flight: "100",
                depAirport: "ANC",
                depLocal: "2026-03-04 09:00",
                arrAirport: "SEA",
                arrLocal: "2026-03-04 12:00",
                depUTC: earlyUTC,
                arrUTC: "2026-03-04T18:00:00Z",
                status: "-",
                block: "3:00"
            )
            let legLate = TripLeg(
                payPeriod: "CA26-03-A70878",
                pairing: pairing,
                leg: 2,
                flight: "101",
                depAirport: "ANC",
                depLocal: "2026-03-04 08:00",
                arrAirport: "ANC",
                arrLocal: "2026-03-04 11:00",
                depUTC: lateUTC,
                arrUTC: "2026-03-04T20:00:00Z",
                status: "-",
                block: "10:00"
            )
            let schedule = PayPeriodSchedule(
                id: "CA26-03-A70878",
                label: "CA26-03-A70878",
                tripCount: 1,
                legCount: 2,
                openTimeCount: 0,
                updatedAt: Date(),
                legs: [legLate, legEarly],
                openTimeTrips: []
            )

            let windows = NextReportWindowBuilder.build(schedules: [schedule], anchorageTimeZone: anc)
            guard let first = windows.first else { fail("no next report windows built") }
            let expectedReport = parseUTC(earlyUTC).addingTimeInterval(-NextReportWindowBuilder.reportLeadTimeSeconds)
            expect(first.pairing == pairing, "unexpected pairing in next report window")
            expect(abs(first.reportTime.timeIntervalSince(expectedReport)) < 1, "next report picked wrong departure anchor (not UTC-first sort)")
        }

        // Regression 2: Backfill must treat CrewAccess depLocal/arrLocal as UTC display text.
        // Regression 3: BidPro local display fallback should still convert local -> UTC.
        do {
            let resolver = IATATimeZoneResolver.shared
            let crewLeg = TripLeg(
                payPeriod: "CA26-03-A70878",
                pairing: "A70878",
                leg: 5,
                flight: "68",
                depAirport: "HNL",
                depLocal: "2026-03-10 21:27",
                arrAirport: "SGN",
                arrLocal: "2026-03-11 02:45",
                depUTC: nil,
                arrUTC: nil,
                status: "-",
                block: "12:18"
            )
            let bidproLeg = TripLeg(
                payPeriod: "BP26-03",
                pairing: "BID123",
                leg: 1,
                flight: "1234",
                depAirport: "ANC",
                depLocal: "2026-03-04 06:57",
                arrAirport: "SDF",
                arrLocal: "2026-03-04 18:32",
                depUTC: nil,
                arrUTC: nil,
                status: "-",
                block: "6:05"
            )

            let cached = ScheduleCacheSnapshotV2(
                crewAccessSchedules: [PayPeriodSchedule(
                    id: "CA26-03-A70878",
                    label: "CA26-03-A70878",
                    tripCount: 1,
                    legCount: 1,
                    openTimeCount: 0,
                    updatedAt: Date(),
                    legs: [crewLeg],
                    openTimeTrips: []
                )],
                bidproSchedules: [PayPeriodSchedule(
                    id: "BP26-03",
                    label: "BP26-03",
                    tripCount: 1,
                    legCount: 1,
                    openTimeCount: 0,
                    updatedAt: Date(),
                    legs: [bidproLeg],
                    openTimeTrips: []
                )],
                lastSyncAt: Date(),
                migratedAt: nil
            )

            let cache = MockCacheService(snapshot: cached)
            let vm = await MainActor.run {
                AppViewModel(
                    syncService: MockSyncService(),
                    authService: MockAuthService(),
                    cacheService: cache,
                    notificationService: MockNotificationService(),
                    crewAccessImportService: CrewAccessPDFImportService(),
                    tzResolver: resolver
                )
            }

            let schedules = await MainActor.run { vm.schedules }
            guard let crewSchedule = schedules.first(where: { $0.id == "CA26-03-A70878" }),
                  let backfilledCrewLeg = crewSchedule.legs.first(where: { $0.pairing == "A70878" }) else {
                fail("missing backfilled CrewAccess leg")
            }
            guard let bidproSchedule = schedules.first(where: { $0.id == "BP26-03" }),
                  let backfilledBidproLeg = bidproSchedule.legs.first(where: { $0.pairing == "BID123" }) else {
                fail("missing backfilled BidPro leg")
            }

            let expectedCrewDepUTC = "2026-03-10T21:27:00Z"
            let expectedCrewArrUTC = "2026-03-11T02:45:00Z"
            expect(backfilledCrewLeg.depUTC == expectedCrewDepUTC, "CrewAccess depUTC backfill should parse UTC display without timezone shift")
            expect(backfilledCrewLeg.arrUTC == expectedCrewArrUTC, "CrewAccess arrUTC backfill should parse UTC display without timezone shift")

            let expectedBidproDepUTC = localToUTCString(localText: "2026-03-04 06:57", airport: "ANC", resolver: resolver)
            let expectedBidproArrUTC = localToUTCString(localText: "2026-03-04 18:32", airport: "SDF", resolver: resolver)
            expect(backfilledBidproLeg.depUTC == expectedBidproDepUTC, "BidPro depUTC backfill should convert local display using airport timezone")
            expect(backfilledBidproLeg.arrUTC == expectedBidproArrUTC, "BidPro arrUTC backfill should convert local display using airport timezone")

            expect(!cache.savedSnapshots.isEmpty, "backfill should persist recovered UTC values")
        }

        print("Timezone regression validation passed.")
    }
}
SWIFT

xcrun swiftc \
  -o "$TMP_BIN" \
  "$TMP_SWIFT" \
  "$ROOT/TripDataHub/Models/TripModels.swift" \
  "$ROOT/TripDataHub/Models/TripLegDisplaySupport.swift" \
  "$ROOT/TripDataHub/Services/CrewAccessPDFImportService.swift" \
  "$ROOT/TripDataHub/Services/IATATimeZoneResolver.swift" \
  "$ROOT/TripDataHub/Services/ScheduleCacheService.swift" \
  "$ROOT/TripDataHub/Services/TripBoardSyncService.swift" \
  "$ROOT/TripDataHub/Services/TripBoardAuthService.swift" \
  "$ROOT/TripDataHub/Services/KeychainService.swift" \
  "$ROOT/TripDataHub/Services/NextReportNotificationService.swift" \
  "$ROOT/TripDataHub/Services/NextReportWindowBuilder.swift" \
  "$ROOT/TripDataHub/ViewModels/AppViewModel.swift"

"$TMP_BIN"
