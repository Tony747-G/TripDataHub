Codex Instruction: App Store Review Demo Mode and TripBoard Hiding

Goal

Implement a safe App Store Review / Demo Mode for TripDataHub.

Requirements:

* Reviewer can use app without GEMS verification
* TripBoard Fetch is hidden or disabled
* Manual PDF import still works
* Timeline/calendar remain reviewable
* Production logic remains unchanged

Required Changes

1. Add Review Mode Flag

Example:

enum AppEnvironment {
    static let isAppStoreReviewMode: Bool = {
        #if APPSTORE_REVIEW
        return true
        #else
        return false
        #endif
    }()
}

Use a centralized environment/config approach.

⸻

2. Bypass GEMS Verification

When Review Mode is enabled:

* Do not require GEMS verification
* Allow reviewer to enter app normally
* Show optional label:

Demo Mode: GEMS verification is disabled for App Store review.

Do not remove real production verification logic.

⸻

3. Hide or Disable TripBoard Fetch

When Review Mode is enabled:

* Hide TripBoard Fetch UI if possible
* Otherwise disable it

Optional disabled message:

TripBoard Fetch is unavailable in Demo Mode. Please use manual PDF import.

Do not add fake airline login/networking.

⸻

4. Keep Manual PDF Import Working

Reviewer must still be able to:

* Import synthetic sample PDF
* View timeline
* View calendar
* View trip details
* View local times

Do not redesign parser/import pipeline.

⸻

5. Synthetic Demo Data

Sample PDF is synthetic review data only.

Optional:

* Add small “Demo Data” or “Sample Schedule” label in review mode

⸻

App Review Compatibility

Implementation must support the following review statement:

TripDataHub is a personal schedule viewer that uses manually imported PDF schedule files provided by the user.

The app does not connect to airline systems, crew systems, or employer databases.

The sample screenshots and sample schedule data used for App Store review are synthetic demo data created specifically for review purposes only.

No real crew data, employee identifiers, or operational company data are included in the sample content.

⸻

Risk Controls

Must NOT expose:

* Real GEMS IDs
* Real crew names
* Real TripBoard data
* Real airline credentials
* Real operational schedule data

Production behavior must remain unchanged when Review Mode is disabled.

⸻

Acceptance Criteria

* Reviewer can open app without sign-in
* GEMS verification is bypassed in Review Mode
* TripBoard Fetch hidden/disabled
* Manual PDF import works
* Timeline/calendar display correctly
* Production mode unchanged
* No real operational data exposed

⸻

Priority

High priority before App Store submission.

Avoid scope creep.
::: ￼
