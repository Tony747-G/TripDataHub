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

Domicile determines LDT. Currently supported (`DomicileSupport.swift`):

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

The full enumerated table for 2025-11-30 through 2027-10-30 lives in `CLAUDE.md` (top of file) and in `BidPeriodService.bidPeriodDefinitions`. When updating, both must move together. This file documents the boundary **rules**, not the full table, to avoid the table drifting in three places.

## Common Mistakes

- **Using UTC midnight as the boundary instead of 03:00 LDT.** Produces off-by-one assignments for trips departing between UTC midnight and 03:00 LDT.
- **Using `Calendar.current` (device local) for boundary math.** Two devices in different zones would get different BP membership for the same trip.
- **Forgetting that `BP26-07` is 4 weeks, not 8.** The iPad calendar grid renders 8 weeks for normal BPs; the 4-week BP needs the 4-week-row overflow handling in `iPadCalendarGrid`.
- **Forgetting to treat `SDFZ` as `SDF`.** They share the same Louisville timezone; user-entered domicile may be either.

## Related

- `INV-003` (BP/PP boundary), `INV-004` (Domicile controls LDT) in `docs/INVARIANTS.md`.
- `BidPeriodService.swift` — boundary math.
- `DomicileSupport.swift` — TZ resolution.
- `iPadBidPeriodCalendarView.swift` — calendar grid rendering using `domicile` from verified identity.
