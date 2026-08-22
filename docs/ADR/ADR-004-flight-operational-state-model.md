# ADR-004: Separate Flight Operational Countdown from Actual Flight History

**Status:** Accepted — revised by Product Owner
**Original date:** 2026-08-15
**Revised date:** 2026-08-19
**Implementation status:** Four-state contract implemented; local-only Activity lifecycle limitation and bounded elapsed presentation approved.

## Context

The original ADR-004 defined a seven-state real-time operational model using planned departure and arrival, observed ATD and ATA, and report time. That model expected `Arriving in`, scheduled-arrival-passed, and Actual-completed states to be available during operation.

Product experience established that CrewAccess Actual data is commonly imported only after a trip finishes. TripDataHub therefore has no trustworthy real-time ATD or ATA source. Keeping the former model would force the product either to leave arrival states unavailable in normal operation or to infer `Departed`, `In flight`, `Arrived`, or `Completed` from schedule passage.

The product principle remains:

> Incorrect operational information is worse than no information.

STD passage is a known schedule fact. It is safe to say that departure time has passed. It is not safe to say that the aircraft departed, is airborne, arrived, or completed its leg.

Actual ATD and ATA remain valuable historical data under INV-012. This ADR changes only the real-time operational countdown and its presentation.

## Decision

### 1. Use a four-state STD-centred model

The model has three visible states and one non-presenting terminal state:

| State | Meaning |
| --- | --- |
| `.preReport` | The first domicile-departure leg is before its known report time |
| `.preDeparture` | STD is in the future and no pre-report condition applies |
| `.departureTimePassed` | STD has passed, but STD+61 minutes has not been reached |
| `.expired` | STD+61 minutes has been reached; this leg produces no operational countdown |

The old `.inFlight`, `.scheduledArrivalPassed`, `.completed`, and STA-based `.stale` real-time states are retired. They MUST NOT remain as aliases or surface-specific presentation states.

There is no `.unknown` state. A leg missing a required planning input is excluded with a reason-coded diagnostic. It does not receive a default instant or user-facing operational error state.

### 2. Restrict operational inputs to STD, report time, and now

The evaluator accepts only:

- required `plannedDepartureUTC` (STD);
- optional trip-level `reportTimeUTC`;
- `nowUTC`.

`plannedArrivalUTC` may remain in the shared payload solely to render route date and time. STA is not a state boundary, countdown target, selection input, or Activity lifecycle boundary.

`atdUTC`, `ataUTC`, `depUTC`, and `arrUTC` MUST NOT enter the operational evaluator, current-leg selector, boundary scheduler, operational status descriptor, or Activity lifecycle decision. Invalid or missing Actual data does not make an otherwise valid planned-departure countdown ineligible.

Duration and elapsed calculations are absolute UTC `Date` differences. Device timezone, `Calendar.current`, and wall-clock `DateComponents` are not duration inputs.

### 3. Make the exact evaluation order a contract

Let `STD` be `plannedDepartureUTC` and let `expiry` be exactly `STD + 61 minutes`. The evaluator applies these rules from top to bottom and returns the first match:

1. `nowUTC >= expiry` → `.expired`
2. `nowUTC >= STD` → `.departureTimePassed`
3. `reportTimeUTC != nil && nowUTC < reportTimeUTC` → `.preReport`
4. otherwise, while before STD → `.preDeparture`

Equality belongs to the later state:

| Instant | Result |
| --- | --- |
| `now == reportTimeUTC` | `.preDeparture` |
| `now == STD` | `.departureTimePassed`, elapsed minute 0 |
| `STD+60:00 ... STD+60:59` | `.departureTimePassed`, elapsed minute 60 |
| `now == STD+61:00` | `.expired` |

Elapsed whole minutes are `floor((nowUTC - plannedDepartureUTC) / 60)`. A negative elapsed value inside `.departureTimePassed` is an evaluator defect and is not clamped.

### 4. Apply report time to one leg only

Only the trip's first domicile-departure leg may receive a non-nil `reportTimeUTC` and become `.preReport`. Every subsequent leg receives nil report time and is `.preDeparture` while before STD. If the first domicile departure or its report time cannot be resolved, `.preReport` is not inferred; the valid leg uses `.preDeparture`.

The report lead-time product rule remains:

- Lower 48 origin and Lower 48 destination: STD minus 1 hour;
- Alaska, Hawaii, an unclassified airport, or any other combination: STD minus 1 hour 30 minutes.

The lead-time function remains single-source across report-window and Timeline duty-start consumers.

### 5. Use one semantic status contract

Every operational surface consumes the same structured status descriptor:

| State | Descriptor | Prefix / semantic meaning | Anchor |
| --- | --- | --- | --- |
| `.preReport` | report countdown | `Report in` | `reportTimeUTC` |
| `.preDeparture` | departure countdown | `Dep in` | `plannedDepartureUTC` |
| `.departureTimePassed` | departure elapsed | `Departure time passed` | `plannedDepartureUTC` |
| `.expired` | none | no operational presentation | none |

The descriptor, anchor UTC instant, state, leg identity, operational expiration instant, and any presentation-only timer clamp instant are common. Layout, font, and compactness may differ by surface; operational meaning may not.

Live Activity and Widget countdown or elapsed values use OS-driven dynamic time rendering. For departure elapsed, `SystemFormatStyle.Timer` localization such as `14 minutes` is accepted. The exact `XX min` spelling is not a product requirement. The prefix and semantic meaning are the common contract. The count-up range is bounded by the presentation-only `timerClampUTC = STD + 60 minutes`, so a retained Activity shell never advances beyond 60 minutes. `expirationUTC = STD + 61 minutes` remains a distinct evaluator and lifecycle boundary. Manual per-minute `Activity.update()`, a Swift timer, or polling solely to format the duration is forbidden.

The old `Arriving in`, `Scheduled Arrival Time Passed`, arrival reference line, and all STA-based operational copy are retired.

### 6. Derive every operational surface from one builder

One builder produces a structured operational presentation containing at least:

- trip and leg identity;
- the four-state result;
- semantic status descriptor;
- anchor UTC instant;
- optional `expirationUTC = STD + 61 minutes` operational expiration;
- optional `timerClampUTC = STD + 60 minutes` departure-elapsed presentation clamp;
- planned route/date/time metadata needed by the layout;
- Presentation Policy visibility.

The following are consumers of that output and do not re-decide state:

- app Timeline on iPhone;
- app Timeline on iPad;
- Lock Screen Live Activity;
- Dynamic Island;
- Home Screen Widget snapshot;
- operational notification scheduling;
- app-launch reconstruction and current-leg cache.

The old app Timeline `(-05d 15h 45m)` calculation and any independent surface-specific countdown meaning are retired. Equivalent iPhone and iPad surfaces remain subject to INV-005.

Presentation Policy remains separate. T-12h, T-6h, and other visibility windows determine where a valid state is shown; they do not enter the state evaluator.

### 7. Select the current leg deterministically

Selection uses evaluated schedule states only:

1. If one or more legs are `.departureTimePassed`, select the leg with the latest STD.
2. Otherwise select the `.preReport` or `.preDeparture` leg with the earliest STD.
3. Exclude `.expired` and input-insufficient legs.

A selected `.departureTimePassed` leg remains current through elapsed minute 60. At STD+61 it becomes `.expired`, is removed, and selection advances to the next valid leg. This priority is deliberate even when it shortens or eliminates the next leg's pre-departure countdown during a short turn.

### 8. Reconcile at report, STD, and STD+61 boundaries

Boundary-driven reevaluation uses report time, STD, STD+61, and Presentation Policy visibility boundaries. STA and STA+1h are removed. Minute polling is not introduced. In the local-only architecture, this scheduler is best-effort while the process is suspended or terminated; it is not an exact background wake guarantee.

Normal `reconcile` updates the same Activity through `.preReport`, `.preDeparture`, and `.departureTimePassed`. Whenever execution reaches reconciliation at or after STD+61, it immediately ends the expired Activity and removes the snapshot unless a newly selected leg justifies an update or replacement Activity. A current-leg identity change ends the old Activity and may request one new Activity. If the app is suspended or terminated at the boundary, the Activity shell may remain until the next available app execution; exact dismissal at STD+61 is not guaranteed without a server-side Activity end.

`destructiveRebuild` remains exclusive to successful Trip Revision or Replacement and retains its existing teardown and rebuild contract.

The Activity stale boundary for an active operational countdown is `plannedDepartureUTC + 61 minutes`, not planned arrival plus one hour. `staleDate` is metadata and MUST NOT be described as a dismissal guarantee. While a shell remains, the system timer is bounded by `timerClampUTC = plannedDepartureUTC + 60 minutes` and remains visibly clamped at 60 minutes.

### 9. Keep Actual data on the history side of the boundary

CrewAccess parsing, canonical JSON, CloudKit/import persistence, `TripLeg` Actual fields, Leg History, and historical Timeline rendering retain ATD and ATA. `TripLeg.depUTC` and `arrUTC` may continue to answer the historical/display question defined by INV-012.

Two legs that differ only in ATD or ATA MUST produce identical real-time operational state, status descriptor, selection result, and Activity lifecycle decision.

### 10. Fail closed while migrating persisted derived state

Old encoded Actual/arrival-driven states must not survive as operational claims after upgrade. Legacy `.inFlight`, `.scheduledArrivalPassed`, `.completed`, and STA-based `.stale` values decode or migrate to a non-presenting result and are rebuilt from current planned schedule data.

Legacy scheduled-departure-passed data is re-evaluated against STD and STD+61. Decode failure never preserves old arrival copy. Launch reconciliation ends obsolete Activities and removes obsolete snapshots before publishing the new builder result.

## Consequences

- The product no longer presents an unsupported real-time arrival or Actual state.
- `Departure time passed` communicates a schedule fact, not a claim that the aircraft departed.
- Planned arrival remains available for route display, but no longer drives state, selection, status, or lifecycle.
- A passed leg deliberately owns the operational presentation through minute 60; a short turn may have little or no `Dep in` presentation for its next leg.
- Operational expiration (`STD+61`) and visible timer clamping (`STD+60`) are separate contracts. A suspended Activity may remain temporarily, but its visible elapsed value stops at 60 minutes and the next reconciliation ends it.
- App Timeline, Widget, and Live Activity must migrate together because a surface-specific fallback would recreate contradictory operational meaning.
- Device rendering acceptance remains necessary for OS-driven timer output; source-level tests protect syntax and semantic anchors but do not inspect SpringBoard pixels.
- The original seven-state arrival/Actual-driven contract and its arrival-side T-xx assertions are retired by Product Owner decision, not lost coverage.

## Alternatives Rejected

### Keep ATD/ATA states for the rare live import

Rejected because the product has no reliable real-time Actual delivery contract. A state that normally cannot be produced is not a dependable operational model.

### Infer departure or arrival from schedule passage

Rejected because schedule passage proves only that a scheduled instant passed.

### Keep the old arrival states but hide their copy

Rejected because selection, lifecycle, persisted snapshots, and surface builders would still contain unsupported operational meaning.

### Format elapsed minutes with manual updates

Rejected because background Activity updates are not reliable enough to make a formatting preference an operational dependency. OS-driven localized timer output is accepted instead.

### Guarantee exact local-only Activity dismissal at STD+61

Rejected because a suspended or terminated app has no guaranteed execution opportunity at the boundary. `staleDate` does not end an Activity. APNs/server-side Activity ending, BGTask boundary guarantees, and per-minute updates are outside this contract; the next app execution reconciles and ends the expired Activity.

### Let each surface adapt the old model independently

Rejected because the existing app Timeline versus Widget/Live Activity split already demonstrated that independent operational meanings drift.

## Related

- `docs/INVARIANTS.md` — INV-001, INV-002, INV-005, INV-012 through INV-019.
- `docs/BUILD_WEEK_TDH_RELIABILITY_SWE_INSTRUCTION.md` — authoritative revised T-1 through T-24 definitions.
- `docs/ADR/ADR-002-utc-source-of-truth.md`.
- `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`.

## Reconsider When

- The product gains a trustworthy, explicitly contracted real-time Actual or aircraft-state source.
- A future product decision changes the 60-minute departure-passed ownership window.
- ActivityKit exposes a new system-driven formatting primitive that can meet a stricter cross-locale copy contract without app-driven polling.
