# BidProSchedule Phase 1

This folder contains the Phase 1 scaffold for the iOS app:

- SwiftUI app entry point
- Home screen with `Sync` button
- Pay period list and detail views
- App-level ViewModel
- Data models for pay periods and trip legs
- Sync service protocol + stub implementation

## Current State

- The app UI is scaffolded and shows preview data for:
  - `PP26-02`
  - `PP26-03`
- `Sync` currently calls a stub service and intentionally returns "not implemented".

## Next (Phase 2)

- Add `WKWebView` login flow for TripBoard.
- Capture and persist authenticated cookies securely (Keychain/cookie store strategy).
- Replace `TripBoardSyncService.sync()` with authenticated data retrieval.
