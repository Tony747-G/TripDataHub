# BidProSchedule Phase 4

Phase 4 expands formatting and presentation:

- Added **Open Time ingestion** from `payPeriods[].trips`.
- Added PP detail UI tabs:
  - `Schedule`
  - `Open Time`
- Added `OpenTimeTrip` model and per-PP `openTimeCount`.
- Kept schedule-leg local time conversion and block recalculation logic from Phase 3.

## Display

- Home list now shows:
  - schedule trip count
  - schedule leg count
  - open time count
- Detail screen can toggle between schedule legs and open time trip list.
