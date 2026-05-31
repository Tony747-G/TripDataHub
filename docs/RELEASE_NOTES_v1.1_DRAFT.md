# TDH v1.1 Draft Release Notes

This draft summarizes the v1.1 release candidate scope. Friend Sharing is in release-readiness freeze; only bug fixes and review-readiness changes should be accepted before submission.

## Highlights

- Ships optional Friend Sharing with mutual GEMS-ID approval.
- Keeps shared schedules read-only for receiving friends.
- Hardens Friend Sharing privacy boundaries for App Review.
- Added Crew Base selection in Settings.
- Added Manual Operational Event entry for reserve, call-out, training, and hold-style duty codes.
- Added Personal Event entry for lightweight non-duty calendar context.
- Extended Timeline into a Crew Duty Chronology.
- Hardened iPad Calendar layer separation between Operational, Bid, and Personal content.

## Friend Sharing RC Notes

- Friend requests are blocked for self-requests and duplicate pending requests.
- Existing accepted friends cannot be re-requested.
- Friend removal clears local visibility and removes the user's CloudKit approval.
- Mutual approval is required before shared schedules are visible.
- If a friend link is missing or no longer mutually approved, cached shared schedules are cleared.
- Empty schedule uploads are allowed so deleted local schedules clear the remote shared schedule.
- `TDHSharedSchedule` no longer persists internal CloudKit record names.

## App Review Notes

Friend Sharing has no public discovery, no messaging, no public profiles, and no online status or presence indicator. The feature is optional and does not affect local schedule import, Timeline, Calendar, or Settings.

## Operational Layer Manual Events

Users can create Manual Operational Events using fixed operational codes:

- `RSV-A`
- `RSV-B`
- `RSV-C`
- `RSV-D`
- `LCO`
- `HOT`
- `RCID`
- `CQ12`
- `CQ6`

Crew Base determines rule-based local duty windows where applicable. Events persist internally as UTC intervals.

## Crew Base Setting

Settings now supports Crew Base selection:

- `SDF`
- `SDFZ`
- `MIA`
- `ONT`
- `ANC`

Default Crew Base is `ANC`.

Crew Base is used when generating Manual Operational Event times. Existing events are not recalculated if the user later changes Crew Base.

## Personal Layer Stack Behavior

Personal Events render in the lower calendar stack area, alongside Bid Layer events.

Layer priority is:

1. Operational
2. Bid
3. Personal

When Bid and Personal events share a day, Bid remains the representative display item and Personal contributes to the `+N` overflow count. Personal-only days can still show a Personal representative stack item.

Personal Events do not appear in Timeline.

## Timeline

Timeline now represents Crew Duty Chronology rather than only flights.

Timeline includes imported trips, flights, DH, and Manual Operational Events such as RSV, LCO, HOT, RCID, and CQ.

Timeline excludes Bid Layer and Personal Layer events.

## Known Non-Goals

The v1.1 layer work does not include:

- reminders
- recurrence
- fatigue modeling
- legality engine
- Apple Calendar sync
- drag and drop
- advanced color or animation systems

## QA Focus

Regression coverage should protect:

- Operational events staying out of Bid/Personal stack
- Personal events staying out of Timeline
- Bid representative `+N` behavior
- Personal-only stack display
- delete refresh behavior for Operational and Personal events
- Crew Base changes not recalculating existing events
- `RCID` spelling across all surfaces
