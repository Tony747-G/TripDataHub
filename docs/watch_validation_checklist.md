# Watch MVP — Real Device Validation Checklist

## Pre-TestFlight Build Requirements

- [ ] Release build: iOS target BUILD SUCCEEDED
- [ ] Release build: watchOS target BUILD SUCCEEDED
- [ ] Watch app embedded at `TripDataHub.app/Watch/TripDataHubWatch.app`
- [ ] `WKCompanionAppBundleIdentifier` = `com.sfune.BidProSchedule` in Watch Info.plist

---

## Installation

- [ ] iPhone app installs via TestFlight without errors
- [ ] Watch app automatically appears on paired Apple Watch
- [ ] Watch app launches without crash on cold start

---

## Empty State (no snapshot)

- [ ] Fresh Watch install with no prior sync: `WatchEmptyStateView` is shown
- [ ] Message "Open TripDataHub on iPhone to sync your schedule" is readable
- [ ] No crash, no black screen, no fake data

---

## Snapshot Delivery (WatchConnectivity)

- [ ] Open iPhone app → schedule data loads → Watch receives snapshot within ~30 seconds
- [ ] Watch mode view matches expected mode based on current schedule state
- [ ] Kill and relaunch Watch app → last snapshot is restored from UserDefaults (cold launch)
- [ ] iPhone unreachable (airplane mode): Watch continues showing last stored snapshot
- [ ] Snapshot age is reasonable (not hours old after a fresh iPhone open)

---

## Trip Mode

- [ ] UTC clock shows correct current UTC time
- [ ] DEP airport local clock shows correct local time for departure airport timezone
- [ ] ARR airport local clock shows correct local time for arrival airport timezone
- [ ] All three clocks advance by 1 minute every ~60 seconds
- [ ] Countdown shows T-HH:MM before departure; T+HH:MM after departure
- [ ] Card 1 (Leg Detail): UTC dep/arr times and block time are correct
- [ ] Card 2 (Time Pack): LT dep/arr times are correct
- [ ] Swiping between cards works (Digital Crown or swipe)

---

## Reserve / LCO / RCID Mode

- [ ] LDT clock shows correct current local domicile time
- [ ] LDT clock advances by 1 minute every ~60 seconds
- [ ] Reserve type label (RSV-A/B/C/D, LCO, RCID) matches the event
- [ ] Progress ring reflects elapsed fraction of the window correctly
- [ ] Remaining time (HH:MM) counts down over time
- [ ] HOT event does NOT trigger Reserve mode
- [ ] Upcoming (not-yet-started) reserve shows Off-Duty mode, not Reserve
- [ ] Card 1 (Window Detail): start/end times in LDT and total duration are correct

---

## CQ / Training Mode

- [ ] Event name (CQ12 / CQ6) is displayed
- [ ] Countdown shows time until start
- [ ] "Starts in" / "In progress" label switches correctly at start time
- [ ] CQ starting within T-6h shows Training mode; beyond T-6h shows Off-Duty

---

## Off-Duty Mode

- [ ] Next duty date, type, and report time are correct
- [ ] "In" countdown format: "Xd Xh" for multi-day; "Xh Xm" for same-day
- [ ] Countdown decrements every minute
- [ ] Card 1 (Time Pack): UTC report time shown correctly

---

## Priority Verification

- [ ] Active RSV window shows Reserve, even when a trip leg is within T-24h
- [ ] Active trip leg (airborne) shows Trip mode
- [ ] No active duty + trip within T-24h shows Trip mode
- [ ] CQ within T-6h but trip also within T-24h → Trip mode wins

---

## DEBUG Build Only

- [ ] Watch debug picker (`#if DEBUG`) appears with "Live snapshot" section
- [ ] Snapshot age label shows correct time since last sync
- [ ] Stale snapshot (>4h) age label turns orange
- [ ] "No snapshot" shown when Watch has never received one
- [ ] Manual mode links navigate to correct mode views with mock data

---

## Performance / Battery

- [ ] Watch app does not spike CPU visibly in Instruments
- [ ] `TimelineView(.periodic(by:60))` is the only refresh mechanism — no busy timers

---

## Known Not Tested in Simulator

- Digital Crown scroll between cards on physical hardware
- WatchConnectivity delivery timing on real device
- Watch face power reserve behavior
