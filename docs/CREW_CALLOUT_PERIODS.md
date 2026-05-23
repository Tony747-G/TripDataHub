# Crew Call-Out Periods

Reference data for future manual Operational Layer entries:

- Reserve duty: `RSV-A`, `RSV-B`, `RSV-C`, `RSV-D`
- Long Call-out: `LCO`
- Reschedule Call-In Duty: `RCID`

All duty windows below are expressed in **LDT**: Local Domicile Time at the pilot's base.

## Time Conversion Notes

When converting LDT to Z time for the listed 2025-2026 season:

| Domicile | DST offset | Standard offset |
| --- | --- | --- |
| `ANC` | LDT + 8 hours | LDT + 9 hours |
| `SDF` | LDT + 4 hours | LDT + 5 hours |
| `SDFZ` | LDT + 4 hours | LDT + 5 hours |
| `ONT` | LDT + 7 hours | LDT + 8 hours |
| `MIA` | LDT + 4 hours | LDT + 5 hours |

DST interval:

- DST begins at `0200 LDT` on `2025-03-09`.
- Standard time begins at `0200 LDT` on `2025-11-02`.
- Standard time continues until `0200 LDT` on `2026-03-08`.

Implementation note: do not hard-code these offsets as a general date engine. Use the domicile timezone when possible, and treat this table as the operational reference for call-out windows and expected Z-time conversion behavior.

## ANC Base

All times are in `ANC` LDT.

| Code | LDT window |
| --- | --- |
| `RSV-A` | `0730 - 1929` |
| `RSV-B` | `0300 - 1459` |
| `RSV-C` | `2015 - 0814` |
| `RSV-D` | `1545 - 0344` |

## SDF / SDFZ Base

All times are in `SDF` / `SDFZ` LDT.

| Code | LDT window |
| --- | --- |
| `RSV-A` | `0000 - 1159` |
| `RSV-B` | `1200 - 2359` |
| `RSV-C` | `1600 - 0359` |
| `RSV-D` | `0400 - 1559` |

## ONT Base

All times are in `ONT` LDT.

| Code | LDT window |
| --- | --- |
| `RSV-A` | `2300 - 1059` |
| `RSV-B` | `1200 - 2359` |
| `RSV-C` | `1559 - 0358` |
| `RSV-D` | `0400 - 1559` |

## MIA Base

All times are in `MIA` LDT.

| Code | LDT window |
| --- | --- |
| `RSV-C` | `1600 - 0359` |
| `RSV-D` | `0500 - 1659` |

## Other Manual Operational Duty Windows

All times are in LDT for the user's selected domicile.

| Code | Meaning | LDT window |
| --- | --- | --- |
| `RCID` | Reschedule Call-In Duty | `0900 - 1300` |
| `LCO` | Long Call-out | `0800 - 1400` |

## Calendar Layer Placement

These items belong to the iPad Calendar **Operational Layer**, alongside trip bars and training events. They should render as operational schedule content, not as Bid Layer or Financial Layer events.

## Related

- `docs/BID_PERIODS.md` — BP/PP boundary rules and domicile LDT behavior.
- `DomicileSupport.swift` — domicile-to-timezone mapping.
- `iPadBidPeriodCalendarView.swift` — current layered iPad calendar rendering.
