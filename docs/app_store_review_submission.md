# App Store Review Submission Notes

Use this checklist when submitting the App Store Review build.

## Build Mode

For OpenTime / TripBoard Fetch review, archive a normal Release build. Do not define `APPSTORE_REVIEW` unless you intentionally want the legacy Demo Mode build that hides TripBoard-related UI.

Do not use the `APPSTORE_REVIEW` Swift compilation flag when OpenTime, TripBoard Fetch, or Friend Sharing must be visible to App Review.

Legacy Demo Mode can still be produced with the `APPSTORE_REVIEW` Swift compilation flag enabled.

This enables Demo Mode:

- GEMS verification is bypassed.
- TripBoard Fetch is unavailable.
- OpenTime is hidden.
- Friends / advanced schedule sharing is hidden and disabled.
- Manual PDF import, Timeline, Calendar, flight details, and local time rendering remain available.

Normal Release behavior is used when `APPSTORE_REVIEW` is not defined.

## Archive Command

```sh
xcodebuild \
  -project TripDataHub.xcodeproj \
  -scheme TripDataHub \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  archive
```

If a legacy Demo Mode build is intentionally needed, add `APPSTORE_REVIEW` to the Release archive build's Swift Active Compilation Conditions / Other Swift Flags before creating the archive.

## App Review Information

Set:

- Sign-in required: OFF

Do not provide airline, CrewAccess, TripBoard, GEMS, or employer credentials unless a specific TripBoard review account is available and approved for App Review use.

## Review Notes

For v1.1.0 and later, paste the following into App Review Notes:

```text
TripDataHub is a personal schedule viewer that uses manually imported PDF schedule files provided by the user. It also includes an optional OpenTime view powered by TripBoard Fetch.

TripDataHub includes optional Friend Sharing. Friend Sharing uses CloudKit Public Database records keyed by verified GEMS IDs. It does not use CloudKit Sharing / CKShare.

Users must mutually add each other's GEMS ID before any schedule information becomes visible. Adding another user's GEMS ID only records one side of approval. The friend connection becomes active only after both users have added each other.

There is no public user search, public profile directory, messaging, social feed, or one-way following.

TripDataHub uploads shared schedule records only after a mutual friend connection is accepted. After acceptance, both users can view each other's shared schedule. If either user removes the friend connection, the link is marked as canceled, approval flags are cleared, and the other user's schedule is no longer displayed. When a user disables sharing by removing their last friend or deletes their account, TripDataHub removes that user's shared schedule records from CloudKit Public Database and cancels their friend links.

The shared Friend schedule is read-only to the receiving user. The feature shares only the user's display name/profile picture where configured and parsed schedule data needed for the schedule timeline. It does not expose internal CloudKit IDs, device identifiers, CloudKit metadata, last-sync timestamps, online status, or hidden profile attributes.

OpenTime is an optional read-only view powered by TripBoard Fetch.

Users must have their own active BidPro TripBoard subscription and authenticate with their own TripBoard credentials. TripDataHub only displays OpenTime information that is already available to that authenticated user through their TripBoard account.

TripDataHub does not provide TripBoard access, does not bypass any subscription requirement, does not share OpenTime data with other users, and does not submit, bid for, reserve, or modify any TripBoard data.

Fetching occurs only on the user's device after the user authenticates. It is initiated by app launch when the user enables Auto Fetch on App Open, or by manual refresh / Fetch. TripDataHub does not run server-side scraping, automated background monitoring, continuous polling, or push notifications for OpenTime.

For App Review, please use Demo Mode to review the OpenTime interface without using real TripBoard credentials.

OpenTime Demo Mode steps:
1. Open TripDataHub.
2. Go to Settings.
3. Enable Demo Mode in the TripBoard Fetch section.
4. Open the OpenTime tab.
5. Tap Refresh if needed.

Demo Mode uses static sample OpenTime data stored in the app and does not connect to TripBoard.

Manual PDF import remains available so reviewers can inspect the core schedule viewer experience without TripBoard credentials.

Sample schedule PDF:
https://tripdatahub.app/sample/

Review steps:
1. Open the sample schedule URL above.
2. Open or download `SampleTrip.pdf` from the page.
3. Use iOS Share and choose TripDataHub.
4. Confirm the import in TripDataHub.
5. Review the imported trip in Timeline, Calendar, and flight detail views.

Friend Sharing review test account:
1. Verify with test GEMS ID `0000001` and DOB `01/01/1990`.
2. Open Friends and add friend GEMS ID `0000002`.
3. Test account `0000002` is preconfigured and has already approved the relationship for App Review. After adding `0000002`, the mutual friend connection becomes active and the sample shared schedule becomes visible.
4. Swipe the friend row and choose Unfriend, then confirm. The friend schedule disappears and the link is canceled.

The sample screenshots and sample schedule data used for App Store review are synthetic demo data created specifically for review purposes only. No real crew data, employee identifiers, airline credentials, or operational company data are included in the sample content.
```

## Expected Review Flow

Fresh install from a normal Release build:

- App opens without mandatory sign-in.
- Import Preview appears when the sample PDF is shared to TripDataHub.
- Confirm Import saves trip `A00001`.
- Timeline displays ANC-CVG, CVG-HND, and DH HND-ANC.
- Calendar displays the imported trip.
- Flight detail / trip timeline sheet is reviewable.
- OpenTime tab is visible.
- Settings shows TripBoard Fetch, Auto Fetch on App Open, and the TripBoard Log-in / Fetch action.
- Settings also provides Demo Mode for reviewing OpenTime without TripBoard credentials.
- TripBoard Fetch remains optional and requires the user's own active TripBoard subscription and credentials.
- Friend Sharing remains optional and requires iCloud plus mutual GEMS-ID approval before any shared schedule appears.
