# TripData Hub Calendar Tab Implementation Spec

This document consolidates the calendar planning notes into one repo-specific implementation design for **TripData Hub**.

It is intended to guide implementation of the **Calendar** tab without changing the app into a traditional month calendar.

---

## 1. Product Goal

The Calendar tab is a **pilot roster visualization** for one Bid Period.

It must:

- render a fixed **8-week Bid Period**
- start on **Sunday**
- show **56 day cells**
- render **horizontal trip bars** across days
- split bars across **days** and **weeks**
- support **tap -> Timeline highlight**

It must not become a generic month calendar.

---

## 2. V1 Scope

Build only:

- calendar grid for one Bid Period
- trip normalization from existing `TripLeg` data
- day segmentation
- week splitting
- simple lane allocation
- overlay rendering
- tap navigation to Timeline

Do not build:

- fatigue overlays
- trip editing
- drag and drop
- colleague calendar overlays
- real-time ops tracking
- month view

---

## 3. Existing Repo Constraints

TripData Hub does **not** store trips directly.

Current source data is:

- [`PayPeriodSchedule`](/Users/sfune/Desktop/work/ios-app/TripDataHub/TripDataHub/Models/TripModels.swift)
- [`TripLeg`](/Users/sfune/Desktop/work/ios-app/TripDataHub/TripDataHub/Models/TripModels.swift)

Relevant existing behavior:

- `pairing` already behaves like a trip identifier in Timeline
- Timeline already groups and navigates by trip-like identity
- airport timezone resolution already exists in [`IATATimeZoneResolver.swift`](/Users/sfune/Desktop/work/ios-app/TripDataHub/TripDataHub/Services/IATATimeZoneResolver.swift)

Because of this, Calendar must introduce a normalization layer before rendering.

---

## 4. Required Architecture

Calendar should be implemented in three layers:

1. `TripLeg -> CalendarTrip` normalization
2. `CalendarTrip -> CalendarSegment` rendering engine
3. SwiftUI grid + overlay + navigation interaction

Business logic must stay outside the SwiftUI layout layer.

### Required File Layout

The Calendar tab implementation must be kept concentrated in these files:

1. `TripDataHub/Models/CalendarModels.swift`
2. `TripDataHub/Services/BidPeriodService.swift`
3. `TripDataHub/Views/CalendarSupport.swift`
4. `TripDataHub/Views/CalendarTabView.swift`

Also update shared navigation state where `RootTabView` and Timeline tab state are managed.

Do not spread calendar engine logic into many unrelated files.

---

## 5. Source of Truth Rules

### 5.1 Time Rules

- **UTC** is the only source of truth for all calendar engine math
- **device timezone must never be used**
- **local airport time** is rendering metadata only

The following must use **UTC only**:

- trip normalization
- overlap checks
- Bid Period visibility
- segment ordering
- lane allocation
- geometry lifecycle decisions

The following may use **local airport time only**:

- choosing the visible calendar day column
- computing `startFraction`
- computing `endFraction`
- formatting displayed labels in the calendar UI

Non-negotiable rule:

- do not rewrite the calendar engine around local-time math
- do not move overlap math, ordering, or lane allocation to local time
- UTC ordering remains authoritative even when local displayed time appears to go backward

### 5.2 Bid Period Rules

Calendar renders exactly one Bid Period window:

- 8 weeks
- Sunday start
- 56 consecutive days

Bid Period boundaries must come from a formal Bid Period definition source, not inferred ad hoc from current schedules.

The existing Bid Period definitions in project instructions should be formalized into app data.

### 5.3 Trip Identity Rules

Calendar trip identity must align with Timeline trip identity.

For this repo, do **not** assume raw `pairing` is always globally unique.

Trip identity must be constructed explicitly as:

- `"\(payPeriod)|\(pairing)"`

If Timeline later centralizes a different effective trip identity rule, Calendar must use that same shared rule.

The selected Calendar trip must map cleanly to Timeline highlighting.

---

## 6. Proposed Data Model

These are the repo-specific conceptual models for Calendar.

```swift
struct CalendarBidPeriod {
    let id: String
    let startDateUTC: Date
    let endDateUTC: Date
    let days: [CalendarDay]
}

struct CalendarDay {
    let index: Int          // 0...55
    let weekIndex: Int      // 0...7
    let weekdayIndex: Int   // 0...6
    let dayStartUTC: Date
    let dayEndUTC: Date
    let displayDateKey: String
}

struct CalendarTrip {
    let id: String
    let pairing: String
    let payPeriod: String
    let legs: [TripLeg]
    let startUTC: Date
    let endUTC: Date
}

struct CalendarSegment {
    let tripID: String
    let weekIndex: Int
    let dayIndex: Int
    let segmentStartUTC: Date
    let startFraction: Double
    let endFraction: Double
    var lane: Int
    let hasLocalTimeRegression: Bool
    let regressedRange: ClosedRange<Double>?
}
```

Notes:

- `CalendarTrip` is a normalized rendering object, not a new storage type
- `CalendarSegment` is a rendering artifact only
- one trip may produce many segments
- `CalendarBidPeriod.endDateUTC` is an **exclusive** upper bound
- `CalendarDay.displayDateKey` is a UI convenience only
- `lane` is mutable because lane assignment happens after segmentation
- `hasLocalTimeRegression` and `regressedRange` are rendering metadata only, never ordering metadata
- `segmentStartUTC` is required for deterministic UTC-based sorting

### Model Placement

These models should live in:

- `TripDataHub/Models/CalendarModels.swift`

Required properties by model:

#### `CalendarBidPeriod`

- `id`
- `startDateUTC`
- `endDateUTC`
- `days`

#### `CalendarDay`

- `index`
- `weekIndex`
- `weekdayIndex`
- `dayStartUTC`
- `dayEndUTC`
- `displayDateKey`

`displayDateKey` may be used for:

- debugging
- logging
- optional display labels

It must not be used as the primary mechanism for:

- determining day ownership
- mapping UTC events to `dayIndex`

Format:

- `"YYYY-MM-DD"`

#### `CalendarTrip`

- `id`
- `pairing`
- `payPeriod`
- `legs`
- `startUTC`
- `endUTC`

#### `CalendarSegment`

- `tripID`
- `weekIndex`
- `dayIndex`
- `segmentStartUTC`
- `startFraction`
- `endFraction`
- `lane`
- `hasLocalTimeRegression`
- `regressedRange`

---

## 7. Normalization Step

This step is mandatory before segmentation.

### Input

- merged schedule source used for Timeline-like calendar display
- `TripLeg` values from current app data

### Output

- normalized `CalendarTrip` objects

### Rules

1. Group legs by effective trip identity using `"\(payPeriod)|\(pairing)"`
2. Sort legs inside each trip by UTC departure
3. Compute:
   - `startUTC` from earliest departure
   - `endUTC` from latest arrival
4. Exclude malformed trips that cannot produce valid UTC bounds

### Important

Do not build the calendar directly from raw `TripLeg`s.

---

## 8. Bid Period Day Generation

Calendar must generate 56 days from Bid Period start:

```swift
func generateBidPeriodDays(startUTC: Date) -> [CalendarDay]
```

For each day index `i` in `0..<56`:

- `weekIndex = i / 7`
- `weekdayIndex = i % 7`

`startUTC` is the first visible day at `00:00:00 UTC`.

`endDateUTC` is the **exclusive** upper bound:

- the start of day 57 at `00:00:00 UTC`

The generated day list is the only grid source of truth.

### Bid Period Service

Formal Bid Period support should live in:

- `TripDataHub/Services/BidPeriodService.swift`

Required functions:

```swift
func bidPeriod(for dateUTC: Date) -> CalendarBidPeriod?
func generateBidPeriodDays(startUTC: Date) -> [CalendarDay]
```

Implementation rules:

- `weekIndex = i / 7`
- `weekdayIndex = i % 7`
- `dayStartUTC` = start of UTC day
- `dayEndUTC` = next UTC midnight
- `CalendarBidPeriod.endDateUTC` must be exclusive

Important:

- `dayStartUTC` and `dayEndUTC` are Bid Period boundary helpers only
- they must not be used as the direct ownership rule for local rendered day placement

Do not infer Bid Period boundaries from trips.

Bid Periods must come from formal data.

---

## 9. Visible Trip Filtering

A trip is visible if it intersects the Bid Period window:

```swift
trip.startUTC < bidPeriod.endDateUTC
&&
trip.endUTC > bidPeriod.startDateUTC
```

This includes trips that start before the BP and end inside it, or start inside it and end after it.

---

## 10. Day Placement Rule

Calendar columns are **operational local-day columns**, not UTC-day columns.

Required interpretation:

- UTC determines:
  - whether a trip overlaps the visible BP range
  - trip ordering
  - segment ordering
  - lane allocation order
- local operational time determines only:
  - which visible calendar day column receives a rendered segment
  - `startFraction`
  - `endFraction`

Implementation must not use device timezone.

It must derive local time using airport timezone data already available in the app.

### Concrete Rendering Rule

The correct flow is:

`UTC Trip / UTC Bounds`
-> determine BP visibility in UTC
-> resolve local airport timezone for rendering boundary only
-> compute local day ownership
-> compute local `startFraction` / `endFraction`
-> render

### Boundary Ownership Rule

For v1, local day ownership must be determined only from structured local date-time components derived from:

- UTC timestamp
- resolved display timezone

Use clear names such as:

- `displayTimeZone`
- `localStartComponents`
- `localEndComponents`
- `hasLocalTimeRegression`
- `regressedRange`

Avoid vague names such as:

- `adjustedTime`
- `displayHack`
- `tempOffset`

Required helper:

```swift
func resolveDayIndex(
    for utcDate: Date,
    timeZone: TimeZone,
    calendarDays: [CalendarDay]
) -> Int?
```

This function must be the **only** place where `UTC -> dayIndex` mapping is performed.

It must use the provided `timeZone` parameter.

It must not resolve timezone internally.

Timezone resolution must happen before calling this function.

It must:

1. convert `UTC -> local date-time` using the provided timezone
2. determine the local calendar day from year/month/day
3. map that local day to a `CalendarDay.index`

All of the following must call this function:

- `buildSegments`
- `localRegressionMetadata`
- any future calendar placement logic

There must be exactly one way to answer:

`Which day column does this UTC timestamp belong to?`

If different parts of the system compute `dayIndex` differently, that is a bug.

### Display Rule

The calendar displays **local time by default**.

Meaning:

- trip bars are positioned using local operational time
- visible time labels in the calendar are local time
- default rendering must not show mixed UTC/local values

An explicit UTC mode may be added later, but it is not part of v1.

### Local-Time Regression Rule

The calendar must support a broader **local-time regression** case, including:

- timezone shifts
- date-line crossings
- apparent local clock reversal

This is a rendering rule only.

Required behavior:

- keep UTC as the true interval source
- detect when the rendered local timeline regresses within a visible trip segment/day presentation
- render the regressed visible portion with **75% transparency**
- keep the normal visible portion at full opacity

In other words:

- normal bar portion: full opacity
- regressed portion: opacity `0.25`

Regression detection must **not** compare raw display strings.

It must use structured local date-time components derived from UTC plus timezone.

UTC ordering must remain unchanged even when local displayed time appears to go backward.

This must be consistent with Timeline display behavior.

### Exact Regression Metadata Contract

This is a rendering-only feature.

It must **not** affect:

- ordering
- overlap detection
- lane allocation

Required function:

```swift
func localRegressionMetadata(
    trip: CalendarTrip,
    days: [CalendarDay]
) -> [Int: ClosedRange<Double>]
```

Return value:

- dictionary of `dayIndex -> regressed fraction range`
- if no regression exists, return an empty dictionary

#### Inputs

From `CalendarTrip`:

- `startUTC`
- `endUTC`
- `legs`

From each leg:

- departure airport
- arrival airport
- departure UTC
- arrival UTC

Use `IATATimeZoneResolver` to resolve:

- departure timezone
- arrival timezone

#### Local Conversion

For each leg:

- compute `localDeparture` from UTC in departure airport timezone
- compute `localArrival` from UTC in arrival airport timezone

Extract structured values:

- year
- month
- day
- hour
- minute
- second
- day key in `YYYY-MM-DD`

Do not compare formatted display strings.

#### Regression Detection Rule

A regression occurs when:

- local arrival date-time < local departure date-time

This compares full structured **local date-time components**, not UTC ordering and not clock-only values.

Example:

- Jan 1 22:00 -> Jan 2 05:00 = not regression
- Jan 2 22:00 -> Jan 2 05:00 = regression
- Jan 2 22:00 -> Jan 1 23:00 = regression
- Jan 1 10:00 -> Jan 1 14:00 = not regression

Use numeric year/month/day/hour/minute/second components, not strings.

#### Affected Calendar Day

Regression is applied to the day where the **arrival is rendered**.

Steps:

1. determine the local arrival boundary using structured local date-time components
2. resolve the timezone using the arrival airport
3. call `resolveDayIndex(...)` using that UTC timestamp and timezone
3. use that `dayIndex` as the regression target

Do not maintain two separate day-ownership rules.

The function that decides which day column owns a local boundary event must be reused for both:

- normal segment placement
- regression affected-day placement

### Timezone Ownership for Multi-Day Trips

For a multi-day trip, one consistent timezone must be used for all intermediate visible day segments.

Rule:

- the entire trip uses the **departure airport timezone of the first leg** as the display timezone for:
  - day ownership
  - `startFraction`
  - `endFraction` for intermediate days
- only the final boundary of the last segment uses the arrival airport timezone of the final leg

For the last segment of a trip:

- convert `trip.endUTC` using the arrival airport timezone of the final leg
- compute `localEndTime` from that conversion
- use that value for `endFraction`

Do not use the departure timezone for `endFraction` on the final segment.

Do not switch timezones per segment or per day for the same trip.

Rationale:

- avoids mid-trip timezone switching
- improves visual stability across days
- better aligns with existing Timeline expectations

For v1, use the simple case:

- if `arrivalFraction < departureFraction`
- store `arrivalFraction ... departureFraction`

If multiple regression legs exist on the same day, keep the widest range.

#### Segment Integration

During segment creation:

- if `segment.dayIndex` exists in the regression dictionary:
  - `hasLocalTimeRegression = true`
  - `regressedRange = dictionary[dayIndex]`
- otherwise:
  - `hasLocalTimeRegression = false`
  - `regressedRange = nil`

#### Rendering Rule

Do **not** render a regressed segment as a single uniform-opacity rectangle.

Split drawing into two layers:

1. normal portion at full opacity
2. regressed portion at opacity `0.25`

This can be implemented with clipped shapes or multiple rectangles, but the faded portion must be isolated to the regressed range only.

#### Fraction Range

The `regressedRange` represents the visual gap in the day column between:

- `arrivalFraction`
- `departureFraction`

This range is rendered at reduced opacity (`0.25`).

Example:

- departure `22:00`
- arrival `05:00`
- regression portion = `05:00 -> 22:00`

---

## 11. Trip Segmentation

Calendar renders trips as day-based segments.

### Function Shape

```swift
func buildSegments(
    trip: CalendarTrip,
    days: [CalendarDay]
) -> [CalendarSegment]
```

### Segmentation Rules

For each calendar day intersected by the trip:

- first day:
  - `startFraction = localStartTime / 24h`
  - `endFraction = 1.0`
- middle days:
  - `startFraction = 0.0`
  - `endFraction = 1.0`
- last day:
  - `startFraction = 0.0`
  - `endFraction = localEndTime / 24h`

Important:

- segment creation order is based on UTC
- local time is used only to choose the visible day column and fractions
- lane assignment must consume already-built segments without reordering them by local clock value

### Local-Time Regression Metadata

Segmentation must also compute rendering metadata for the local-time-regression case.

Each segment should determine:

- `hasLocalTimeRegression`
- `regressedRange`

If a rendered local day presentation contains a regressed portion:

- split the visible bar into:
  - a normal-opacity portion
  - a reduced-opacity portion

This affects rendering only, not trip ordering or overlap math.

### Calendar Engine Placement

The pure calendar engine should live in:

- `TripDataHub/Views/CalendarSupport.swift`

Before any UI work, implement and test these pure functions there:

- `normalizeCalendarTrips`
- `visibleTrips`
- `buildSegments`
- `localRegressionMetadata`
- `assignLanes`
- `frameForSegment`

Do not embed trip math directly in the view body.

### Required Engine Functions

#### A. Normalization

```swift
func normalizeCalendarTrips(from schedules: [PayPeriodSchedule]) -> [CalendarTrip]
```

Rules:

- group legs by effective trip identity: `"\(payPeriod)|\(pairing)"`
- sort legs by UTC departure
- compute trip `startUTC` and `endUTC`
- exclude malformed trips with invalid UTC bounds

Do not build the calendar directly from raw `TripLeg`.

#### B. Visible Trip Filtering

```swift
func visibleTrips(in bidPeriod: CalendarBidPeriod, trips: [CalendarTrip]) -> [CalendarTrip]
```

Rules:

- include trip if:
  - `trip.startUTC < bidPeriod.endDateUTC`
  - `trip.endUTC > bidPeriod.startDateUTC`

#### C. Local Rendering Boundary Helpers

Required helpers:

```swift
func displayTimeZoneForTripStart(_ trip: CalendarTrip) -> TimeZone?
func displayTimeZoneForTripEnd(_ trip: CalendarTrip) -> TimeZone?
func localComponents(for utcDate: Date, timeZone: TimeZone) -> DateComponents
func dayKey(from utcDate: Date, timeZone: TimeZone) -> String
func resolveDayIndex(for utcDate: Date, timeZone: TimeZone, calendarDays: [CalendarDay]) -> Int?
```

Rules:

- never use device timezone
- only use airport timezone resolver
- use structured date components, not strings, for logic
- `resolveDayIndex(...)` is the only source of truth for UTC-to-dayIndex mapping

#### D. Day Placement and Fraction Calculation

Required helpers:

```swift
func startFraction(for utcDate: Date, timeZone: TimeZone) -> Double
func endFraction(for utcDate: Date, timeZone: TimeZone) -> Double
```

Rules:

- `fraction = (hour + minute / 60 + second / 3600) / 24`
- clamp to `0...1`
- these functions are rendering helpers only
- for multi-day trips, use the first-leg departure timezone for day ownership and intermediate-day fractions
- use the final-leg arrival timezone only for the final boundary of the last segment

#### E. Local-Time Regression Detection

Required helper:

```swift
func localRegressionMetadata(for trip: CalendarTrip, days: [CalendarDay]) -> [Int: ClosedRange<Double>]
```

Rules:

- rendering rule only
- do not compare display strings
- use structured local components from UTC + resolved timezone
- if local arrival date-time appears earlier than local departure date-time in the rendered presentation, store the regressed range for the arrival-rendered day
- the regressed portion later renders at opacity `0.25`
- normal portion remains full opacity

Important:

- do not move any ordering or overlap logic to local time
- overnight arrival on the next local day is not a regression

#### F. Segmentation

```swift
func buildSegments(trip: CalendarTrip, days: [CalendarDay]) -> [CalendarSegment]
```

Rules:

- segment creation order is based on UTC
- local time is used only for:
  - visible day ownership
  - `startFraction`
  - `endFraction`
  - regression rendering metadata
- first day:
  - `startFraction = local start`
  - `endFraction = 1.0`
- middle day:
  - `0.0 -> 1.0`
- last day:
  - `0.0 -> local end`
- overnight trips must split across days
- week crossing must naturally split because segments carry `weekIndex` and `dayIndex`
- local regression metadata is attached by matching `dayIndex` from `localRegressionMetadata`
- if a single-day rendered segment would produce `startFraction > endFraction`, do not reject or skip it
- instead, create a full-width segment:
  - `startFraction = 0.0`
  - `endFraction = 1.0`
- the visual regression is then represented only through `regressedRange`

This keeps regression behavior isolated to rendering metadata and preserves a continuous visible bar.

#### G. Lane Allocation

```swift
func assignLanes(to segments: [CalendarSegment]) -> [CalendarSegment]
```

Rules:

- sort by:
  - `weekIndex`
  - `dayIndex`
  - `segmentStartUTC`
- collision only if:
  - same `weekIndex`
  - same `dayIndex`
  - `startA < endB`
  - `endA > startB`
- priority:
  1. bars must never overlap
  2. reuse same lane for same trip if possible
  3. otherwise first available lane
- deterministic output is required

Do not compute lane allocation from raw local clock ordering.

Required structure:

```swift
var tripLaneMap: [String: Int]
```

Algorithm:

- for each segment in sorted order:
  - if `tripLaneMap[segment.tripID]` exists and the segment does not collide in that lane:
    - reuse that lane
  - otherwise:
    - find the first non-colliding lane
    - assign it
    - update `tripLaneMap[segment.tripID]`

#### H. Geometry Mapping

```swift
func frameForSegment(_ segment: CalendarSegment, dayFrame: CGRect, laneHeight: CGFloat, laneSpacing: CGFloat) -> CGRect
```

Rules:

- `xStart = dayFrame.minX + startFraction * dayFrame.width`
- `xEnd = dayFrame.minX + endFraction * dayFrame.width`
- `y = row origin + lane * (laneHeight + laneSpacing)`
- `width = xEnd - xStart`

This function must stay isolated from the SwiftUI body.

Do not ignore `laneSpacing`.

### Overnight Example

If a trip runs:

- Day 1 22:00 -> Day 2 05:00

Segments become:

- Day 1: `22:00 -> 24:00`
- Day 2: `00:00 -> 05:00`

### Date Line Example

For long-haul trips:

- use absolute UTC timestamps for correctness
- never compare displayed clock strings to determine order

---

## 12. Week Splitting

Calendar rows represent weeks.

Segments must never render across rows.

Week splitting is handled naturally because each segment carries:

- `weekIndex`
- `dayIndex`

Overlay rendering must only draw within one row at a time.

---

## 13. Lane Allocation Consolidation

Section §13 is intentionally not a separate algorithm definition.

The authoritative lane allocation algorithm is defined only in:

- **§11.G Lane Allocation**

All implementations must follow §11.G.

Do not implement a separate or simplified lane allocation path based on an older duplicate section.

---

## 14. Geometry Mapping

Trip bars must be rendered in an overlay layer, never independently inside cells.

Inputs:

- measured day-cell frames
- day width
- lane height

Geometry:

```text
xStart = dayX + startFraction * dayWidth
xEnd   = dayX + endFraction * dayWidth
y      = weekY + lane * laneHeight
width  = xEnd - xStart
```

The overlay should compute frames from actual layout measurements, not hard-coded guesses.

---

## 15. Navigation Contract

This feature requires shared app navigation state.

Current `RootTabView` does not expose selected-tab or selected-trip navigation state, so Calendar must introduce one.

Recommended shared state:

- `selectedRootTab`
- `selectedTimelineTripID`

`selectedRootTab` should be backed by an explicit shared root-tab enum rather than stringly-typed values.

Tap behavior:

1. user taps a segment
2. set `selectedTimelineTripID = segment.tripID`
3. switch to Timeline tab
4. Timeline scrolls to the first leg of that trip
5. Timeline visually highlights the trip

Calendar should not own the Timeline navigation logic directly.

### Shared Navigation Requirement

Update shared app navigation state to add or reuse:

- `selectedRootTab`
- `selectedTimelineTripID`

Required behavior when tapping a calendar segment:

1. set `selectedTimelineTripID = segment.tripID`
2. switch to Timeline tab
3. Timeline scrolls to and highlights that trip

Trip identity must match Calendar identity exactly:

- `"\(payPeriod)|\(pairing)"`

Do not rely on raw pairing alone.

---

## 16. Rendering Order

Implementation order should be:

1. formalize Bid Period source of truth
2. normalize `TripLeg -> CalendarTrip`
3. generate 56 grid days
4. filter visible trips
5. segment trips by day
6. assign lanes
7. compute overlay geometry
8. render Calendar tab
9. connect tap navigation to Timeline

Do not begin with UI styling.

---

## 17. Suggested File Layout

Recommended files for this repo:

- `TripDataHub/Models/CalendarModels.swift`
- `TripDataHub/Services/BidPeriodService.swift`
- `TripDataHub/Views/CalendarSupport.swift`
- `TripDataHub/Views/CalendarTabView.swift`

This matches the existing repo style used by Timeline and OpenTime.

### CalendarTabView Requirement

`TripDataHub/Views/CalendarTabView.swift` should:

1. determine current or selected Bid Period
2. generate 56 days
3. normalize trips
4. filter visible trips
5. build segments
6. assign lanes
7. render the overlay over the day grid

Day grid requirements:

- render exactly 8 rows x 7 columns
- Sunday first
- day cells remain lightweight

Overlay requirements:

- render trip bars in a separate overlay layer
- each bar segment must be tappable
- if `hasLocalTimeRegression == true` and `regressedRange != nil`, split the drawing into:
  - normal-opacity part
  - reduced-opacity part at opacity `0.25`

Do not fake the regression rule with a single uniform-opacity rectangle.

---

## 18. V1 Test Scenarios

The engine should be validated against:

- one-day trip
- overnight trip
- multi-day trip
- week-crossing trip
- trip intersecting BP boundary
- overlapping trips
- identical start times
- tiny segment near midnight
- deadhead trip rendering
- tap-to-Timeline navigation
- standard same-timezone trip
- timezone-heavy route with local clock regression
- date-line-style case where arrival local time is earlier than departure local time
- DST boundary case to confirm DST does not break UTC-based engine logic

Additional repo-specific validation:

- CrewAccess-imported trips
- BidPro-fetched trips
- repeated pairing numbers across pay periods
- timezone-heavy routes crossing the date line

### Required Test Inventory

Add tests for these exact functions:

#### `generateBidPeriodDays`

- returns 56 days
- Sunday-first indexing is correct
- `dayStartUTC` / `dayEndUTC` are consecutive

#### `normalizeCalendarTrips`

- groups by `payPeriod|pairing`
- sorts legs by UTC
- excludes malformed trips

#### `visibleTrips`

- includes partial overlap at BP start
- includes partial overlap at BP end
- excludes fully outside trips

#### `buildSegments`

- one-day trip
- overnight trip
- multi-day trip
- week-crossing trip
- tiny segment near midnight
- single-day regression case produces a full-width segment

#### `localRegressionMetadata`

- same-timezone normal trip
- timezone-heavy route where local arrival appears earlier than departure
- same-timezone overnight flight:
  - departure Jan 1 22:00 local
  - arrival Jan 2 05:00 local
  - no regression
- date-line / timezone regression case:
  - local arrival date-time is earlier than local departure date-time
  - regression detected
- CGN -> HKG style long haul
- DST boundary case that must not break UTC ordering
- multi-day trip with one regression leg

#### `assignLanes`

- overlapping segments
- identical start times
- same trip prefers same lane
- deterministic repeated output
- sorting uses `segmentStartUTC`, not `startFraction`

---

## 19. Definition of Done

Calendar v1 is done when:

- one Bid Period renders as a 56-cell grid
- visible trips render as horizontal bars
- multi-day trips split correctly
- week crossing renders on separate rows
- overlapping trips do not overlap visually
- same trip segments keep stable lanes where possible
- tapping a trip navigates to Timeline and highlights that trip

---

## 20. Non-Goals

Do not include in v1:

- month calendar mode
- editing or drag-and-drop
- fatigue/risk overlays
- colleague calendar overlays
- real-time ops updates
- schedule mutation from Calendar
- `OpenTimeTrip` rendering

`OpenTimeTrip` is excluded from Calendar v1.

Calendar v1 renders only scheduled `TripLeg`-based trips.

---

## 21. Final Guidance

The highest-risk parts are not the SwiftUI drawing code.

The highest-risk parts are:

- trip normalization
- explicit local-day placement rule
- bid-period source-of-truth
- shared navigation state with Timeline

Those must be settled before implementation starts.

Additional guardrails:

- use one property name only: `regressedRange`
- `displayDateKey` is not a source of truth for ownership
- local regression must compare full local date-time, not clock-only values
- overnight arrival on the next local day is not a regression
- `dayStartUTC` / `dayEndUTC` are BP boundary helpers, not local day-placement rules
- `resolveDayIndex(...)` must be reused for both segment placement and regression placement
- full-width regression segments (`0.0 -> 1.0`) may collide with all other segments on that day
- this may create additional lanes and increase visual stacking
- this is expected behavior
- do not attempt to optimize away this side effect

---

## 22. Implementation Order

Before writing UI polish, first implement and test these pure functions in `CalendarSupport.swift`:

- `normalizeCalendarTrips`
- `generateBidPeriodDays`
- `visibleTrips`
- `buildSegments`
- `localRegressionMetadata`
- `assignLanes`
- `frameForSegment`

Only after those are correct should the SwiftUI overlay be wired.
