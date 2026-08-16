# ADR-004: Separate Flight Operational State from Presentation Policy

**Status:** Accepted
**Date:** 2026-08-15
**Implementation status:** Phase 1 state/countdown engine implemented; replacement and lifecycle work remains in Phases 2 and 3.

## Context

TripDataHub currently uses one STD-relative presentation phase as both a visibility policy and a proxy for flight state. The phase moves from Widget to Live Activity, then to `liveDelayed`, and finally to `finished` using T-12h, T-6h, and STD+6h constants. It has no STA, ATD, or ATA input. As a result, a passed schedule time can be presented as an Actual operational event, a completed leg can be selected again, and a future leg can displace a leg that is still the relevant arrival-side operation.

The countdown conversion also reads `TripLeg.depUTC` and `arrUTC`, whose display/history resolution may prefer Actual values. INV-012 defines planning as a separate question. Countdown targets and operational decisions must not move merely because an Actual display value was observed.

Trip Replacement adds a related lifecycle problem. Widget snapshots, notifications, current-leg selection, and Live Activities are derived along separate paths. A revised persisted trip can therefore coexist with artifacts derived from an obsolete revision. At the same time, unconditionally ending and recreating Live Activities during ordinary refresh would introduce flicker and consume ActivityKit request budget.

The product principle is:

> Incorrect operational information is worse than no information.

## Decision

### 1. Use absolute instants and separate time meanings

Operational state and countdown duration use only these inputs:

- `plannedDepartureUTC` and `plannedArrivalUTC` for schedule/planning instants;
- optional `atdUTC` and `ataUTC` for observed Actual events;
- optional trip-level `reportTimeUTC`, supplied only to the first domicile-departure leg.

Duration is always `target.timeIntervalSince(now)`. Device timezone, `Calendar`, and wall-clock `DateComponents` are not duration inputs. `depUTC` and `arrUTC` remain display/history values and are not read directly by the countdown engine or operational-state builder.

Timezone is applied only while rendering a reference timestamp or interpreting an explicit domain boundary. The Timeline LCL/UTC preference may change the scheduled-arrival reference line, but it cannot change elapsed or remaining duration.

### 2. Separate Operational State from Presentation Policy

`FlightOperationalState` answers what can safely be said about a leg. Presentation Policy answers whether and where that state should be visible.

T-12h, T-6h, and other visibility windows exist only in Presentation Policy. They are not state-machine inputs. “Too early to display” is therefore not an operational state, and `.preTrip` is not introduced.

### 3. Define exactly seven operational states

The state model contains:

| State | Meaning |
| --- | --- |
| `.preReport` | First domicile-departure leg before its known trip report time |
| `.postReportPreDeparture` | STD is still in the future and no pre-report condition applies |
| `.scheduledDeparturePassed` | STD passed, ATD is unobserved, and STA has not passed |
| `.inFlight` | ATD observed, ATA unobserved, and current time is before STA |
| `.scheduledArrivalPassed` | STA reached, ATA unobserved, and STA+1h not reached; ATD may be present or absent |
| `.completed` | ATA observed |
| `.stale` | STA+1h reached with ATA still unobserved |

There is no `.unknown` state. Two situations that were previously described as “unknown” have different handling:

- When schedule instants are known but Actual events are unobserved, `.scheduledDeparturePassed` and `.scheduledArrivalPassed` communicate only the schedule fact.
- When a required planning instant or presentation timezone cannot be resolved, no state or presentation payload is created for that leg. It is excluded from current-leg selection, selection continues, and a reason-coded event is recorded through `SyncDiagnosticsLog`. No operational error banner is shown.

No missing instant or timezone is replaced with a default.

### 4. Make evaluation order part of the contract

The evaluator applies these rules from top to bottom and returns the first match:

1. `ataUTC != nil` → `.completed`
2. `ataUTC == nil && now >= plannedArrivalUTC + 1h` → `.stale`
3. `ataUTC == nil && now >= plannedArrivalUTC` → `.scheduledArrivalPassed`
4. `atdUTC != nil && now < plannedArrivalUTC` → `.inFlight`
5. `now >= plannedDepartureUTC` → `.scheduledDeparturePassed`
6. `reportTimeUTC != nil && now < reportTimeUTC` → `.preReport`
7. otherwise, while before STD → `.postReportPreDeparture`

Equality belongs to the later state: at STA the state is `.scheduledArrivalPassed`; at STA+1h it is `.stale`. STA checks precede `.inFlight`, including when ATD is known. This order prevents arrival-passed and stale states from becoming unreachable.

`.inFlight` has exactly one evidence source in this Build: an observed ATD. Time passage, next-leg existence, connection feasibility, device location, and other indirect signals do not establish airborne status. ATD also does not establish that the aircraft remains airborne at or after STA.

ATA is the only evidence that creates `.completed`. No elapsed-time rule creates `Delayed`, `Departed`, or `Completed`.

### 5. Apply report time only to the trip's first domicile departure

Report time is a trip property. Only the first domicile-departure leg can receive a non-nil `reportTimeUTC` and become `.preReport`. Subsequent legs receive no report time and, while before STD, are `.postReportPreDeparture`. If report time cannot be calculated, `.preReport` is not inferred.

The product rule for report lead time is:

- Lower 48 origin and Lower 48 destination: STD minus 1 hour;
- Alaska, Hawaii, an unclassified airport, or any other combination: STD minus 1 hour 30 minutes.

Asia and Europe regional rules are outside this Build. The authoritative Lower 48 airport-data source remains a PM decision; this ADR does not select one.

### 6. Use one status contract on every surface

Every surface consumes the same presentation payload. The state-to-copy contract is:

| State | Status line | Reference line |
| --- | --- | --- |
| `.preReport` | `Report in HHhr MMmin` | none |
| `.postReportPreDeparture` | `Dep in HHhr MMmin` | none |
| `.scheduledDeparturePassed` | `Scheduled Departure Time Passed` | none |
| `.inFlight` | `Arriving in HHhr MMmin` | none |
| `.scheduledArrivalPassed` | `Scheduled Arrival Time Passed HHhr MMmin` | `Scheduled Arrival: HH:MM LCL` or `Scheduled Arrival: HH:MM UTC` |
| `.completed` | no presentation | none |
| `.stale` | no presentation | none |

`Arriving in` is a schedule-based countdown, not a real-time ETA, and exists only before STA. A zero or negative value indicates a state-machine defect; it is not clamped with `max(0, ...)`.

For `.scheduledArrivalPassed`, the status line is the absolute elapsed duration since planned arrival. The reference line uses the planned arrival instant, including a revision when present. LCL uses the arrival airport timezone; UTC mode uses UTC. Compact surfaces may omit the reference line but do not invent different status copy.

Operating flights and Commercial Deadhead legs use the same state evaluator and duration path. Deadhead is presentation metadata only.

### 7. Select one current leg from valid evaluated states

The single builder evaluates valid legs, then selects the first applicable category in this order:

1. `.inFlight`; if multiple exist, choose the latest STD
2. `.scheduledArrivalPassed`; if multiple exist, choose the latest STD
3. `.scheduledDeparturePassed`; if multiple exist, choose the latest STD
4. `.postReportPreDeparture` or `.preReport`; choose the earliest STD

`.completed`, `.stale`, and input-insufficient legs are excluded. An input-insufficient exclusion is logged before selection continues. When no candidate remains, the builder returns a nil presentation payload, which ends relevant Activity presentation and removes the Widget snapshot.

Arrival-side present operations therefore outrank future departure-side legs. The current persisted trip revision is the only schedule source from which the builder derives candidates.

The latest-STD tie-break for multiple arrival-passed or departure-passed candidates selects the most recent operation. This ordering is deterministic and is part of the accepted current-leg contract.

### 8. Derive every operational surface from one builder

One operational-state builder produces the presentation payload consumed by:

- Dynamic Island;
- Lock Screen Live Activity;
- Home Screen Widget snapshot;
- notification scheduling;
- app Timeline operational presentation;
- app-launch reconstruction and current/next-leg cache.

These consumers do not independently decide flight state. This requirement does not replace INV-006 through INV-008: the CrewAccess JSON remains the recoverable source, and existing fail-closed import, rollback, CloudKit transaction, and tombstone boundaries remain authoritative.

### 9. Use explicit reconcile and destructive-rebuild lifecycle modes

The Live Activity coordinator accepts an explicit caller-selected mode:

- `reconcile` is normal operation. If the current leg remains the same, a state transition updates the existing Activity. If the current leg changes, the old Activity ends and the new current leg may create one. If no current leg remains, the Activity ends and the snapshot is removed.
- `destructiveRebuild` is exclusive to a successful Trip Revision or Replacement. It cancels old derived notifications, ends all existing countdown Activities without relying on leg identity, removes the App Group snapshot and current/next cache, persists the revised trip, recalculates state, and creates only the derived artifacts justified by the revised source.

Launch, scene activation, periodic/boundary refresh, and same-leg transitions never request `destructiveRebuild`. The coordinator does not infer the mode. A coordinator-owned, one-time population barrier is shared by every refresh entry point, so concurrent launch and scene-activation reconciliations cannot mistake unpopulated ActivityKit runtime state for an empty set.

## Consequences

- Operational claims become evidence-based and fail closed when inputs are insufficient.
- `.scheduledArrivalPassed` and `.stale` remain reachable for ATD-known as well as ATD-unknown legs.
- A future leg cannot displace the current arrival-side operation merely because it entered a UI visibility window.
- All surfaces use one state and copy contract; inconsistent surface-specific flight conclusions are defects.
- Replacement deliberately incurs a full derived-state teardown, while ordinary refresh preserves the same Activity when the leg identity is stable.
- Input-insufficient legs produce diagnostics without distracting the operating user with an error banner.
- Existing `TripDataHubTests/FlightCountdownTests.swift` phase tests encode the rejected STD-relative state model, including `.liveDelayed` and `.finished`. Phase 1 intentionally deletes or rewrites those tests. QA must treat that test removal as an approved specification change, not as lost regression coverage; T-1 through T-24 replace it with operational-state, lifecycle, timezone, presentation-window independence, report-policy consistency, and reconstruction coverage.
- Phase 1 implements the state evaluator, presentation policy, current-leg selection, shared countdown payload, report-time rule, and their applicable T-xx regressions. Phase 2 makes replacement a single import transaction and adds one injected, awaited, best-effort, timeout-bounded invalidation seam after durable verification. Phase 3 implements caller-selected reconcile/destructive-rebuild modes, awaited startup Activity enumeration, boundary-driven reevaluation, and replacement teardown behind that seam.

## Alternatives Rejected

### Rename `Delayed` without changing the state model

Rejected because the STD-only phase would still select completed legs, displace in-flight legs, and fabricate completion after a fixed interval.

### Keep one enum for visibility and operational state

Rejected because surface windows and flight facts answer different questions and change for different reasons.

### Add an `.unknown` operational state

Rejected because an input-insufficient leg would become selectable and acquire user-facing copy. Excluding and logging it is safer.

### Infer airborne or completed state from elapsed schedule time

Rejected because a schedule instant is not evidence that an Actual event occurred.

### Recreate every Live Activity on refresh

Rejected because it produces visual churn, consumes ActivityKit request budget, and obscures the semantic difference between ordinary reconciliation and replacement invalidation.

### Patch an existing Activity through Trip Replacement

Rejected because an obsolete leg or revision can survive. Replacement requires teardown followed by derivation from the newly persisted source.

## Related

- `docs/INVARIANTS.md` — INV-001, INV-002, INV-006 through INV-008, and INV-012 through INV-018.
- `docs/BUILD_WEEK_TDH_RELIABILITY_SWE_INSTRUCTION.md` — authoritative T-1 through T-24 definitions and phased acceptance requirements.
- `docs/ADR/ADR-002-utc-source-of-truth.md`.
- `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`.
- `TripDataHub/Models/FlightOperationalState.swift`, `FlightCountdownSharedModels.swift`, and `FlightCountdownSupport.swift` — Phase 1 state and presentation implementation.
- `TripDataHub/Services/FlightCountdownCoordinator.swift` — explicit reconcile/destructive-rebuild lifecycle implementation.
- `TripDataHubTests/FlightCountdownTests.swift` — Phase 1 operational-state regression coverage replacing the former STD-relative phase tests.

## Reconsider When

- The product accepts a new non-ATD evidence source for in-flight status through a separate Build and ADR.
- A trustworthy real-time ETA source replaces schedule-based arrival countdown.
- Report-time policy expands to additional regions after PM defines the airport classification source.
- ActivityKit exposes a stronger lifecycle or restoration primitive that changes reconciliation requirements.
