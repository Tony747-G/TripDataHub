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

The legacy `TDHDeviceScheduleSnapshot` may replace local CrewAccess schedules only when the canonical import-file rebuild produced an empty `crewAccessSchedules`. A non-empty Timeline rebuilt from local import files always wins; snapshot and local-file timestamps are deliberately not compared because they describe different events.

The same local-wins rule applies to the *file* layer, where "local wins" is expressed as a transaction rather than a timestamp comparison — a file has no schedule `updatedAt` to compare. From the local JSON commit in `confirmPendingImport` until that generation is uploaded to CloudKit, an **Import transaction** is open. While it is open, foreground and startup CrewAccess sync do not fetch records, apply tombstones or reconcile; the request is coalesced and replayed exactly once after the transaction closes. Without this, a sync landing mid-import applies the pre-import record set to a post-import local directory and reconcile rebuilds a Timeline without the trip that was just confirmed.

Upload order inside the transaction is source JSON first, schedule snapshot second, so every intermediate state another device can observe is one it can fully rebuild from files (INV-006). A snapshot is never uploaded when the rebuilt `crewAccessSchedules` is empty.

**Enforced by:** the non-empty `crewAccessSchedules` precondition in `AppViewModel.fetchLegacyDeviceScheduleFallbackIfNeeded`; `AppViewModel.beginCrewAccessImportTransaction` / `endCrewAccessImportTransaction` with the guards at the top of `syncCrewAccessDeviceData` and `fetchCrewAccessImportFilesIfNeeded`. Tests: `AppViewModelDeviceSyncTests`, `CrewAccessInProgressTripReimportTests`.

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

## INV-013: Home Widget State Uses Scheduled Report, STD, and Final STA+30

**Rule:** The Home Screen Widget answers one question from one shared domain result: the next Trip report before report time, or the next scheduled flight during an active Trip. Selection and boundary scheduling use absolute `Date` comparisons against Trip report time, every flight STD, and `final planned arrival + 30 minutes`. `plannedArrivalUTC` is otherwise display metadata and the final Trip release anchor. ATD, ATA, `depUTC`, and `arrUTC` MUST NOT drive Widget state.

If a required planned endpoint or presentation timezone cannot be resolved, that leg is excluded from the Widget projection and the reason is recorded through `SyncDiagnosticsLog`. Trip completion is independent of renderability: after at least one leg projects, the release boundary uses the last source flight in canonical sequence whose planned arrival parses, even when that source leg cannot project because its airport timezone is unresolved. If later source flights have no parseable planned arrival, release falls back in source order to the last parseable source arrival, then to the last valid projected arrival only when necessary. A Trip with no projected legs is excluded. A decoded/input Trip with a nil release boundary is ineligible for Widget selection; it MUST NOT remain active indefinitely. No default timestamp, device timezone, Actual value, or release time is synthesized.

**Why:** CrewAccess Actual information is historical and not a contracted realtime feed. Scheduled boundaries are deterministic and available when the schedule is imported; the final STA+30 rule matches the established active-Trip suppression boundary.

**Forbidden:** Making Trip completion depend on timezone projection when a source planned arrival is valid; choosing completion by maximum timestamp instead of canonical source sequence; treating nil release as active forever; using ATD or ATA for Widget transition; comparing formatted clock strings; substituting the device timezone; inventing a final release time; treating scheduled time passage as proof of an Actual event.

**Enforced by:** `HomeWidgetScheduleBuilder`, `HomeWidgetDomain`, reason-coded diagnostics, and `HomeWidgetDomainTests` covering report, STD, final-release, timezone, and Actual-independent selection.

**See also:** INV-001, INV-002, INV-012, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-014: Exact STD Selects the Following Scheduled Flight

**Rule:** During an active Trip, the Widget selects the first flight whose `STD > now`. Equality belongs to the transition: at a displayed flight's exact STD, that flight is no longer “next” and the following flight is selected. While the prior flight may be airborne, the Widget continues showing the following scheduled flight. Time passage alone MUST NOT produce `Delayed`, `Departed`, `In flight`, `Arriving`, `Arrived`, or `Completed`.

**Why:** The Widget is an operational look-ahead, not a realtime aircraft-status surface.

**Forbidden:** Keeping a flight selected at `now == STD`; applying the retired STD+61 current-leg rule to the Home Widget; inferring Actual status from STD or STA passage; creating a fake following leg.

**Enforced by:** `HomeWidgetDomain.selection` and exact-boundary tests for every STD.

**See also:** `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-015: Home Widget Has One Schedule Projection and Two Explicit Refresh Modes

**Rule:** The app publishes one compact multi-Trip `HomeWidgetScheduleSnapshot`; `HomeWidgetDomain` is the only Trip/leg selector and is compiled into both the app and Widget extension. Small and Medium consume the same presentation and may differ only in layout/information density. Normal operation uses explicit `reconcile` semantics. A Trip Revision or Replacement alone uses explicit `destructiveRebuild` semantics to clear the old snapshot before publishing the revised generation. Report notifications remain independently owned by `NextReportNotificationService`.

The Timeline Top Next Report Countdown represents the next Trip's report instant rather than current-flight operational state. Its selector and visibility are governed by INV-020 and MUST NOT be fed back into notification or Home Screen Widget lifecycle decisions.

**Why:** Family-specific or process-specific selectors drift at exact boundaries. Replacement and ordinary progression also have different publication requirements.

**Forbidden:** Selecting a Trip or leg in SwiftUI; separate family selectors; coordinator-side guessing of refresh mode; publishing a revised generation without first clearing the prior snapshot during Trip Replacement; coupling notification selection into Widget state.

**Enforced by:** `HomeWidgetScheduleBuilder`, `HomeWidgetDomain`, caller-selected `FlightCountdownRefreshMode`, `FlightCountdownCoordinator.refreshHomeWidget`, and family contract tests.

**See also:** INV-006, INV-007, INV-008, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-016: Home Widget Is Always Operational, Not Window-Gated

**Rule:** Once a valid future or active Trip exists in the published schedule projection, the Widget presents it regardless of distance from STD. The former T-12h through T-6h visibility window is not part of the Home Widget contract.

**Why:** A Widget that answers “what operational event do I need next?” cannot disappear based on an unrelated departure-relative window.

**Forbidden:** Applying `FlightPresentationPolicy.widgetLeadTime` or `widgetEndLeadTime` to the new Widget projection; hiding a valid future report because it is more than 12 hours away; letting a view decide visibility.

**Enforced by:** the absence of a presentation-window input in `HomeWidgetDomain` and a timeline regression beginning 40 hours before report.

**See also:** `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-017: Actual Events Are History-Only for Home Widget State

**Rule:** ATD and ATA remain persisted, leg-scoped history under INV-012, but they MUST NOT affect Home Widget Trip/leg selection, copy, or timeline boundaries. Two schedules differing only in ATD or ATA produce identical Widget projections.

**Why:** CrewAccess Actual data is commonly imported after trip completion and is not a contracted real-time source. Allowing it to affect live countdown would make normal operation depend on unavailable evidence while leaving surfaces vulnerable to revision-time changes.

**Forbidden:** Widget evaluator parameters for ATD or ATA; converting an Actual observation into `Arriving`, `Arrived`, or `Completed` copy; rejecting a valid planned leg because an Actual timestamp is missing or malformed.

**Enforced by:** a Widget projection that parses only planned endpoints, source guards for retired status copy, and scheduled-boundary tests.

**See also:** INV-012, INV-013, INV-014, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-018: Final STD Falls Back Until Final STA+30

**Rule:** If no flight has `STD > now` after the final leg reaches STD, the current Trip remains active until `final planned arrival + 30 minutes`. During this interval the shared presentation has state `.activeTripFinalLeg`, retains the final flight number, route, departure and arrival schedule, exposes no report time, and uses neutral copy `TRIP IN PROGRESS`. Small renders the final leg's departure `(L)`/`(Z)` times only; Medium retains both departure and arrival columns. No fake next leg is created. At release-boundary equality the following future Trip report becomes eligible.

**Why:** Advancing to the next Trip at final STD is premature, while implying an Actual flight status would be unsupported.

**Forbidden:** Showing the following Trip before release; resurrecting the current Trip report; inventing a next leg or release time; labeling the flight departed/in-flight/arrived.

**Enforced by:** `HomeWidgetDomain.selection`, `HomeWidgetDomain.presentation`, pre-release/exact-release tests, and the shared final-leg presentation consumed by every family.

**See also:** INV-014, INV-017, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-019: A Surface That Overrides Its Background Must Declare Its Foreground

**Rule:** A surface that overrides its background MUST declare its foreground at the same ownership boundary. `.primary` and `.secondary` resolve against the system appearance, not against a background or tint supplied by the view. Background and foreground declarations are a pair; changing only one is forbidden.

**Why:** An implicit semantic foreground can become unreadable when the fixed background and system appearance disagree. This contract remains relevant to the active Home Screen Widget.

**Forbidden:** Adding or changing a fixed custom background without declaring the matching foreground environment or explicit foreground at the same surface.

**Enforced by:** adjacent foreground/background declarations on the active Home Screen Widget surface and active test `test_T51S_homeWidgetCustomBackgroundDeclaresMatchingForegroundEnvironment`. Light and Dark rendering remains Widget acceptance.

---

## INV-020: Timeline Top Suppresses the Next Report During an Active Trip

**Rule:** Timeline Top may select the single Trip window with the earliest `reportTimeUTC` strictly greater than `nowUTC` only when no started Trip is still inside its active window. A Trip active window begins at report-time equality and ends at `releaseBoundary = final flight leg planned arrival + 30 minutes`; equality at the release boundary makes the next future Trip eligible. Operating and commercial-deadhead flight legs both count, including a final flight that ends away from domicile. A `GND` row does not count as a flight leg.

The final flight is determined before parsing its arrival. If that leg has no valid planned arrival, no replacement time is inferred: the most recently started unresolved Trip conservatively suppresses the next report until a later Trip itself reaches report time and supersedes it. Any started Trip with a known release boundary still in the future also suppresses the card, including overlapping Trips.

Before the current Trip's report time, its existing three-line countdown remains visible. At report-time equality the entire Top countdown is absent, and it remains absent through `releaseBoundary - 1 second`. Selection is independent of the viewed/selected Trip and Timeline scroll position. Duration is the absolute UTC instant difference; LCL/UTC changes rendering timezone and zone label only.

Timeline visibility MUST NOT cancel, hide, or alter report notifications or the Home Screen Widget snapshot. The Home Widget independently applies the same final-STA+30 active-Trip boundary through `HomeWidgetDomain`, while notifications remain governed by their existing builder and preferences.

**Enforced by:** `TimelineNextReportCountdownBuilder`, the shared iPhone/iPad `TimelineNextReportCountdownView`, and `NextReportWindowBuilderTests` covering report-time and release boundaries, commercial deadhead and foreign endings, overlap, multiple future Trips, missing final arrival, format, timezone, color, and responsibility separation.

**See also:** INV-001, INV-002, INV-005, INV-015, and `docs/ADR/ADR-004-flight-operational-state-model.md`.

---

## INV-021: Flight Countdown Live Activities Are Absent

**Rule:** TripDataHub MUST NOT request, update, or end a Flight Countdown Live Activity. The app exposes no Flight Countdown Lock Screen or Dynamic Island compact, minimal, or expanded configuration. Production sources and Info.plists contain no Flight Countdown ActivityKit runtime or Live Activity capability declaration.

**Why:** The local-only ActivityKit architecture could not guarantee that departure status was no longer user-visible at Scheduled Departure Time +60 minutes. The product requirement was not weakened, and APNs/server/BGTask infrastructure was not added; the feature was removed instead. This is an architecture/product decision, not an iOS bug classification.

**Forbidden:** Restoring `Activity.request`, `activity.update`, `activity.end`, Activity attributes/ContentState, `ActivityConfiguration`, Dynamic Island regions, `staleDate`, `context.isStale`, DateReference, timer-clamp, or lifecycle workarounds for Flight Countdown without a new Product Owner decision and a new architecture contract.

**Enforced by:** the absence of an ActivityKit dependency in production Flight Countdown sources, removal of `NSSupportsLiveActivities`, a snapshot-only coordinator, and the production runtime-path regression guard.

**See also:** `docs/ADR/ADR-004-flight-operational-state-model.md`.
