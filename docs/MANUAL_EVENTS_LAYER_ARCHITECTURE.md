# Manual Events Layer Architecture

This document records the v1.1 Time Engine expansion that allows user-created Manual Operational and Personal events. Treat this as the layer contract for Calendar and Timeline work.

## Scope

Manual events extend TDH from a trip-only viewer into a Crew Duty Chronology system.

This is not a reminder system, recurrence engine, fatigue engine, or Apple Calendar replacement.

## Crew Base Setting

Settings exposes a persistent Crew Base value.

Supported values:

- `SDF`
- `SDFZ`
- `MIA`
- `ONT`
- `ANC`

Default: `ANC`.

Crew Base is used when creating Manual Operational Events that have rule-based LDT windows. The selected base determines the local duty window and the timezone used to convert the entered local date into persisted UTC timestamps.

Important rule: changing Crew Base later must not silently recalculate existing events. Existing Manual Operational Events keep their persisted `startUTC` and `endUTC`. If the model stores event-time crew base, display should prefer the event's creation base for that event.

## Manual Operational Codes

Manual Operational Events support this fixed code list:

- `RSV-A`
- `RSV-B`
- `RSV-C`
- `RSV-D`
- `LCO`
- `HOT`
- `RCID`
- `CQ12`
- `CQ6`

Free text is not allowed for Operational codes.

`RCID` must remain `RCID`. Do not rename it to `RCIT`.

Deadhead (`DH`) is not a manual operational code. DH is imported from schedule data and must not be reintroduced as a manual entry type.

Reserve and call-out windows are defined in `docs/CREW_CALLOUT_PERIODS.md`.

## Personal Codes

Personal Events currently support a deliberately small fixed set:

- `Commute`
- `Medical`
- `Appointment`
- `Other`

Personal Events are not crew duty. They must not appear in Timeline and must not render in the Operational lane.

## Persistence Rule

Manual events persist UTC timestamps:

- `startUTC`
- `endUTC`

Local time is used to interpret user input and render labels. UTC remains the source of truth for sorting, overlap checks, day resolution, and persistence.

Cross-midnight events must persist the correct next-day `endUTC`. Examples that must remain covered by tests:

- `ANC RSV-C 2015-0814`
- `ONT RSV-A 2300-1059`
- `SDF RSV-C 1600-0359`
- `MIA RSV-D 0500-1659`
- `RCID 0900-1300`
- `LCO 0800-1400`

## Calendar Layer Priority

Calendar is layered, not a generic flat event list.

Priority:

1. Operational
2. Bid
3. Personal

Operational content is visually dominant. Bid and Personal share the lower stack area.

## Operational Layer

Operational Layer includes:

- Imported Trip Bars
- Imported DH where applicable
- Manual `RSV-A` / `RSV-B` / `RSV-C` / `RSV-D`
- Manual `LCO`
- Manual `HOT`
- Manual `RCID`
- Manual `CQ12`
- Manual `CQ6`

Operational events render in the same hierarchy as Trip Bars. They must not be added to the Bid/Personal stack.

For multi-day or cross-midnight Operational events, calendar rendering may split the event across visible day cells, but the underlying event remains one persisted UTC interval.

## Bid Layer

Bid Layer is administrative schedule-cycle information. It belongs in the lower stack area.

Examples:

- `BID PACKAGE OUT`
- `SCHD BID CLOSE`
- `VTO PUBLISHED`
- `VTO BID CLOSE`
- `LITT ACCEPT`

Qualification controls which bid events are shown. If Settings says Captain, show Captain bid timeline only. If Settings says First Officer, show First Officer bid timeline only. Do not show both at the same time unless product requirements explicitly change.

## Personal Layer

Personal Layer shares the same lower stack area as Bid Layer.

Personal must not:

- render as a Trip Bar
- appear in Timeline
- visually compete with Operational Layer

If Bid and Personal events occur on the same day, Bid is the representative stack item and Personal contributes to the overflow count.

Examples:

- Bid + Personal same day: `[VTO BID CLOSE] +1`
- Personal only day: Personal event is the representative stack item

Tap or popover expansion may reveal the full Bid/Personal list.

## Timeline Definition

Timeline is now a Crew Duty Chronology, not a flight-only list.

Timeline includes:

- Trips
- Flights
- DH imported from schedule data
- Manual Operational Events: `RSV`, `LCO`, `HOT`, `RCID`, `CQ`

Timeline excludes:

- Personal Events
- Bid Layer events
- Financial indicators

Display labels should prefer the event code. LDT times should be shown for Manual Operational Events.

## Known Non-Goals

Do not add these as part of the v1.1 manual event layer unless a new scope explicitly approves them:

- reminders
- recurrence
- fatigue modeling
- legality engine
- Apple Calendar sync
- drag and drop
- advanced edit workflows beyond current manual edit/delete

## Regression Checklist

Before changing this area, verify:

- iPad Calendar Operational Bar and Bid/Personal stack do not overlap or compete.
- Personal does not appear in Timeline.
- Manual Operational does not enter the Bid/Personal stack.
- Bid representative +N behavior is correct when Personal is on the same day.
- Personal-only days still show stack content.
- Deleting Personal updates stack count immediately.
- Deleting Operational updates calendar lane immediately.
- Crew Base changes do not recalculate existing events.
- `RCID` spelling is fixed on all surfaces.

## Related

- `docs/CREW_CALLOUT_PERIODS.md`
- `docs/BID_PERIODS.md`
- `docs/INVARIANTS.md`
- `docs/ADR/ADR-002-utc-source-of-truth.md`
