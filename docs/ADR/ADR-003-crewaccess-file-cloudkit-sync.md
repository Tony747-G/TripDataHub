# ADR-003: Sync CrewAccess Import JSON Files via CloudKit

**Status:** Accepted
**Date:** 2026-05

## Context

CrewAccess PDF imports happen unpredictably on either iOS or iPad — whichever device the pilot used to run Zscaler Print. Build 36 introduced cross-device sync of the **parsed schedule** via `TDHDeviceScheduleSnapshot`, which fixed the Timeline display divergence between devices.

But Settings → CrewAccess Imports (Files) still showed a different list on each device because the underlying JSON files in `Documents/CrewAccessImports/` were local-only. The parsed schedule converged across devices; the source artifacts that produced it did not.

This caused user-visible inconsistencies:
- File counts differed in Settings between iPhone and iPad.
- Re-import / dedup / hotel-enrichment operated on different file sets per device.
- Deletions on one device left the file present on the other.

Two options were considered:
- **Plan A — short-term workaround:** make `reconcileCrewAccessSchedulesWithImportFiles` skip when the local files directory is empty. This would prevent iPad from wiping CloudKit-synced schedules, but Settings would still show empty Files on the receiving device.
- **Plan B — full file sync:** add a CloudKit record type that carries the raw JSON, fetch on startup/foreground, and tombstone on delete.

## Decision

**Adopt Plan B.** Sync the CrewAccess import JSON files themselves via a new CloudKit record type, `TDHCrewAccessImportFile`. After a fetch, restore the JSON files to the local `Documents/CrewAccessImports/` directory; existing reconcile logic then runs unchanged and produces identical `crewAccessSchedules` on every device.

Concretely:
- New service: `CrewAccessImportCloudKitService` with `uploadImportFile`, `fetchImportFiles`, `tombstoneImportFile`.
- Upload after a successful `confirmPendingImport`.
- Fetch on app init (BEFORE `applyCrewAccessRetentionPolicy` — see `INV-006`), on foreground, and on iPad workspace `.task`.
- Delete uses `deletedAt` tombstone semantics; other devices observing `deletedAt != nil` remove the local file (`INV-008`).

## Consequences

- Settings → CrewAccess Imports (Files) converges across devices.
- Timeline can be rebuilt on any device from restored import files.
- File identity is stable (`{date}_{tripId}.json`) and survives across devices, avoiding duplicates.
- Storage cost on CloudKit Public DB grows with the number of imports per user. Trip JSONs are typically < 5 KB so this is acceptable for the Phase 1 user base.
- One more record type to deploy to Production CloudKit before each TestFlight build that adds fields.

## Tradeoffs

- Plan A would have required no new record type, but produced a degraded user experience (empty Files list on the receiving device). Plan B's incremental cost is one service file plus a record type; the user-visible behavior is correct.
- Tombstones rather than physical delete add a small storage overhead but are necessary to prevent offline-device "resurrection" of deleted files.

## Related Code

- `TripDataHub/Services/CrewAccessImportCloudKitService.swift`
- `AppViewModel.fetchCrewAccessImportFilesIfNeeded`
- `AppViewModel.uploadCrewAccessImportFile`
- `AppViewModel.tombstoneCrewAccessImportFiles`
- `AppViewModel.listCrewAccessImportFiles`
- `AppViewModel.deleteCrewAccessImportFiles`
- `docs/CLOUDKIT.md` — record type fields and security role.
- `docs/INVARIANTS.md` — INV-006 (fetch-before-reconcile), INV-008 (tombstones).

## Reconsider When

- CloudKit Public DB storage cost becomes a constraint.
- A more privacy-preserving sync model (Private DB with CKShare) becomes the default.
- File identity needs to incorporate content hashing rather than `{date}_{tripId}` (e.g. if the same trip is imported with edits and we need to merge rather than overwrite).
