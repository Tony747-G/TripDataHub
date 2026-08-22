# Priority 2 Tally — Final Reconciled Record

- Authoritative baseline: `78a67b0`
- Final status: **PASS**
- Evidence: production-path ActivityKit/SpringBoard Simulator runtime plus authentic-PDF Timeline acceptance

> Earlier sections of this tally treated Simulator results as triage only and retained arrival-driven states. A later PO decision approved the production-path Simulator runtime evidence and replaced the realtime model with the STD-only contract. Those earlier gates are superseded by this record.

## 1. Four-row layout

| Item | iPhone narrow | iPhone Pro Max | iPad Lock Screen | Status |
|---|---|---|---|---|
| D-1 / D-1b / D-1c | PASS | PASS | PASS | **PASS** |
| D-2 / D-2b / D-2c | PASS | PASS | PASS | **PASS** |
| D-6 enlarged text | PASS | PASS | PASS | **PASS** |

Dynamic Island expanded was checked on supported iPhone surfaces. iPad Dynamic Island is **N/A**.

## 2. STD-only runtime presentation

| Item | Evidence | Status |
|---|---|---|
| D-7a | `Report in …`, no redaction/blank/seconds | **PASS** |
| D-7b | `Dep in …`, Lock Screen and DI expanded | **PASS** |
| D-7c | `Departure time passed …`, including 60-minute stress case | **PASS** |
| D-7d | Minute-only OS-driven rendering | **PASS** |
| D-7e | Countdown/count-up advanced across minute boundaries without polling | **PASS** |
| D-7f | All three STD-only wordings; no retired arrival wording | **PASS** |
| D-7g | Light/Dark visibility on required Lock Screen/DI surfaces | **PASS** |

Timer evidence: +59 rendered 59 minutes; +60 rendered 60 minutes; beyond +60 remained clamped at 60 while suspended. At next execution, +61 evaluated expired and the Activity ended.

## 3. Timeline Connection card

Authentic `Trip_12165.pdf` was the source. The production parser/canonical JSON produced the following authoritative gate:

| Item | Authoritative value | Status |
|---|---|---|
| D-3 | `Block: 02:48` | **PASS** |
| D-4 | `Connection at CGO: 2:26`, separate right-aligned line | **PASS** |
| D-5 | Same two-line structure/value on iPad | **PASS** |

The older `Block: 02:44` / `Connection at CGO: 2:31` values are **RETIRED** because they do not match this authentic PDF or canonical JSON.

## 4. Surface scope

- Lock Screen and iPhone Dynamic Island expanded: accepted.
- iPad Lock Screen: accepted; Dynamic Island is N/A.
- Dynamic Island compact/minimal: outside D-7.
- Home Screen Widget actual rendering: **F-9 DEFERRED**. Static guards exist, but this tally does not claim pixel acceptance.

## 5. Historical Simulator decision

The 2026-08-17 run was originally labeled triage-only. Subsequent PO-approved DEBUG runtime time injection exercised the real ActivityKit → WidgetKit extension → SpringBoard path, including timer boundaries, appearances, and expanded layout. That later evidence supersedes the earlier statement that Simulator could not close Priority 2. Test-host rendering alone is still not acceptance evidence.

## Final result

```text
D-1 / D-1b / D-1c: PASS
D-2 / D-2b / D-2c: PASS
D-3 / D-4 / D-5 / D-6: PASS
D-7a through D-7g: PASS
Home Screen Widget visual: F-9 DEFERRED
Priority 2: PASS
```
