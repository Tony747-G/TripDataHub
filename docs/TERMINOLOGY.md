# Terminology

Names that have repeatedly caused bugs. When you write code that touches any of these, decide explicitly which one you mean.

---

## `crewAccessSchedules` (`AppViewModel.crewAccessSchedules: [PayPeriodSchedule]`)

- **Meaning:** Pay-period schedules whose legs originated from a CrewAccess PDF import.
- **Source of truth:** Rebuildable from local JSON files in `Documents/CrewAccessImports/` via `reconcileCrewAccessSchedulesWithImportFiles`. Synced across devices via `TDHDeviceScheduleSnapshot` (parsed form) AND `TDHCrewAccessImportFile` (raw JSON).
- **Used by:** Timeline rendering, BP/PP grouping, LogTen export, CloudKit upload (device snapshot).
- **Common mistakes:**
  - Confusing it with `schedules` (the merged display list — see below).
  - Wiping it on iPad startup before fetching import files from CloudKit (would lose all data because reconcile rebuilds from empty local files).

---

## `bidproSchedules` (`AppViewModel.bidproSchedules: [PayPeriodSchedule]`)

- **Meaning:** Pay-period schedules originating from BidPro web sync (TripBoardSyncService).
- **Source of truth:** Cached from web responses; supplemental to `crewAccessSchedules`.
- **Used by:** iPad calendar (as `supplemental` argument to `mergedCalendarTrips`), merged display.
- **Common mistakes:**
  - Passing `viewModel.schedules` instead of `viewModel.bidproSchedules` to `mergedCalendarTrips` (causes double-counting because `schedules` already contains crewAccess data).

---

## `schedules` (`AppViewModel.schedules: [PayPeriodSchedule]`)

- **Meaning:** **Merged** display/runtime list = `mergeAndSortSchedules(crew: crewAccessSchedules, bidpro: bidproSchedules)`.
- **Source of truth:** Derived. Recomputed whenever `crewAccessSchedules` or `bidproSchedules` change.
- **Used by:** Generic Timeline views, countdown engine, friend-match logic.
- **Common mistakes:**
  - Treating it as a primary source. It is a view on top of the two arrays above.
  - Passing it as `supplemental` to `mergedCalendarTrips` — doc on that function explicitly forbids this (causes duplicate trips on the iPad calendar).

---

## `CrewAccess Imports (Files)`

- **Meaning:** The on-disk JSON files in `<Documents>/CrewAccessImports/{yyyy-MM-dd}_{tripId}.json`. Surfaced to users in Settings → CrewAccess Imports. File order is **ascending by trip date** (oldest first) on both iOS and iPad.
- **Source of truth:** The local files themselves. Synced across devices via `TDHCrewAccessImportFile` (CloudKit), with tombstones for deletion.
- **Used by:** Settings UI, retention policy, `reconcileCrewAccessSchedulesWithImportFiles`, LogTen export hotel enrichment.
- **Common mistakes:**
  - Assuming `crewAccessSchedules` and Files are 1:1 in real time — they converge after reconcile, but in between (e.g. just after CloudKit fetch) they can briefly diverge.

---

## `TDHDeviceScheduleSnapshot`

- **Meaning:** CloudKit record syncing the user's parsed schedules between their own iPhone and iPad. One per user, keyed by GEMS ID.
- **Source of truth:** The owning user's most-recent device. See `INV-007` (local-wins on conflict).
- **Used by:** `DeviceScheduleCloudKitService`. Upload: after every successful import or delete. Fetch: app foreground, iPad workspace task, init.
- **Common mistakes:**
  - Confusing with `TDHCrewAccessImportFile` (which syncs the raw source files, not the parsed schedule). Both exist; both are needed. See `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`.

---

## `TDHCrewAccessImportFile`

- **Meaning:** CloudKit record syncing one CrewAccess import JSON file across the user's devices. One per imported trip.
- **Source of truth:** The local JSON file from the device that imported it.
- **Used by:** `CrewAccessImportCloudKitService`. Upload: after `confirmPendingImport`. Fetch: app foreground, iPad workspace task, init (before reconcile). Tombstone: after Settings file delete.
- **Common mistakes:**
  - Forgetting to tombstone on delete — would cause the file to be re-fetched and "resurrected" on the deleting device.

---

## `TDHSharedSchedule`

- **Meaning:** CloudKit record exposing a user's schedule to their accepted friends.
- **Source of truth:** Owner's `crewAccessSchedules` (uploaded as `schedulesData` JSON).
- **Used by:** `FriendScheduleCloudKitService`, Friends Timeline.

---

## `TripScheduleSnapshot`

- **Meaning:** CloudKit record format consumed by the web Timeline card. Encoded by `TripScheduleSnapshotEncoder`.
- **Source of truth:** Owner's CrewAccess trips.
- **Used by:** Web read-only timeline; not the iOS app's own Timeline.
- **Common mistakes:**
  - Confusing this with `TDHSharedSchedule` (friends sync) — they are different record types with different consumers.

---

## "Timeline"

The user's own Crew Duty Chronology. Driven by imported schedule data plus Manual Operational Events. iOS shows it in a tab; iPad shows it in the left sidebar of the operational workspace. Timeline includes Trips, Flights, imported DH, and Manual Operational Events. Timeline excludes Bid Layer and Personal Layer events.

## "Friends Timeline"

A read-only view of an accepted friend's schedule, populated from `TDHSharedSchedule`. Renders with the SAME components as Timeline (see `INV-005`).

## "Domicile"

The pilot's home base. Determines LDT for BP/PP membership and BP grid timezone. Currently supported: `ANC`, `SDF`, `SDFZ` (treated as SDF), `ONT`, `MIA`. Default: `ANC`. See `DomicileSupport.swift` and `docs/BID_PERIODS.md`.

## "LDT"

Local Domicile Time. The wall-clock time at the pilot's home base. Used for the 03:00 day boundary that defines BP/PP membership.

## "Crew Base"

The user-selected base used for Manual Operational Event time rules. Supported values: `ANC`, `SDF`, `SDFZ`, `ONT`, `MIA`. Default: `ANC`. Crew Base affects new manual event creation and must not silently recalculate existing events.

## "Manual Operational Event"

A user-created duty event such as `RSV-A`, `RSV-B`, `RSV-C`, `RSV-D`, `LCO`, `HOT`, `RCID`, `CQ12`, or `CQ6`. It belongs to the Operational Layer and Timeline. It must not appear in the Bid/Personal stack.

## "Manual Personal Event"

A user-created Personal Layer event such as `Commute`, `Medical`, `Appointment`, or `Other`. It belongs in the calendar's lower Bid/Personal stack area. It must not appear in Timeline or render as a Trip Bar.

## "BP" — Bid Period

A 56-day operational period (occasionally 28 days, e.g. `BP26-07`). See `docs/BID_PERIODS.md`.

## "PP" — Pay Period

A 28-day operational sub-period of a BP. Each non-special BP contains exactly two PPs. See `docs/BID_PERIODS.md`.
