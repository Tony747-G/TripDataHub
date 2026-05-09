# ADR-002: UTC Is the Internal Source of Truth

**Status:** Accepted
**Date:** 2026-05 (codified during Phase 0 docs; the convention itself is older)

## Context

TripDataHub computes:
- BP/PP membership across multiple US time zones (ANC, SDF, ONT, MIA).
- Cross-device sync via CloudKit (iPhone, iPad, web — each in arbitrary zones).
- Timeline rendering with per-airport local-time labels and per-domicile day boundaries.

Mixing UTC and local-time math has produced multiple regressions:
- `resolveDayIndex` using `Calendar.current.startOfDay` produced 1-day shifts for week-crossing trips on UTC- timezones (e.g. ANC March 22 00:00 UTC mapped to March 21 in local).
- DST transitions during a layover produced inconsistent block-time totals.
- Cross-device sync rejected updates because two devices interpreted the same wall-clock differently.

## Decision

**UTC is the internal source of truth.** Every persisted timestamp, every comparison, every sort key, every dedup key, every fingerprint operates in UTC.

**Local time is used at exactly two boundaries:**
1. **Rendering** — converting a UTC `Date` to a local-time string for display.
2. **Domain interpretation** — converting a UTC `Date` to "which 03:00-LDT day does this belong to?" for BP/PP membership.

Implicit conversion via `Calendar.current` or `TimeZone.current` is forbidden. Every formatter and every `Calendar` used for math must set an explicit `timeZone`.

## Consequences

- BP/PP boundary code (`BidPeriodService.bidPeriodBoundaryUTCDate`) explicitly constructs a domicile calendar and converts the local 03:00 to UTC.
- `CalendarSupport.resolveDayIndex` uses pure UTC arithmetic: `floor((utcDate - bpStartUTC) / 86400)`. The display timezone parameter is retained for API compatibility but is not used for day indexing.
- Tests for DST transitions, date-line crossings, and per-domicile boundary moments must accompany any change to time-handling code.

## Tradeoffs

- Slightly more verbose at every formatter site (each must set `timeZone`).
- Reading code requires distinguishing "this is a UTC `Date`" from "this is a local-time string". Convention: variable suffixes `UTC` / `Local` make the distinction explicit (e.g. `depUTC`, `depLocal`, `arrLocal`).

## Related

- `docs/INVARIANTS.md` — INV-001, INV-002, INV-009.
- `docs/BID_PERIODS.md` — the 03:00 LDT boundary.
- `CalendarSupport.swift`, `BidPeriodService.swift`, `LegConnectionTextBuilder.swift`.

## Reconsider When

A move away from this requires a new ADR. There is currently no foreseeable reason to abandon it.
