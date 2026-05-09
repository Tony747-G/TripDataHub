# ADR-001: Use CloudKit Public Database for Phase 1

**Status:** Accepted
**Date:** 2026-01 (codified retroactively in Phase 0 docs, 2026-05)

## Context

TripDataHub needs a backing store that:
- Syncs a user's trips between their iPhone and iPad.
- Lets accepted friends see each other's schedules.
- Drives a read-only browser-side Timeline card.
- Verifies user identity (GEMS ID + DOB) without storing DOB plaintext.

Options considered:
- **CloudKit Private Database** — strongest privacy, but requires Apple Sign-In and adds friction for the cross-user friend-sharing flow (private records can only be shared via CKShare, which complicates the web read path and admin tooling).
- **CloudKit Public Database** — every record is readable by all installed clients of the container. Writes are still constrained by the per-record creator. Easier cross-user reads (friends, web), simpler admin tooling, no extra auth.
- **Custom backend (Vapor / Firebase / Supabase)** — full control, but requires hosting, auth, deployment, and on-call ownership.

## Decision

Use the **CloudKit Public Database** in container `iCloud.com.sfune.TimelineSchedule` for all sync record types in Phase 1: `TDHGEMSVerification`, `TDHVerifiedUser`, `TDHFriendLink`, `TDHSharedSchedule`, `TripScheduleSnapshot`, `TDHDeviceScheduleSnapshot`, `TDHCrewAccessImportFile`.

Per-record privacy is achieved by:
- Embedding the user's normalized GEMS ID in record names so records are user-scoped by convention.
- Hashing identifying fields (DOB) before storage.
- Using `_icloud` security role for create/write of own records.
- Treating the system as **internal / TestFlight phase**, where the constraint of "any installed-app user can read" is acceptable.

## Consequences

- **Web client read path is trivial** — server-to-server CloudKit query with public credentials.
- **Admin tooling is trivial** — `scripts/upload_gems_verification.js` writes verification records with EC server-to-server signing without any per-user auth.
- **Schema deploy required** before TestFlight or App Store. Development → Production is a manual step in the dashboard.
- **No friend `CKShare` complexity.**

## Tradeoffs

- **Weaker privacy model.** Any user with the app installed can technically query any record type. We mitigate by hashing DOBs and not storing PII in record fields.
- **Quota is shared** across the user base. JSON payloads are kept small and binary data uses `Data` rather than `CKAsset` only because trip JSON is < 100KB.
- **Migration cost away from this is real.** A future move to Private DB or a custom backend would require record-by-record export/import. We accept this debt for Phase 1.

## Related

- `docs/CLOUDKIT.md` — schema, record names, security role baseline.
- `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md` — the `TDHCrewAccessImportFile` record type that extended this decision.

## Reconsider When

- The app exits TestFlight and DOB hashing or per-user privacy needs harden.
- Quota or cost on the public DB becomes a constraint.
- Friend sharing needs revocable access (Public DB has no built-in revocation other than deleting your own data).
