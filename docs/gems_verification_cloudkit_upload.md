# GEMS Verification CloudKit Upload

This document describes the developer-only flow for updating `TDHGEMSVerification`
records from the monthly seniority CSV. The app no longer exposes a CSV upload UI
in the Admin tab because the source CSV contains DOB in plain text.

## Source CSV

Keep the monthly CSV in the repo root while working locally, but do not commit it.
The filename pattern `*_seniority.csv` is ignored by `.gitignore`.

Expected columns:

```csv
SEN#,GEMS,DOM,DOB
1,557068,SDF,9/24/64
2,556553,SDF,6/22/61
```

Required columns:

- `GEMS`
- `DOB`

Optional domicile column, one of:

- `DOM`
- `DOMICILE`
- `BASE`

Supported domiciles:

- `ANC`
- `SDF`
- `SDFZ` (uses SDF/Louisville local time)
- `ONT`
- `MIA`

If no domicile is present, the uploader defaults to `ANC`.

## What Gets Uploaded

The uploader writes only hashed verification data to CloudKit:

Record type: `TDHGEMSVerification`

Record name:

```text
tdh_verify_{normalizedGEMSID}
```

Fields:

| Field | Type | Value |
|---|---|---|
| `gemsID` | String | 7-digit normalized GEMS ID |
| `dobHash` | String | SHA-256 hash of normalized GEMS + DOB |
| `domicile` | String | `ANC`, `SDF`, `SDFZ`, `ONT`, or `MIA` |
| `schemaVersion` | Int(64) | `2` |
| `updatedAt` | Date/Time | upload time |

Plain DOB is never uploaded.

Hash payload:

```text
TDH_GEMS_VERIFY_V1|{GEMSID}|{MM/DD/YYYY}|TripDataHub-GEMSVerification-v1
```

Example DOB normalization:

```text
9/24/64 -> 09/24/1964
10-2-69 -> 10/02/1969
```

## One-Time CloudKit Server-to-Server Key Setup

CloudKit Web Services upload requires a Server-to-Server key.

1. Generate a private key locally:

   ```bash
   mkdir -p ~/.tripdatahub-cloudkit
   openssl ecparam -name prime256v1 -genkey -noout \
     -out ~/.tripdatahub-cloudkit/tripdatahub-cloudkit.pem
   chmod 600 ~/.tripdatahub-cloudkit/tripdatahub-cloudkit.pem
   ```

2. Print the public key:

   ```bash
   openssl ec -in ~/.tripdatahub-cloudkit/tripdatahub-cloudkit.pem -pubout
   ```

3. Open CloudKit Dashboard.

4. Select container:

   ```text
   iCloud.com.sfune.TimelineSchedule
   ```

5. Go to API Access / Server-to-Server Keys.

6. Add the public key and copy the generated Key ID.

7. Keep the private key local. Never commit it, paste it into chat, or store it in
   the app bundle.

## Dry Run

Always run a dry run first:

```bash
node scripts/upload_gems_verification.js \
  --csv 2026-05_seniority.csv \
  --dry-run \
  --out build/gems_verification_preview.json
```

Check the summary:

```text
Prepared 3402 TDHGEMSVerification records.
Skipped 1 rows.
```

The current `2026-05_seniority.csv` has one intentionally skipped row with empty
GEMS/DOB. The preview includes `normalizedDOB` so the developer can audit
parsing before upload, but that preview file must not be committed or shared.

## Upload to Development

```bash
CK_KEY_ID="<CloudKit Server-to-Server Key ID>" \
CK_PRIVATE_KEY_PATH="$HOME/.tripdatahub-cloudkit/tripdatahub-cloudkit.pem" \
node scripts/upload_gems_verification.js \
  --csv 2026-05_seniority.csv \
  --environment development \
  --upload \
  --out build/gems_verification_development_upload.json
```

Then verify in CloudKit Dashboard:

```text
Development -> Data -> Records -> TDHGEMSVerification
```

Search a known record name:

```text
tdh_verify_0557068
```

Confirm fields:

- `gemsID`
- `dobHash`
- `domicile`
- `schemaVersion = 2`
- `updatedAt`

## Deploy Schema Changes

If `domicile` or other fields are new in Development, deploy schema before
TestFlight/Production use:

```text
CloudKit Dashboard -> Deploy Schema Changes
```

## Upload to Production

Only after Development is verified and schema changes are deployed:

```bash
CK_KEY_ID="<CloudKit Server-to-Server Key ID>" \
CK_PRIVATE_KEY_PATH="$HOME/.tripdatahub-cloudkit/tripdatahub-cloudkit.pem" \
node scripts/upload_gems_verification.js \
  --csv 2026-05_seniority.csv \
  --environment production \
  --upload \
  --out build/gems_verification_production_upload.json
```

Then verify:

```text
Production -> Data -> Records -> TDHGEMSVerification
```

## Failure Notes

- `AUTHENTICATION_REQUIRED` or signature errors usually mean the Key ID, private
  key, date/time, or CloudKit container is wrong.
- `WRITE operation not permitted` means CloudKit Security Roles need to allow
  the server-to-server request to write `TDHGEMSVerification` in the public DB.
- If users verify with the wrong base after upload, confirm the CSV has `DOM`,
  `DOMICILE`, or `BASE` and that the value is one of the supported domiciles.

## References

- Apple CloudKit Web Services: records/modify
- Apple CloudKit Web Services: Server-to-Server Key authentication
