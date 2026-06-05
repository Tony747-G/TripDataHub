# CloudKit

Container: `iCloud.com.sfune.TimelineSchedule`. All record types use the **Public Database** (`_defaultZone`). See `docs/ADR/ADR-001-public-cloudkit-phase1.md` for the rationale.

## Workflow Reminders

- **Development schema** is auto-created by running a Development build once and saving a record of each new type. Until that happens, the type does not exist in the dashboard.
- **Production schema deploy is required** before TestFlight or App Store use whenever a record type, field, or index is added or changed. Use CloudKit Dashboard → Schema → Deploy Schema Changes.
- **Always check both Development and Production when investigating user-facing CloudKit bugs.** Debug/device builds may read the Development environment while TestFlight/App Store reads Production. Do not assume a Production fix applies to a Debug build, and do not declare a Friend/GEMS/schedule issue fixed until the relevant records have been checked in both environments.
- **Queryable indexes** must be added explicitly in CloudKit Dashboard → Indexes for any field used in a `CKQuery` predicate. New record types do NOT auto-create queryable indexes for `recordName` or custom fields.
- **Security Roles** baseline (Public DB):
  - `_icloud`: Create / Read / Write where users need to create or update their own sync records.
  - `_creator`: Read / Write where applicable.
  - `_world`: generally no write; read only when intentionally public.

---

## `TDHGEMSVerification`

- **Purpose:** Stores the GEMS-ID ↔ DOB hash so the app can verify a user's identity without storing DOB plaintext.
- **Record name:** `tdh_verify_{normalizedGEMSID}` (one per pilot, deterministic).
- **Key fields:** `gemsID`, `dobHash` (SHA-256), `domicile`, `schemaVersion` (currently `2`), `updatedAt`.
- **Owner model:** Uploaded by an admin tool (`scripts/upload_gems_verification.js`); read by all installed apps to verify identity.
- **Tombstone behavior:** None. Records are managed centrally.
- **Security role:** `_world` read; admin write only.
- **Production deploy required when:** Adding fields, changing `schemaVersion`, or adding queryable indexes.

## `TDHVerifiedUser`

- **Purpose:** Records that a specific user has successfully verified, used to populate the admin-visible user list.
- **Record name:** `tdh_verified_user_{normalizedGEMSID}`.
- **Key fields:** `gemsID`, `verifiedAt`, `schemaVersion` (currently `1`), `updatedAt`.
- **Owner model:** Created by the user's app on first successful verification.
- **Tombstone behavior:** None. Re-verification updates `updatedAt`; first-verify date is preserved.
- **Security role:** `_icloud` create/read/write own; `_world` read.
- **Production deploy required when:** Adding fields or queryable indexes.

## `TDHFriendLink`

- **Purpose:** Pair record connecting two users who have accepted each other as friends.
- **Record name:** `tdh_friend_{firstGEMS}_{secondGEMS}` where `(first, second)` is the canonical ordered pair (alphabetical).
- **Key fields:** `gemsA`, `gemsB`, `approvedA`, `approvedB`, `requestedAt`, `linkedAt`, `status`, `updatedAt`.
- **Owner model:** Either side may create the record (request); the other side updates the matching `*Accepted` flag.
- **Tombstone behavior:** Removing a friend clears both approvals, clears `linkedAt`, and marks the record `status = canceled`. A later request revives the same record as `pending` with a fresh `requestedAt`.
- **Security role:** `_icloud` create/read/write own.
- **Production deploy required when:** Adding fields or queryable indexes. Queries predicate on `gemsA` and `gemsB`; both fields need Queryable indexes in Production.

## `TDHSharedSchedule`

- **Purpose:** A user's parsed schedule, exposed to accepted friends.
- **Record name:** `tdh_schedule_{normalizedGEMSID}`.
- **Key fields:** `ownerGEMSID`, `schedulesData` (JSON-encoded `[PayPeriodSchedule]`), `updatedAt`.
- **Owner model:** Owned and written by the user; read by their friends.
- **Upload gating:** Written only when the user has at least one accepted mutual friend link.
- **Tombstone behavior:** None. Empty `schedulesData` means "no trips".
- **Privacy note:** Do not persist `ownerRecordName` or other internal CloudKit record identifiers in this record. Friend Sharing must not expose internal CloudKit IDs, device identifiers, CloudKit metadata, or presence/status fields.
- **Deletion:** When sharing is disabled by removing the last friend, or when Account Delete runs, the app deletes the user's `TDHSharedSchedule` and `TripScheduleSnapshot` records from the Public DB.

## `TripScheduleSnapshot`

- **Purpose:** Web/review-friendly serialized snapshot of the same owned schedule data.
- **Record name:** `tdh_snapshot_{normalizedGEMSID}`.
- **Deletion:** Deleted together with `TDHSharedSchedule` when the user no longer has active Friend Sharing or deletes their account.
- **Security role:** `_icloud` create/read/write own.
- **Production deploy required when:** Adding fields or queryable indexes.

## `TripScheduleSnapshot`

- **Purpose:** Schedule snapshot consumed by the web Timeline card (read-only browser view).
- **Record name:** `tdh_snapshot_{normalizedGEMSID}`.
- **Key fields:** `ownerGEMSID`, `ownerDisplayName`, `scheduleJSON`, `schemaVersion`, `updatedAt`.
- **Owner model:** Owned by the user; consumed by the web client.
- **Tombstone behavior:** None.
- **Security role:** `_icloud` create/read/write own; `_world` read.
- **Production deploy required when:** Adding fields, changing `schemaVersion`, or adding queryable indexes.

## `TDHDeviceScheduleSnapshot`

- **Purpose:** Syncs a user's `crewAccessSchedules` between their own iPhone and iPad.
- **Record name:** `tdh_device_schedule_{normalizedGEMSID}` (one per user — both devices share the same record).
- **Key fields:** `ownerGEMSID`, `ownerRecordName`, `schedulesData`, `schemaVersion` (currently `1`), `deviceID`, `source` (`iphone` / `ipad` / `unknown`), `updatedAt`.
- **Owner model:** Owned and written by the user; read by the user's other devices. Local-wins on conflict (see `INV-007`).
- **Tombstone behavior:** None. Empty `schedulesData` means "all trips deleted".
- **Security role:** `_icloud` create/read/write own.
- **Production deploy required when:** Adding fields, changing `schemaVersion`, or adding queryable indexes.

## `TDHCrewAccessImportFile`

- **Purpose:** Syncs the raw CrewAccess import JSON files (one record per imported trip) so that `Settings → CrewAccess Imports` converges across the user's devices. See `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`.
- **Record name:** `tdh_import_{normalizedGEMSID}_{baseFileName}` where `baseFileName` is `{date}_{tripId}` (filename without `.json`).
- **Key fields:** `ownerGEMSID`, `fileName`, `jsonData` (Data, the full JSON file contents), `tripInformationDate`, `firstDepartureUTC`, `updatedAt`, `deletedAt` (nil when active, set when tombstoned), `schemaVersion` (currently `1`).
- **Owner model:** Owned and written by the user. Read by the user's other devices on foreground / iPad workspace task / app init.
- **Tombstone behavior:** **Required.** Deletion sets `deletedAt = Date()` rather than removing the record. Other devices observing `deletedAt != nil` remove the local file. See `INV-008`.
- **Security role:** `_icloud` create/read/write own.
- **Production deploy required when:** Adding fields, changing `schemaVersion`, or adding queryable indexes. The fetch query predicates on `ownerGEMSID`, so that field needs a Queryable index in Production.

---

## Common Pitfalls

- **Development vs Production drift can look like a code regression.** This has already caused repeated Friend Sharing bugs: Production had `TDHFriendLink` accepted and `TDHSharedSchedule` present, while Development still had the same friend link pending and/or missing schedule data. When debugging Friend Timeline, GEMS verification, shared schedules, import files, or device sync:
  1. Determine which CloudKit environment the running build is using.
  2. Lookup the record in both `development` and `production`.
  3. Repair or copy records in both environments when the user is testing Debug and production behavior also matters.
  4. Re-verify `TDHFriendLink`, `TDHSharedSchedule`, and `TripScheduleSnapshot` together; an accepted friend link without schedule data still produces an empty Friend Timeline.
- **Setting a field to `nil` during initial schema creation prevents auto-schema** — CloudKit cannot infer the field type from `nil`. Omit the assignment instead.
- **Public DB record IDs are global** — make sure `recordName` is collision-free across users. The convention here is to embed `normalizedGEMSID` in every record name.
- **The dashboard caches schema** — after a new record type is created via app save, refresh the browser before checking Schema → Record Types.
