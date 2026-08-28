# ADR-004: Schedule-based Flight Operational State and Live Activity Removal

**Status:** Accepted; amended 2026-08-28 by Product Owner decision
**Scope:** Flight operational domain, Home Screen Widget snapshot, report notifications, Timeline separation

## Context

TripDataHub derives flight countdown information from CrewAccess scheduled data. Actual departure
and arrival values are historical data and are not a reliable realtime source. All operational
calculations therefore use absolute scheduled `Date` instants.

The former Flight Countdown Live Activity displayed this data on the Lock Screen and Dynamic
Island. Its local-only ActivityKit owner could run only when the app received an execution
opportunity. It could not guarantee the required user-visible lifetime:

```text
Scheduled Departure Time + 60 minutes
-> departure status is no longer visible
```

`staleDate`, `context.isStale`, system date/timer formatting, timer clamping, foreground
reconciliation, and local boundary tasks do not constitute a guaranteed Activity update or end.
The product requirement was not weakened, and APNs/server/BGTask infrastructure was not added.

## Decision

### 1. Keep the four-state schedule model

`FlightOperationalState` remains:

```text
preReport
preDeparture
departureTimePassed
expired
```

Evaluation order is exact:

```text
now >= STD + 61 minutes -> expired
now >= STD              -> departureTimePassed
now < reportTime        -> preReport
otherwise               -> preDeparture
```

Equality belongs to the later state. The interval through STD+60:59 remains
`departureTimePassed`; STD+61:00 is `expired`.

### 2. Keep schedule-only inputs and absolute time

Operational state and current-leg selection are derived from:

- required `plannedDepartureUTC`;
- optional trip-level `reportTimeUTC`;
- injected or current `nowUTC`.

`plannedArrivalUTC` may be carried as route display metadata. STA, ATD, ATA, `depUTC`, and
`arrUTC` do not determine realtime state. Timezone changes affect formatting, not the underlying
instant or duration.

Report time applies only to the first valid domicile departure in a Trip. Later legs do not
re-enter `.preReport`.

The Home Screen Widget countdown presentation is a separate optional projection. It exists only
for `.preReport` and `.preDeparture`; `.departureTimePassed` remains a domain/selection state and
has no visible post-STD countdown presentation contract.

### 3. Keep deterministic current-leg selection

A non-expired `.departureTimePassed` leg owns selection through STD+60:59. At STD+61 it becomes
ineligible and the earliest valid future leg may take over. Operating and deadhead flights use the
same state rules. Missing required planned inputs fail closed and are diagnosed; no timestamp is
invented.

### 4. Keep the Home Screen Widget as a separate WidgetKit feature

The Widget Extension target remains because it owns the Home Screen Widget. The app publishes its
snapshot through `FlightCountdownCoordinator`, which now has only a snapshot client and no
ActivityKit dependency.

Home Screen Widget visibility remains T-12h through T-6h. Outside that interval it is explicitly
`.hidden`. Launch, active-scene, schedule-revision, and boundary refresh paths remain because they
also maintain this Widget snapshot. Replacement uses clear-then-publish semantics for the snapshot.

The shared operational state, engine, snapshot, timezone formatting, and pre-STD Home Widget
countdown presentation remain domain/Widget code. A snapshot may therefore carry the selected
`.departureTimePassed` domain state with no presentation. Live Activity attributes, ContentState,
expanded layout, post-STD elapsed presentation, stale metadata, and Activity clients were removed.

### 5. Remove Flight Countdown Live Activities completely

TripDataHub provides no Flight Countdown:

- Lock Screen Live Activity;
- Dynamic Island compact presentation;
- Dynamic Island minimal presentation;
- Dynamic Island expanded presentation.

There is no production Flight Countdown path that calls `Activity.request`, `activity.update`, or
`activity.end`. The app and Widget extension no longer declare `NSSupportsLiveActivities` for this
feature, and production sources do not import ActivityKit.

This is a product/architecture decision, not a claim that iOS contains a bug. Reintroducing Flight
Countdown Live Activities requires a new Product Owner decision and an architecture that can prove
the STD+60 user-visible expiration requirement. Merely restoring local lifecycle workarounds is
forbidden.

### 6. Keep Timeline and notifications independent

48h and 24h Report Notifications and standard local notifications remain owned by
`NextReportNotificationService` and their existing scheduling preferences.

Timeline Top remains governed by INV-020:

```text
now < reportTime
-> current Trip report visible

reportTime <= now < final scheduled flight arrival + 30 minutes
-> NEXT REPORT hidden

now >= final scheduled flight arrival + 30 minutes
-> next future Trip report eligible
```

Commercial deadhead flights count, `GND` rows do not, foreign-ending Trips are valid, and a missing
final scheduled arrival suppresses conservatively without inventing a release time.

## Consequences

- Issues 2, 3, 4, 5, 6, 7, and 9 are resolved by feature removal.
- Issue 1 remains resolved by the Timeline corrective implementation.
- Issue 8 remains deferred with root cause open; import, persistence, sync, cache, render identity,
  and scroll/focus paths are outside this decision.
- Existing Live Activities installed by an older build are not managed by the new production code;
  the new build contains no request/update/end runtime path for this feature.
- The Widget Extension target, App Group entitlement, snapshot file, and WidgetCenter reload remain
  because the Home Screen Widget still uses them.

## Rejected Alternatives

### Weaken the expiration requirement

Rejected. The feature was removed instead.

### Add APNs, server, or BGTask infrastructure in this round

Rejected by product scope.

### Retry staleDate, context.isStale, DateReference, timer clamp, or local lifecycle scheduling

Rejected because these mechanisms do not prove the required user-visible expiration.

## Related

- `docs/INVARIANTS.md` — INV-013 through INV-021
- `docs/SWE_INSTRUCTION_LIVE_ACTIVITY_LAYOUT_V2.md` — retired historical instruction
- `docs/DEVICE_VERIFICATION_CHECKLIST.md` — retired Live Activity acceptance evidence
- `docs/FOLLOW_UPS.md` — retired Live Activity follow-ups
