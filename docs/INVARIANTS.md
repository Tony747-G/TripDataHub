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

**Enforced by:** Reviewing equivalent iOS/iPad entry points before marking work complete. Known paired surfaces include `TimelineTabView.swift` / `Views/iPad/iPadTimelineSidebarView.swift`, `FriendsTabView.swift` / `Views/iPad/iPadOperationalWorkspaceView.swift`, and shared Settings/Import flows through `SettingsTabView.swift`, `BrowserTabView.swift`, and `ImportPreviewView.swift`. Timeline block/connection rows use the shared structured `BlockConnectionDisplay` and `BlockConnectionDisplayView`; T-15 verifies the same fixed two-line component at iPhone, iPhone Pro Max, and iPad content widths.

---

## INV-006: CrewAccess Import JSON Is the Recoverable Source

The local JSON file in `Documents/CrewAccessImports/{date}_{tripId}.json` is the source of truth for an imported trip. Derived state (`crewAccessSchedules`, `schedules`) can be rebuilt from these files via `reconcileCrewAccessSchedulesWithImportFiles`. The reverse is not true.

**Why:** Allows retention policies, deletes, and cross-device file sync to operate on a single canonical artifact.

**Implication:** If `crewAccessSchedules` is non-empty but the local files directory is empty (e.g. fresh iPad with cloud-synced schedules but no fetched files), running reconcile would wipe `crewAccessSchedules`. Fetch import files from CloudKit BEFORE reconciling on startup.

**Implication:** Because the file is the source, a confirmed import that does not survive the following reconcile is a **failed** import, not a partially successful one. `confirmPendingImport` verifies that the JSON it wrote is still readable and that the reconciled Timeline contains the trip and all of its legs; on failure it rolls the JSON, `crewAccessSchedules`, `schedules` and the cache back to their pre-import values and reports the import as failed. A Timeline that lost both the old and the new trip must never be cached or uploaded.

**Implication:** A commit may not destroy any file before verification has passed. Stale same-trip JSONs are removed *before* the reconcile, so they are moved to a hidden stash rather than deleted, restored on every failure path, and discarded only after verification succeeds. Deleting them outright made the rollback partial — it restored the newly written file but not the superseded ones, which is itself the "no source for this trip" state.

**Implication:** Time-overlap replacement cleanup is addressed only by immutable artifacts captured before the first write: exact old schedule IDs, Bid Period + normalized Trip ID keys, and JSON file URLs. Cleanup MUST NOT re-resolve targets from post-merge schedules by pairing or broad overlap. The incoming schedule ID, trip key, and final JSON URL are always protected. Exact old files are stashed, the directory is reconciled, and both "new trip present" and "old schedule absent" are verified before the stash is discarded or CloudKit tombstones are published.

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

---

## INV-012: CrewAccess Flight History Is Leg-Scoped and Source-Persisted

For each CrewAccess leg, Scheduled versus Actual is classified independently for departure and arrival by comparing the PDF's own `Created (UTC)` instant with that PDF's corresponding endpoint instant. The rule is exact and has no tolerance band:

- `Created < endpoint` → Scheduled observation
- `Created >= endpoint` → Actual observation

A pre-endpoint observation updates the current Scheduled value while preserving the Original Scheduled value; a post-endpoint observation updates Actual and MUST NOT overwrite Scheduled.

The canonical CrewAccess JSON stores the stable leg identity, Original/Current Scheduled values, Actual values, their observation timestamps, aircraft type, block time, and manual aircraft registration. Re-import, reconcile, relaunch, and CloudKit restoration rebuild `TripLeg` from that source without dropping the history or registration.

**`nil` means unknown.** No field is ever back-filled from a neighbouring field. `originalSTDUTC == nil` means no original schedule was observed — not that the original equals the current — and a missing Scheduled value is never synthesized from an Actual one. `TripLeg.init` and the synthesized `Codable` conformance apply identical semantics, so a decoded leg equals the leg it was encoded from; a normalization in one and not the other would break `Equatable`-based change detection.

**Two time resolutions, deliberately different.** Conflating them is a defect:

| Question | Ordering | Accessor |
| --- | --- | --- |
| What happened / what to display | Actual → Current Scheduled → Original Scheduled | `TripLeg.depUTC` / `arrUTC` |
| Identity, planning, Bid Period, report time | Current Scheduled → Original Scheduled | `TripLeg.plannedDepartureUTC` / `plannedArrivalUTC` |

An Actual time MUST NOT move a trip across a Bid Period identity boundary, re-key a trip for deletion/tombstone/retention purposes, reorder a trip's legs, or shift a report time. Those are properties of the schedule.

**Derived legs are copy-and-mutate.** Any transform producing a modified `TripLeg` copies the existing value and assigns the changed fields. Hand-written memberwise reconstruction is prohibited: it silently drops whatever the author forgets, which has already erased the full history block and the manual registration on every app launch via the UTC backfill.

Timeline remains compact: Original Scheduled is the normal state, Revised Scheduled is amber **while the leg is still active or future**, and completed or past is gray. Completion outranks revision — a leg that was revised and has since been flown is gray, not amber. A leg with only an ATD is airborne, not completed. Detailed history and manual registration editing belong in the flight detail sheet, not extra Timeline labels.

**Enforced by:** `CrewAccessLegHistoryTests` (merge, identity ladder, model guarantees), `TimelineFlightVisualStateTests` (the full colour matrix), `CrewAccessParserRegressionTests` (classification through the production parser against `sample_trip/crewaccess_classification_matrix.pdf` and `crewaccess_arrival_boundary.pdf`, plus golden JSON that pins `stdUtc`/`staUtc`/`atdUtc`/`ataUtc`), `AppViewModelDeviceSyncTests.test_scheduleWideTransformsPreserveLegHistoryAndRegistration`, and the existing `CrewAccessInProgressTripReimportTests` transaction regressions.

---

## INV-013: Real-Time Operational Countdown Uses STD, Report Time, and Now Only

**Rule:** Real-time countdown state, current-leg selection, status descriptors, boundary scheduling, and Activity lifecycle decisions take only required `plannedDepartureUTC`, optional trip-level `reportTimeUTC`, and `nowUTC`. All duration math is an absolute `Date` difference. `plannedArrivalUTC` may be carried only as route display metadata. STA, ATD, ATA, `depUTC`, and `arrUTC` MUST NOT drive operational state or lifecycle.

If a required planned departure or presentation timezone cannot be resolved, no operational presentation is created for that leg. The leg is excluded from current-leg selection, the reason is recorded through `SyncDiagnosticsLog`, and selection continues. There is no `.unknown` operational state and no default timestamp is synthesized. Missing or invalid Actual data does not exclude a leg whose planned-departure inputs are valid.

**Why:** CrewAccess Actual information is not a reliable real-time source. INV-012 deliberately retains Actual values for history and display, but feeding them into operational state makes the live presentation depend on data normally imported only after the trip. STA is likewise a planned route timestamp, not evidence of arrival.

**Forbidden:** Accepting ATD, ATA, or STA in the operational evaluator signature; reading `depUTC` / `arrUTC` in the operational path; using planned arrival as a state, selection, lifecycle, or status anchor; using device-local wall-clock math; backfilling a missing planned departure or timezone; excluding a leg only because Actual data is invalid; adding an `.unknown` state or operational error banner.

**Enforced by:** the restricted `FlightOperationalState` signature, the single operational-state builder, reason-coded `SyncDiagnosticsLog`, and parity tests proving that ATD/ATA-only changes do not alter operational output. Tests: revised T-1, T-2, T-3, T-6, T-11, T-16, T-17, and T-22.

**See also:** INV-001, INV-002, INV-012, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-014: Time Passage Reports a Schedule Boundary, Not an Actual Event

**Rule:** Time passage alone MUST NOT produce `Delayed`, `Departed`, `In flight`, `Arriving`, `Arrived`, or `Completed`. From STD through elapsed minute 60 the product may report only the schedule fact `.departureTimePassed` with the prefix `Departure time passed`. At STD+61 the leg becomes `.expired` and produces no operational countdown.

**Why:** A passed STD is known from the schedule; what the aircraft actually did is not. `Departure time passed` deliberately describes the former and makes no Actual claim. STA passage is not used for real-time operational presentation.

**Forbidden:** Treating `.departureTimePassed` as proof of departure; mapping STD or STA passage to an Actual event; using a future leg, connection, location, ATD, ATA, or elapsed schedule time to infer a real-time aircraft state; retaining `Delayed`, `Arriving in`, `Scheduled Arrival Time Passed`, or schedule-derived `Completed` copy on any operational surface.

**Enforced by:** the four-state evaluator, shared semantic status descriptor, current-leg selector, and STD+61 lifecycle boundary. Tests: revised T-6, T-10 through T-12, T-17, T-20, and T-21.

**See also:** `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-015: Derived Operational Presentation Has One Builder and Two Explicit Refresh Modes

**Rule:** Live Activity, Dynamic Island, Home Screen Widget snapshot, notification scheduling, Timeline operational presentation, current-leg cache, and launch reconstruction derive from one operational-state builder output. Normal operation uses explicit `reconcile` semantics: update an Activity while the current leg remains the same, and end/create only when the current leg changes or disappears. A Trip Revision or Replacement alone uses explicit `destructiveRebuild` semantics: cancel old derived artifacts, end all old Activities, invalidate snapshots/caches, persist the revision, then rebuild.

**Why:** Independent derivation paths drift and leave obsolete operational information alive. Conversely, rebuilding every normal refresh consumes ActivityKit request budget and causes visible churn. Replacement and ordinary state progression have different lifecycle requirements and must remain distinct.

**Forbidden:** Surface-specific state builders; notification and Activity state computed independently; coordinator-side guessing of refresh mode; unconditional Activity end/request during launch, scene activation, periodic refresh, or same-leg state transitions; patching an old Activity through a Trip Replacement.

**Enforced by:** the single operational-state builder and shared structured countdown presentation; caller-selected `LiveActivityRefreshMode`; a coordinator-owned, one-time initial Activity population barrier shared by every refresh entry point; boundary-driven report/STD/STD+61 evaluation; and the replacement-only, timeout-bounded destructive invalidation seam. Tests: T-4 through T-8, revised T-16, T-18, T-19, and T-22.

**See also:** INV-006, INV-007, INV-008, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-016: Presentation Windows Do Not Define Operational State

**Rule:** T-12h, T-6h, and other surface visibility windows belong only to Presentation Policy. They determine whether and where a valid operational state is shown; they MUST NOT participate in `FlightOperationalState` evaluation.

**Why:** A leg's operational meaning does not change because a Widget or Live Activity has entered its display window. Combining the two concepts caused STD-relative UI phases to masquerade as flight state.

**Forbidden:** A state case whose meaning is a Widget/Live Activity window; using a visibility lead/tail constant to decide `.departureTimePassed` or `.expired`; adding `.preTrip` to represent “not visible yet.”

**Enforced by:** separate `FlightOperationalState` and Presentation Policy types, with no presentation-window input in the operational-state evaluator signature. Test: T-23 is the dedicated enforcing regression; it requires the same valid operational state outside the T-12h presentation window and regardless of surface visibility.

**See also:** `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-017: Actual Events Are History-Only for Real-Time Countdown

**Rule:** ATD and ATA remain persisted, leg-scoped history under INV-012, but they MUST NOT affect real-time operational state, current-leg selection, status text, boundary scheduling, snapshot stale dates, or Activity update/end/request decisions. Two schedules differing only in ATD or ATA produce identical operational output.

**Why:** CrewAccess Actual data is commonly imported after trip completion and is not a contracted real-time source. Allowing it to affect live countdown would make normal operation depend on unavailable evidence while leaving surfaces vulnerable to revision-time changes.

**Forbidden:** `.inFlight` or `.completed` cases in the real-time state enum; operational evaluator parameters for ATD or ATA; converting an Actual observation into live `Arriving`, `Arrived`, or `Completed` copy; rejecting a planned-departure countdown because an Actual timestamp is missing or malformed.

**Enforced by:** a type signature with no Actual inputs, operational conversion that does not parse Actual fields, source guards for retired state/copy, and ATD/ATA parity regression tests. Tests: revised T-11, T-17, T-20, T-21, and T-22.

**See also:** INV-012, INV-013, INV-014, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-018: STD+61 Is the Exact Operational Expiration Boundary

**Rule:** Operational state is evaluated in this exact order: `now >= STD+61min` → `.expired`; otherwise `now >= STD` → `.departureTimePassed`; otherwise a non-nil report time with `now < reportTime` → `.preReport`; otherwise → `.preDeparture`. Equality belongs to the later state. STD is elapsed minute 0, the entire interval from STD+60:00 through STD+60:59 displays elapsed minute 60, and STD+61:00 is non-presenting.

Current-leg selection gives `.departureTimePassed` legs priority through minute 60, choosing the latest STD when multiple such legs exist. Only at STD+61 is that leg excluded and selection allowed to advance to the earliest valid future leg. Short turns may therefore have a shortened or absent next-leg `Dep in` interval; this is accepted product behavior.

**Why:** The order preserves the exact +60/+61 contract and prevents a future leg from displacing the selected passed leg early. It also gives lifecycle scheduling one deterministic terminal boundary without claiming an Actual event.

**Forbidden:** Using strict `>` at STD or STD+61; expiring at STD+60; allowing a future leg to outrank a non-expired `.departureTimePassed` leg; using STA, STA+1h, ATD, or ATA as an operational boundary; polling every minute to drive state or Activity updates.

**Enforced by:** the pure state evaluator, latest-STD passed-leg selector, report/STD/STD+61 boundary scheduler, OS-driven localized timer rendering, and lifecycle end/update handling. Tests: revised T-6, T-10, T-12, T-18, T-20, and T-21.

**See also:** INV-014, INV-017, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-019: A Surface That Overrides Its Background Must Declare Its Foreground

**Rule:** A surface that overrides its background MUST declare its foreground at the same ownership boundary. `.primary` and `.secondary` resolve against the system appearance, not against a background or tint supplied by the view. Background and foreground declarations are a pair; changing only one is forbidden.

**Why:** An implicit semantic foreground can become unreadable when the fixed background and system appearance disagree. On iOS 18.6 in Light appearance, the Lock Screen Live Activity flight and route text rendered dark on a black background; the same contract defect also existed in the active Home Screen Widget. iOS 26.5 happened to keep the Live Activity text visible, so one OS version could not expose the regression reliably.

**Forbidden:** Adding or changing a fixed custom background without declaring the matching foreground environment or explicit foreground at the same surface; placing surface color policy in `FlightCountdownExpandedLayoutView`; relying on `activitySystemActionForegroundColor` to color Live Activity content.

**Enforced by:** adjacent foreground/background declarations on the Lock Screen / Dynamic Island expanded Live Activity surface and the active Home Screen Widget surface. T-51S asserts both sides of each source-level pair; Light and Dark rendering remains device acceptance.
