# App Store Review Submission Notes

Use this checklist when submitting the App Store Review / Demo Mode build.

## Build Mode

For v1.1.0 Friend Sharing review, archive a normal Release build unless you intentionally want the legacy Demo Mode build.

Do not use the `APPSTORE_REVIEW` Swift compilation flag when Friend Sharing itself must be visible to App Review.

Legacy Demo Mode can still be produced with the `APPSTORE_REVIEW` Swift compilation flag enabled.

This enables Demo Mode:

- GEMS verification is bypassed.
- TripBoard Fetch is unavailable.
- Friends / advanced schedule sharing is hidden and disabled.
- Manual PDF import, Timeline, Calendar, flight details, and local time rendering remain available.

Production behavior is unchanged when `APPSTORE_REVIEW` is not defined.

## Archive Command

```sh
xcodebuild \
  -project TripDataHub.xcodeproj \
  -scheme TripDataHub \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  OTHER_SWIFT_FLAGS='$(inherited) -DAPPSTORE_REVIEW' \
  archive
```

If archiving from Xcode instead of the command line, add `APPSTORE_REVIEW` to the Release archive build's Swift Active Compilation Conditions / Other Swift Flags before creating the archive.

## App Review Information

Set:

- Sign-in required: OFF

Do not provide airline, CrewAccess, TripBoard, GEMS, or employer credentials.

## Review Notes

For v1.1.0 and later, paste the following into App Review Notes:

```text
TripDataHub is a personal schedule viewer that uses manually imported PDF schedule files provided by the user.

TripDataHub includes optional Friend Sharing. Friend Sharing uses CloudKit Public Database records keyed by verified GEMS IDs. It does not use CloudKit Sharing / CKShare.

Users must mutually add each other's GEMS ID before any schedule information becomes visible. Adding another user's GEMS ID only records one side of approval. The friend connection becomes active only after both users have added each other.

There is no public user search, public profile directory, messaging, social feed, or one-way following.

TripDataHub uploads shared schedule records only after a mutual friend connection is accepted. After acceptance, both users can view each other's shared schedule. If either user removes the friend connection, the link is marked as canceled, approval flags are cleared, and the other user's schedule is no longer displayed. When a user disables sharing by removing their last friend or deletes their account, TripDataHub removes that user's shared schedule records from CloudKit Public Database and cancels their friend links.

The shared Friend schedule is read-only to the receiving user. The feature shares only the user's display name/profile picture where configured and parsed schedule data needed for the schedule timeline. It does not expose internal CloudKit IDs, device identifiers, CloudKit metadata, last-sync timestamps, online status, or hidden profile attributes.

The app does not connect to airline systems, crew systems, employer databases, or TripBoard during review. Manual PDF import remains available so reviewers can inspect the core schedule viewer experience. TripBoard Fetch remains unavailable in App Store builds.

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

Fresh install with `APPSTORE_REVIEW` enabled:

- App opens without sign-in.
- Import Preview appears when the sample PDF is shared to TripDataHub.
- Confirm Import saves trip `A00001`.
- Timeline displays ANC-CVG, CVG-HND, and DH HND-ANC.
- Calendar displays the imported trip.
- Flight detail / trip timeline sheet is reviewable.
- Settings shows Demo Mode and a TripBoard unavailable message.
- No GEMS verification form is shown.
- If Friend Sharing is enabled for the submitted build, it remains optional and requires iCloud plus mutual GEMS-ID approval before any shared schedule appears.
