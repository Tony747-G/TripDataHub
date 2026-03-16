# BidProSchedule Phase 3

Phase 3 adds authenticated data retrieval from TripBoard:

- `TripBoardSyncService.sync(cookies:)` now calls:
  - `GET https://tripboard.bidproplus.com/api/1.0/TripBoard/Load`
- Decodes pay periods + scheduled trips + trip legs.
- Converts `startTime` / `endTime` token format (e.g. `(WE08)17:27`) into displayed local datetimes.
- Recalculates block time from UTC deltas when possible.
- Returns `PayPeriodSchedule` models for UI rendering.

## Notes

- Current Phase 3 output maps **scheduled trips only**.
- Open Time ingestion is deferred to the next phase.
