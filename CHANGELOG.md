# Changelog

All notable changes to **TripData Hub** will be documented in this file.

This project follows a simplified form of **Keep a Changelog** and **Semantic Versioning**.

---

## [1.0.0] - 2026-03-16

### Added
- Next Flight Countdown system
- Home Screen Widget countdown (T-12h -> T-6h)
- Live Activity countdown (T-6h -> T+6h)
- Dynamic Island support for countdown display
- Automatic transition from countdown to delayed state at Scheduled Departure Time
- Support for Deadhead (DH) legs in next-leg selection
- Airport-local time display using stored timezone IDs
- Countdown engine test coverage for phase logic, duration formatting, status text, leg selection, leg conversion, and timezone-aware display behavior

### Changed
- Countdown status now switches to **Delayed** mode after Scheduled Departure Time
- Next-leg selection now prefers the most relevant upcoming leg when multiple countdown-eligible legs exist
- Settings tab was simplified and reorganized

### Technical
- Introduced unified countdown engine used by Widget and Live Activity
- UTC-based lifecycle logic for all countdown calculations
- Airport timezone conversion handled only at display layer
- Deterministic next-leg selection algorithm for multi-leg trips
- Renamed the project identity from `BidProSchedule` to `TripDataHub`

---

## [0.9.0] - 2026-03-15

### Initial Release
- Trip schedule import
- Flight leg display
- Timezone-aware schedule rendering
