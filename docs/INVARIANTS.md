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

**Implication:** Because the file is the source, a confirmed import that does not survive the following reconcile is a **failed** import, not a partially successful one. `confirmPendingImport` verifies that the JSON it wrote is still readable and that the reconciled Timeline contains the trip and all of its legs; on failure it rolls the JSON, `crewAccessSchedules`, `schedules` and the cache back to their pre-import values and reports the import as failed. A Timeline that lost both the old and the new trip must never be cached or uploaded.

**Implication:** A commit may not destroy any file before verification has passed. Stale same-trip JSONs are removed *before* the reconcile, so they are moved to a hidden stash rather than deleted, restored on every failure path, and discarded only after verification succeeds. Deleting them outright made the rollback partial — it restored the newly written file but not the superseded ones, which is itself the "no source for this trip" state.

**Enforced by:** Init Task in `AppViewModel` calls `fetchCrewAccessImportFilesIfNeeded` before `applyCrewAccessRetentionPolicy`. `AppViewModel.verifyCrewAccessImportCommit` and `restoreCrewAccessStateAfterFailedImport`. Tests: `CrewAccessInProgressTripReimportTests`.

---

## INV-007: CloudKit Sync Is Local-Wins on Conflict

When fetching a remote `TDHDeviceScheduleSnapshot`, if any local `crewAccessSchedules.updatedAt` is newer than the snapshot's `updatedAt`, the remote is rejected. This prevents a stale remote from rolling back a successful local import that has not yet uploaded.

The same local-wins rule applies to the *file* layer, where "local wins" is expressed as a transaction rather than a timestamp comparison — a file has no schedule `updatedAt` to compare. From the local JSON commit in `confirmPendingImport` until that generation is uploaded to CloudKit, an **Import transaction** is open. While it is open, foreground and startup CrewAccess sync do not fetch records, apply tombstones or reconcile; the request is coalesced and replayed exactly once after the transaction closes. Without this, a sync landing mid-import applies the pre-import record set to a post-import local directory and reconcile rebuilds a Timeline without the trip that was just confirmed.

Upload order inside the transaction is source JSON first, schedule snapshot second, so every intermediate state another device can observe is one it can fully rebuild from files (INV-006). A snapshot is never uploaded when the rebuilt `crewAccessSchedules` is empty.

**Enforced by:** `AppViewModel.fetchDeviceScheduleIfNeeded` "Gate 3 (local-wins)"; `AppViewModel.beginCrewAccessImportTransaction` / `endCrewAccessImportTransaction` with the guards at the top of `syncCrewAccessDeviceData` and `fetchCrewAccessImportFilesIfNeeded`. Tests: `CrewAccessInProgressTripReimportTests`.

---

## INV-008: Cross-Device Deletes Use Tombstones

Deleting a CrewAccess import file MUST set the corresponding CloudKit record's `deletedAt` field rather than delete the record outright. On fetch, tombstoned records cause the local file to be removed.

**Why:** A device that was offline during the delete must not "resurrect" the file by re-uploading it. Tombstones converge across devices regardless of connection order.

**Exactly one exception.** A payload generation the user explicitly confirmed on *this* device, via `confirmPendingImport`, is not deleted by a remote tombstone and is republished so CloudKit converges on it. This is required because a re-import of a trip that changed in progress reuses the same file name, so a tombstone describing the *replaced* generation would otherwise delete the *replacing* one and empty the Timeline (INV-006).

The exception is scoped by canonical payload fingerprint, not by trip key or file name, so it can only ever protect the one generation that was confirmed here — `generatedAt` is re-stamped on every import, so the deleted generation never matches. It is armed only by `recordExplicitCrewAccessReimport` and retired as soon as a live remote record carries the same fingerprint. Automatic sync, launch recovery and local file scans must never arm it: a device that merely holds the file still honours the tombstone.

**Enforced by:** `CrewAccessImportCloudKitService.tombstoneImportFile`, `AppViewModel.fetchCrewAccessImportFilesIfNeeded` (handles `deletedAt != nil` by removing local file), `AppViewModel.isConfirmedCrewAccessImportGeneration`. Tests: `CrewAccessDeletionOutboxTests`, `CrewAccessInProgressTripReimportTests`.

---

## INV-009: Calendar Days Are UTC-Indexed

The Bid Period grid is indexed by UTC calendar dates: `calendarDays[0]` = BP start UTC midnight, `calendarDays[1]` = +1 day, etc. The day a trip occupies is determined by `floor((utcDate - bpStartUTC) / 86400)`. The display timezone parameter is retained for API compatibility but is not used for day indexing.

**Why:** Local-timezone day-index math produced 1-day shifts for UTC- timezones (ANC at March 22 00:00 UTC = March 21 16:00 AKDT, whose `startOfDay` is March 21 — wrong cell).

**Enforced by:** `CalendarSupport.resolveDayIndex` (UTC arithmetic, no `startOfDay` in local TZ).

---

## INV-010: Calendar Layer Boundaries Are Strict

The iPad Calendar is layered. Operational content renders in the Operational lane. Bid and Personal content render in the lower stack. Manual Operational Events MUST NOT enter the Bid/Personal stack. Personal Events MUST NOT render as Operational bars.

Priority is: Operational > Bid > Personal.

If Bid and Personal events share a day, Bid is the representative stack item and Personal contributes to the overflow count. Personal-only days may show a Personal representative.

**Why:** Manual events extend the Time Engine. Mixing layers makes the calendar unreadable and breaks future fatigue/reserve logic.

**Enforced by:** `CalendarLayerRegressionHardeningTests` and `docs/MANUAL_EVENTS_LAYER_ARCHITECTURE.md`.

---

## INV-011: Timeline Is Crew Duty Chronology

Timeline is not flight-only. It includes imported Trips/Flights/DH and Manual Operational Events (`RSV`, `LCO`, `HOT`, `RCID`, `CQ`). It excludes Bid Layer and Personal Layer events.

**Why:** Pilots need one chronological view of crew duty. Administrative and personal context must not dilute that duty chronology.

**Enforced by:** `TimelineChronologySupportTests`, `CalendarLayerRegressionHardeningTests`, and `docs/MANUAL_EVENTS_LAYER_ARCHITECTURE.md`.
