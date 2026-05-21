# App Store Review Submission Notes

Use this checklist when submitting the App Store Review / Demo Mode build.

## Build Mode

Archive the review build with the `APPSTORE_REVIEW` Swift compilation flag enabled.

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

Paste the following into App Review Notes:

```text
TripDataHub is a personal schedule viewer that uses manually imported PDF schedule files provided by the user.

For App Store review, the submitted build runs in Demo Mode. GEMS verification is disabled, TripBoard Fetch is unavailable, and Friends / advanced schedule sharing is hidden and disabled. The app does not require sign-in for review.

The app does not connect to airline systems, crew systems, employer databases, or TripBoard during review. Manual PDF import remains available so reviewers can inspect the core schedule viewer experience.

Sample schedule PDF:
https://tripdatahub.app/sample/

Review steps:
1. Open the sample schedule URL above.
2. Open or download `SampleTrip.pdf` from the page.
3. Use iOS Share and choose TripDataHub.
4. Confirm the import in TripDataHub.
5. Review the imported trip in Timeline, Calendar, and flight detail views.

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
- No Friends / advanced sharing UI is shown.
- No advanced sharing CloudKit sync/upload/request is performed.
