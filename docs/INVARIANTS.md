# Invariants

Rules that must not silently change. If you violate one, add a new ADR and update this file. If a test for an invariant does not exist, add one when you touch the related code.

---

## INV-001: UTC Source of Truth

All internal calculations (sorting, deduplication, day-index resolution, BP/PP membership, fingerprinting) MUST use UTC. Local time is for **rendering** and for interpreting **domain boundaries** (e.g. 03:00 LDT). Any persisted timestamp is UTC.

**Why:** Multiple devices in different zones must converge on the same data. Local-time math has caused day-shift bugs (UTC- timezones produced dayIndex off-by-one for week-crossing trips).

**Enforced by:** `CalendarSupport.resolveDayIndex` (UTC arithmetic), `LegConnectionTextBuilder.parseUTC`, `TripScheduleSnapshotEncoder` (UTC fields).

**See also:** `docs/ADR/ADR-002-utc-source-of-truth.md`.

---

## INV-002: Timezone Conversion Is Explicit

Timezone conversion happens at exactly two boundaries:
1. Rendering — converting a UTC `Date` to a local-time string for display.
2. Domain interpretation — converting a UTC `Date` to "which 03:00-LDT day does this belong to?" for BP/PP membership.

It MUST NOT happen silently inside arithmetic, sorting, or comparison.

**Why:** Implicit conversion using `Calendar.current` or `TimeZone.current` produces device-local results that differ between devices.

**Enforced by:** Every formatter sets an explicit `timeZone`; every `Calendar` used for math sets an explicit `timeZone` or is the UTC `calendarEngineUTCCalendar`.

---

## INV-003: BP/PP Membership Uses 03:00 LDT Boundary

A trip belongs to a Pay Period or Bid Period iff its **departure time** falls within `[BP.start 03:00 LDT, BP.end 03:00 LDT)` where LDT is the pilot's domicile time. The interval is half-open.

**Why:** Operational period boundaries are defined by domicile-local 03:00, not by UTC midnight.

**Enforced by:** `BidPeriodService.bidPeriod(for:domicile:)`, `bidPeriodBoundaryUTCDate` (always uses `"\(date) 03:00"` in domicile calendar).

**See also:** `docs/BID_PERIODS.md`.

---

## INV-004: Domicile Controls LDT

LDT (Local Domicile Time) is determined entirely by the verified pilot's `domicile` field. Code MUST go through `DomicileSupport.timeZone(for:)`. SDFZ is treated as SDF (Louisville). Adding a new domicile requires updating `DomicileSupport.swift` AND `docs/BID_PERIODS.md`.

**Enforced by:** `DomicileSupport.swift`. Tests: `BidPeriodServiceTests.test_bidPeriod_usesDomicile0300Boundary`.

---

## INV-005: Equivalent iOS and iPad Surfaces Stay in Sync

When a behavior, workflow, or user-facing display is changed on iOS, the equivalent iPadOS surface MUST be identified, reviewed, and updated to match unless the product requirement explicitly says the platforms should differ. The reverse is also true: iPadOS fixes require checking and updating the iOS equivalent.

Shared components should be used where practical. The same `TimelineFlightRow` and `TimelineLayoverCard` views are used for the user's own Timeline AND for shared/friend timelines. Visual divergence between equivalent Timeline/Friends/Settings/Import surfaces is a bug, not a feature.

**Why:** Repeated regressions where one path got a polish update and the other didn't (e.g. iPad layover card was missing the date label; iOS Timeline/Friends changes missed iPad-specific sidebar/sheet implementations).

**Enforced by:** Reviewing equivalent iOS/iPad entry points before marking work complete. Known paired surfaces include `TimelineTabView.swift` / `Views/iPad/iPadTimelineSidebarView.swift`, `FriendsTabView.swift` / `Views/iPad/iPadOperationalWorkspaceView.swift`, and shared Settings/Import flows through `SettingsTabView.swift`, `BrowserTabView.swift`, and `ImportPreviewView.swift`.

---

## INV-006: CrewAccess Import JSON Is the Recoverable Source

The local JSON file in `Documents/CrewAccessImports/{date}_{tripId}.json` is the source of truth for an imported trip. Derived state (`crewAccessSchedules`, `schedules`) can be rebuilt from these files via `reconcileCrewAccessSchedulesWithImportFiles`. The reverse is not true.

**Why:** Allows retention policies, deletes, and cross-device file sync to operate on a single canonical artifact.

**Implication:** If `crewAccessSchedules` is non-empty but the local files directory is empty (e.g. fresh iPad with cloud-synced schedules but no fetched files), running reconcile would wipe `crewAccessSchedules`. Fetch import files from CloudKit BEFORE reconciling on startup.

**Enforced by:** Init Task in `AppViewModel` calls `fetchCrewAccessImportFilesIfNeeded` before `applyCrewAccessRetentionPolicy`.

---

## INV-007: CloudKit Sync Is Local-Wins on Conflict

When fetching a remote `TDHDeviceScheduleSnapshot`, if any local `crewAccessSchedules.updatedAt` is newer than the snapshot's `updatedAt`, the remote is rejected. This prevents a stale remote from rolling back a successful local import that has not yet uploaded.

**Enforced by:** `AppViewModel.fetchDeviceScheduleIfNeeded` "Gate 3 (local-wins)".

---

## INV-008: Cross-Device Deletes Use Tombstones

Deleting a CrewAccess import file MUST set the corresponding CloudKit record's `deletedAt` field rather than delete the record outright. On fetch, tombstoned records cause the local file to be removed.

**Why:** A device that was offline during the delete must not "resurrect" the file by re-uploading it. Tombstones converge across devices regardless of connection order.

**Enforced by:** `CrewAccessImportCloudKitService.tombstoneImportFile`, `AppViewModel.fetchCrewAccessImportFilesIfNeeded` (handles `deletedAt != nil` by removing local file).

---

## INV-009: Calendar Days Are UTC-Indexed

The Bid Period grid is indexed by UTC calendar dates: `calendarDays[0]` = BP start UTC midnight, `calendarDays[1]` = +1 day, etc. The day a trip occupies is determined by `floor((utcDate - bpStartUTC) / 86400)`. The display timezone parameter is retained for API compatibility but is not used for day indexing.

**Why:** Local-timezone day-index math produced 1-day shifts for UTC- timezones (ANC at March 22 00:00 UTC = March 21 16:00 AKDT, whose `startOfDay` is March 21 — wrong cell).

**Enforced by:** `CalendarSupport.resolveDayIndex` (UTC arithmetic, no `startOfDay` in local TZ).
