# ADR-004: Schedule-based Home Widget State and Live Activity Removal

**Status:** Accepted; amended 2026-08-31 by Product Owner decision
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

### 1. Use one always-operational Widget state model

The Home Screen Widget uses one shared `HomeWidgetDomain` with three explicit projection states:

```text
nextTripReport
activeTripNextFlight
activeTripFinalLeg
```

Before report time it selects the earliest future Trip report. At report-time equality the Trip is
active and it selects the first scheduled flight whose `STD > now`. At each STD equality that leg
is no longer “next”, so selection advances immediately. The former T-12h through T-6h Home Widget
window and STD+61 current-leg presentation are retired from this Widget path.

Small and Medium receive the same `HomeWidgetPresentation`; SwiftUI views do not select a
Trip or leg.

### 2. Use scheduled absolute instants and explicit airport timezones

The Widget schedule projection derives from:

- Trip report time for the first valid domicile departure;
- each flight's planned STD and STA;
- the final flight's planned STA plus 30 minutes;
- injected or current `nowUTC`.

ATD, ATA, display-effective `depUTC` / `arrUTC`, device timezone, and formatted clock text do not
determine Widget state. Departure LCL uses the departure-airport timezone, arrival LCL uses the
arrival-airport timezone, and UTC formats the same absolute `Date`.

Missing planned endpoints or timezones fail closed for that projected leg and are diagnosed. Trip
completion is separate from renderability: after at least one leg projects, release uses the last
source flight in canonical sequence whose planned arrival parses, even if that source leg cannot
project because its airport timezone is unresolved. If later source flights have no parseable
arrival, release falls back in source order to the last parseable source arrival, then to the last
valid projected arrival only when necessary. Trips with no projected legs are excluded, and
nil-release input Trips are ineligible rather than active forever. No release time is invented.

### 3. Keep the final Trip active through final STA+30

At the final leg's STD there is no following flight. Until final planned arrival plus 30 minutes,
the Widget retains the final leg with neutral `TRIP IN PROGRESS` copy. It does not create a fake
next leg, resurrect report time, or show the following Trip prematurely.

The exact family presentation is:

- Small: final flight number, the compact DEP/airplane/ARR route-time grid carrying departure and
  arrival `(L)`/`(Z)`, and `TRIP IN PROGRESS`.
- Medium: flight number, the DEP/airplane/ARR route-time grid carrying both departure and
  arrival `(L)`/`(Z)`, plus optional destination layover/weather enrichment.

Large was withdrawn as a product decision; only Small and Medium are supported families.

At release-boundary equality, the next future Trip report becomes eligible.

### 4. Publish one schedule projection and enrich weather in the Widget provider

The app publishes a compact multi-Trip `HomeWidgetScheduleSnapshot` through the existing App Group
file and `FlightCountdownCoordinator`. Reconcile publishes normally; Trip Replacement performs
clear-then-publish. The Widget provider evaluates the shared domain and emits at most 12 entries
within a rolling 48-hour horizon, beginning with the current state and then the immediate report,
STD, and final STA+30 boundaries in that window. The 30-minute reload policy rematerializes later
boundaries before they become current. WidgetKit owns actual redraw timing, but reevaluation at or
after a boundary deterministically produces the later state.

Weather is optional, Medium-only enrichment performed by the Widget TimelineProvider, never a view
body or the host app. Each `getTimeline` invocation enriches only the current/first entry, for a
hard maximum of one WeatherKit enrichment; later complete operational entries carry nil weather
until a periodic reload makes them current. It queries WeatherKit hourly data around scheduled
arrival and selects the hour nearest that arrival. Arrivals outside WeatherKit's 10-day hourly
horizon, request failures, or empty forecasts yield no weather without removing flight data.
Successful values are cached briefly in memory and reduced to destination, forecast hour, SF
Symbol name, and Celsius temperature.

Arrival coordinates are a checked-in projection for every airport already supported by
`IATATimeZoneResolver`, generated from the pinned public-domain OurAirports dataset commit
`9e51f13487de777bdc473a37d271981a2d0b30ca`; PBI uses that dataset's KPBI coordinates. No current
location or per-refresh geocoding is used.

Only the Widget extension carries `com.apple.developer.weatherkit`. Weather presentation requires
`WeatherService.attribution`: the provider downloads Apple's combined light- and dark-appearance
Weather marks and stores them with Apple's legal-page URL in the timeline entry so the Widget can
match the active system appearance. The Medium Widget renders the matching mark as
a `Link`; if attribution is unavailable, weather itself is suppressed. The operational state is
still rendered.

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

- The Home Screen Widget now remains useful before report, throughout a Trip, and through final
  STA+30; all three supported families share exact boundary behavior.
- WeatherKit provisioning for the Widget extension must be enabled for the production App ID and
  confirmed in the distribution profile before release signing/archive validation.
- Issues 2, 3, 4, 5, 6, 7, and 9 are resolved by feature removal.
- Issue 1 remains resolved by the Timeline corrective implementation.
- Issue 8 remains deferred with root cause open; import, persistence, sync, cache, render identity,
  and scroll/focus paths are outside this decision.
- Existing Live Activities installed by an older build are not managed by the new production code;
  the new build contains no request/update/end runtime path for this feature.
- The Widget Extension target, App Group entitlement, snapshot file, and WidgetCenter reload remain
  because the redesigned Home Screen Widget uses them.

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
