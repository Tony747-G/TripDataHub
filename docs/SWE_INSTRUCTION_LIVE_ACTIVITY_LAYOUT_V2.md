# RETIRED — Flight Countdown Live Activity Layout v2

**Status:** Retired by Product Owner decision on 2026-08-28.
**Do not implement or restore this document's former requirements.**

The former instruction defined Lock Screen and Dynamic Island layout, timer formatting,
`staleDate`, and ActivityKit/SpringBoard acceptance for Flight Countdown Live Activities.

The feature was removed because a local-only ActivityKit architecture could not guarantee the
required user-visible expiration:

```text
Scheduled Departure Time + 60 minutes
-> departure status is no longer visible
```

The requirement was not weakened. APNs/server/BGTask infrastructure was not introduced. A retry
using `staleDate`, `context.isStale`, `DateReference`, timer clamping, foreground reconciliation,
or local boundary scheduling is not an approved replacement.

Current contract:

- no Flight Countdown Lock Screen Live Activity;
- no Flight Countdown Dynamic Island compact/minimal/expanded presentation;
- no Flight Countdown Activity request/update/end production path;
- Home Screen Widget remains and is not a Live Activity;
- shared operational state and absolute Date/timezone handling remain;
- 48h/24h Report Notifications remain;
- Timeline NEXT REPORT remains governed by INV-020.

The historical T-14/T-50S and D-7/D-8 Live Activity acceptance requirements are retired. Current
regression coverage must instead prove the absence of the Flight Countdown ActivityKit runtime path
and preserve shared domain, Home Screen Widget, notification, and Timeline behavior.

See `docs/ADR/ADR-004-flight-operational-state-model.md` and INV-021.
