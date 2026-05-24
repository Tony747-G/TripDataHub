# Watch MVP — Known Limitations (pre-TestFlight)

Last updated: 2026-05-24

---

## Transport

**Snapshot is push-only from iPhone**
Watch receives snapshots when the iPhone app is open and schedule data loads or changes.
There is no periodic background push from iPhone. If the iPhone is closed all day, the Watch will show the last stored snapshot until the next iPhone app open.

**WatchConnectivity `updateApplicationContext` delivery is not guaranteed real-time**
`updateApplicationContext` queues the context dictionary and delivers it when the Watch is reachable. On first install, delivery may be delayed until both devices are awake and connected.

**Snapshot age is not surfaced in production UI**
Stale snapshots (>4h old) are shown as-is in the production Watch UI. The `WatchSessionReceiver.staleThreshold` constant is defined but not yet used to alter UI behavior. A staleness indicator is deferred to a future PR.

---

## Schedule Logic

**Snapshot generated only on schedule change, not on a timer**
`WatchSnapshotCoordinator` debounces AppViewModel changes and sends a new snapshot. If no schedule change occurs (e.g., the user opens the iPhone app and data is unchanged), no new snapshot is sent. This means the snapshot timestamp may be old even after a fresh iPhone open, if the schedule data did not change.

**No automatic snapshot refresh while Watch app is active**
The Watch does not request a new snapshot from the iPhone. All data flows one-way: iPhone → Watch.

**Off-duty countdown uses `nextDutyStartUtc` as report time**
`WatchSnapshotGenerator` equates "next duty start" with "report time." If actual report time differs from scheduled departure/event start, the countdown may be slightly off.

---

## Watch UI

**`TimelineView` 60-second refresh is approximate**
`TimelineView(.periodic(from:by:60))` fires ~every 60 seconds from the time the view first appears. The clocks may be up to 59 seconds behind real time. A sub-minute precision timer is deliberately avoided for battery reasons.

**No Watch complications**
Complications are not implemented in this MVP. The Watch app is only accessible by crown press / app launch.

**No background mode or handoff**
The Watch app has no background mode. If the Watch screen sleeps, the app pauses. On wake, `TimelineView` resumes from the current time.

**Training detail card not implemented**
`WatchTrainingModeView` is Primary-only (no supporting card) per PR6 scope. A Training Detail card can be added in a future PR.

---

## Data Completeness

**TripPayload has no flight number**
`TripPayload` carries `depIata`, `arrIata`, timezone identifiers, and UTC times. The flight number (e.g., "5X101") is not included in the snapshot. The LegDetail card shows DEP → ARR without a flight number.

**OffDutyPayload has no LDT timezone identifier**
The off-duty `reportLdtFormatted` is a pre-formatted string. The TimePack card derives the UTC equivalent from `nextDutyStartUtc`. If the generator ever returns a report time different from the duty start UTC, the UTC display on the TimePack card will be incorrect.

---

## Not Implemented

- Watch complications
- Watch notifications
- Friends schedule on Watch
- Bid period / pay period info on Watch
- PDF import on Watch
- CloudKit direct read from Watch
- Timeline / calendar grid on Watch
- Multi-leg trip context (only next/active leg is shown)
