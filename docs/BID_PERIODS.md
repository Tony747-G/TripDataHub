# Bid Periods & Pay Periods

The operational calendar that drives trip grouping, the iPad calendar grid, and the Timeline.

## Definitions

- **Pay Period (PP)** — a 28-day operational sub-period.
- **Bid Period (BP)** — usually two contiguous Pay Periods (56 days). Special cases exist (e.g. `BP26-07` is a single 28-day BP).
- **LDT** — Local Domicile Time, the wall-clock time at the pilot's home base.

## Boundary Rule

A PP starts at **03:00 LDT** on its start date and ends at **03:00 LDT** on the start date of the next PP (half-open interval). A trip belongs to a PP iff its **departure time** falls within that interval.

The interval is half-open in code: `start <= dateUTC < end`.

The 03:00 boundary is computed by `BidPeriodService.bidPeriodBoundaryUTCDate`, which formats `"\(dateString) 03:00"` in the **domicile calendar** and converts the result to UTC. The returned `Date` is absolute UTC time; it is the same physical moment for every device, but corresponds to different wall-clock times in different zones.

A BP is the contiguous union of its constituent PPs.

## Domiciles

Domicile determines LDT. Currently supported (`TripDataHub/Services/DomicileSupport.swift`):

```text
ANC  -> America/Anchorage
SDF  -> America/Kentucky/Louisville
SDFZ -> America/Kentucky/Louisville   (treated as SDF)
ONT  -> America/Los_Angeles
MIA  -> America/New_York
```

Default: `ANC`. Unknown values normalize to `ANC` via `DomicileSupport.normalize`.

Adding a new domicile requires:
1. Updating `DomicileSupport.supportedDomiciles` and the `timeZone(for:)` switch.
2. Updating this document.
3. Adding a test case in `BidPeriodServiceTests.test_bidPeriod_usesDomicile0300Boundary`.

## Worked Examples

These examples assume domicile `ANC` (America/Anchorage):

- **`PP26-06`** starts `2026-05-17 03:00 ANC` and ends `2026-06-14 03:00 ANC`. Trip departures in `[start, end)` belong to this PP.
- **`PP26-07`** starts `2026-06-14 03:00 ANC` and ends `2026-07-12 03:00 ANC`.
- **`BP26-04`** = `PP26-06` + `PP26-07`. Spans `2026-05-17 03:00 ANC` through `2026-07-12 03:00 ANC` (56 days).
- **`BP26-07`** is the special 4-week BP for 2026: contains only `PP26-12`, spans `2026-11-01` through `2026-11-29`.

The same dates expressed for an `SDF`-based pilot would correspond to different absolute UTC moments because `03:00 Louisville` ≠ `03:00 Anchorage`. This is intentional and is what makes the per-domicile boundary correct.

## Reference: Full BP/PP Table

This is the human-readable copy of the period definitions. `BidPeriodService.bidPeriodDefinitions` is the runtime source of truth. When changing the table, update this section and the service together, then run the Bid Period tests.

Dates below are inclusive calendar-date coverage. Runtime membership still uses the domicile-local 03:00 half-open boundaries described above.

| Bid Period | Coverage | Pay Periods |
|---|---|---|
| BP26-01 | 2025-11-30–2026-01-24 | PP25-13: 2025-11-30–2025-12-27; PP26-01: 2025-12-28–2026-01-24 |
| BP26-02 | 2026-01-25–2026-03-21 | PP26-02: 2026-01-25–2026-02-21; PP26-03: 2026-02-22–2026-03-21 |
| BP26-03 | 2026-03-22–2026-05-16 | PP26-04: 2026-03-22–2026-04-18; PP26-05: 2026-04-19–2026-05-16 |
| BP26-04 | 2026-05-17–2026-07-11 | PP26-06: 2026-05-17–2026-06-13; PP26-07: 2026-06-14–2026-07-11 |
| BP26-05 | 2026-07-12–2026-09-05 | PP26-08: 2026-07-12–2026-08-08; PP26-09: 2026-08-09–2026-09-05 |
| BP26-06 | 2026-09-06–2026-10-31 | PP26-10: 2026-09-06–2026-10-03; PP26-11: 2026-10-04–2026-10-31 |
| BP26-07 | 2026-11-01–2026-11-28 | PP26-12: 2026-11-01–2026-11-28 (four-week BP) |
| BP27-01 | 2026-11-29–2027-01-23 | PP26-13: 2026-11-29–2026-12-26; PP27-01: 2026-12-27–2027-01-23 |
| BP27-02 | 2027-01-24–2027-03-20 | PP27-02: 2027-01-24–2027-02-20; PP27-03: 2027-02-21–2027-03-20 |
| BP27-03 | 2027-03-21–2027-05-15 | PP27-04: 2027-03-21–2027-04-17; PP27-05: 2027-04-18–2027-05-15 |
| BP27-04 | 2027-05-16–2027-07-10 | PP27-06: 2027-05-16–2027-06-12; PP27-07: 2027-06-13–2027-07-10 |
| BP27-05 | 2027-07-11–2027-09-04 | PP27-08: 2027-07-11–2027-08-07; PP27-09: 2027-08-08–2027-09-04 |
| BP27-06 | 2027-09-05–2027-10-30 | PP27-10: 2027-09-05–2027-10-02; PP27-11: 2027-10-03–2027-10-30 |
| BP27-07 | 2027-10-31–2027-12-25 | PP27-12: 2027-10-31–2027-11-27; PP27-13: 2027-11-28–2027-12-25 |

## Common Mistakes

- **Using UTC midnight as the boundary instead of 03:00 LDT.** Produces off-by-one assignments for trips departing between UTC midnight and 03:00 LDT.
- **Using `Calendar.current` (device local) for boundary math.** Two devices in different zones would get different BP membership for the same trip.
- **Forgetting that `BP26-07` is 4 weeks, not 8.** The iPad calendar grid renders 8 weeks for normal BPs; the 4-week BP needs the 4-week-row overflow handling in `iPadCalendarGrid`.
- **Forgetting to treat `SDFZ` as `SDF`.** They share the same Louisville timezone; user-entered domicile may be either.

## Related

- `INV-003` (BP/PP boundary), `INV-004` (Domicile controls LDT) in `docs/INVARIANTS.md`.
- `TripDataHub/Services/BidPeriodService.swift` — boundary math.
- `TripDataHub/Services/DomicileSupport.swift` — TZ resolution.
- `TripDataHub/Views/iPad/iPadBidPeriodCalendarView.swift` — calendar grid rendering using `domicile` from verified identity.
