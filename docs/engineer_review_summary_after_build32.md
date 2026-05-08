# Engineer Review Summary After Build 32

This summary covers the changes made after engineer commit `628e433`
(`Store and remove foreground observer token in deinit (build 32)`) on branch
`claude/sad-babbage-c05c38`.

## Scope

The work since `628e433` covers three areas:

1. Domicile-aware PP/BP boundary logic
2. Admin CSV upload removal
3. Developer-only GEMS verification upload script

No build number bump, commit, push, archive, or upload has been performed after
these changes.

## 1. Domicile-Aware PP/BP Logic

### Product Rule Captured

All PP/BP boundaries start at `03:00 LDT` (Local Domicile Time) for the pilot's
base. The trip's departure UTC determines which PP/BP it belongs to after
converting the domicile boundary to UTC.

Current domiciles:

| Domicile | Time Zone |
|---|---|
| `ANC` | Anchorage local time |
| `SDF` | Louisville local time |
| `SDFZ` | Same as SDF / Louisville local time |
| `ONT` | Ontario CA / Pacific time |
| `MIA` | Miami / Eastern time |

### Files Changed

- `MEMORY.md`
- `TripDataHub/Services/DomicileSupport.swift`
- `TripDataHub/Services/BidPeriodService.swift`
- `TripDataHub/Services/GEMSVerificationCloudKitService.swift`
- `TripDataHub/ViewModels/AppViewModel.swift`
- `TripDataHub/Views/iPad/iPadBidPeriodCalendarView.swift`
- `TripDataHub/Views/iPad/iPadWorkspaceModels.swift`
- `TripDataHubTests/CalendarSupportTests.swift`
- `TripDataHubTests/GEMSVerificationCloudKitServiceTests.swift`
- `TripDataHubTests/AppViewModelDeviceSyncTests.swift`

### Implementation Notes

- Added `DomicileSupport.swift` as a separate service helper.
- `SDFZ` normalizes as a valid domicile but uses SDF/Louisville time.
- `bidPeriod(for:domicile:)` now computes `03:00` boundaries in the selected
  domicile timezone, then compares using UTC.
- `bidPeriod(for:domicile:)` keeps the computed start boundary while selecting
  the matching bid period, avoiding repeated start-boundary calculation in
  `.max(by:)`.
- iPad calendar uses `viewModel.verifiedIdentity?.domicile ?? "ANC"`.
- GEMS verification records now support `domicile` in CloudKit.
- Existing records without a `domicile` field still default to `ANC`.

### CloudKit Impact

`TDHGEMSVerification` now includes:

```text
domicile: String
schemaVersion: 2
```

Development must generate/confirm this field, then Deploy Schema Changes before
Production/TestFlight reliance.

## 2. Admin CSV Upload Removal

### Product Decision

Because the source seniority CSV contains DOB in plain text and there is only
one admin/developer, CSV upload should not live inside the production app UI.

### Files Changed

- `TripDataHub/Views/AdminTabView.swift`
- `TripDataHub/Views/AdminSections.swift`
- `.gitignore`

### Implementation Notes

- Removed `Upload GEMS/DOB CSV`.
- Removed `Import from App Documents`.
- Removed `Reset Seniority DB`.
- Removed file importer from `AdminTabView`.
- Admin tab now shows only `Verified App Users`.
- `AppViewModel.importSeniorityCSVData(_:)` remains as a developer/test
  compatibility hook only and is documented as no longer being reachable from
  the production Admin UI.
- Added `.gitignore` rules:

```gitignore
*_seniority.csv
*.pem
.cloudkit-keys/
build/
```

## 3. Developer-Only GEMS Verification Upload Script

### Files Added

- `scripts/upload_gems_verification.js`
- `docs/gems_verification_cloudkit_upload.md`

### Script Behavior

The script:

1. Reads local seniority CSV.
2. Parses `GEMS`, `DOB`, and optional `DOM` / `DOMICILE` / `BASE`.
3. Normalizes 6-digit numeric GEMS IDs to 7 digits with leading `0`.
4. Normalizes DOB to `MM/DD/YYYY`.
5. Hashes with the same payload as the app:

   ```text
   TDH_GEMS_VERIFY_V1|{GEMSID}|{MM/DD/YYYY}|TripDataHub-GEMSVerification-v1
   ```

6. Writes a preview JSON.
7. Uploads to CloudKit Web Services using server-to-server signed requests.

CloudKit operation:

```text
POST /database/1/iCloud.com.sfune.TimelineSchedule/{environment}/public/records/modify
operationType: forceUpdate
recordType: TDHGEMSVerification
recordName: tdh_verify_{GEMSID}
```

### Dry Run

```bash
node scripts/upload_gems_verification.js \
  --csv 2026-05_seniority.csv \
  --dry-run \
  --out build/gems_verification_preview.json
```

Dry-run result against the current CSV:

```text
Prepared 3402 TDHGEMSVerification records.
Skipped 1 rows.
```

The skipped row has empty GEMS/DOB.

### Upload

```bash
CK_KEY_ID="<CloudKit Server-to-Server Key ID>" \
CK_PRIVATE_KEY_PATH="$HOME/.tripdatahub-cloudkit/tripdatahub-cloudkit.pem" \
node scripts/upload_gems_verification.js \
  --csv 2026-05_seniority.csv \
  --environment development \
  --upload
```

## Verification Performed

Before the script/docs work, the domicile changes were verified with:

- Targeted GEMS + calendar tests: passed
- Full unit tests: `159 tests, 0 failures`
- iPad build: `BUILD SUCCEEDED`

After Admin upload removal:

- iPhone simulator build: `BUILD SUCCEEDED`

After engineer review follow-up:

- `DomicileSupport` moved to its own file and registered in the Xcode project.
- `bidPeriod(for:domicile:)` start-boundary selection avoids double-calculation
  in `.max(by:)`.
- `CalendarBidPeriodGenerationTests` already includes explicit ANC boundary
  coverage via `test_bidPeriod_usesAnchorage0300Boundary`.
- Targeted calendar + GEMS verification tests: `20 tests, 0 failures`.

## Review Points Requested

Please review:

1. Whether any remaining legacy `importSeniorityCSVData` methods should stay as
   testable/internal helpers or be made non-UI developer utilities only.
2. Whether `TDHGEMSVerification.schemaVersion = 2` is sufficient for the
   domicile migration.
3. Whether the Node CloudKit Web Services signing implementation matches the
   expected Apple server-to-server request format.
4. Whether the Admin tab should display last verification DB upload metadata in
   the future, or remain Verified Users only.
