# AI Context Index

This is the routing layer for AI sessions working on TripDataHub. It tells you what to read, when to read it, and what to do when code and docs disagree. Keep it short.

## Always Read

- `AGENTS.md` — cross-agent constitution
- `docs/AI_CONTEXT_INDEX.md` (this file)

## If Touching CloudKit

- `docs/CLOUDKIT.md`
- `docs/ADR/ADR-001-public-cloudkit-phase1.md`
- `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`
- Before reporting a CloudKit user issue as fixed, verify whether the running build is using Development or Production and check the relevant records in **both** environments. Development/Production drift is a known recurring source of Friend Sharing and schedule-sync bugs.

## If Touching CrewAccess PDF Import or Share Handoff

- `docs/INVARIANTS.md` — especially the import-file source-of-truth and cross-device rules
- `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`
- `docs/RCA_SEQUENTIAL_IMPORT_FAILURE.md` — sequential in-app Browser import popup leak RCA
- `docs/RCA_V2_IMPORT_PREVIEW_STUCK.md` — bidirectional Preview dismissal and CrewAccess report-window teardown RCA
- `docs/SWE_INSTRUCTION_POPUP_LIFECYCLE.md` — coordinator-owned popup teardown scope and T-26 through T-28
- `TripDataHub/Services/AppGroupImportHandoff.swift`
- `TripDataHub/Services/CrewAccessPDFImportService.swift`
- `TripDataHubTests/AppGroupImportHandoffTests.swift`
- `TripDataHubTests/CrewAccessParserRegressionTests.swift`
- Keep the extension limited to PDF acceptance and App Group handoff. Text extraction, parsing, normalization, and persistence belong in the main app.

## If Touching Time / Timeline / Calendar / iPad Calendar

- `docs/INVARIANTS.md`
- `docs/BID_PERIODS.md`
- `docs/MANUAL_EVENTS_LAYER_ARCHITECTURE.md`
- `docs/ADR/ADR-002-utc-source-of-truth.md`

## If Touching Flight State / Countdown / Live Activity / Notification

- `docs/INVARIANTS.md` — especially INV-013 through INV-018
- `docs/ADR/ADR-004-flight-operational-state-model.md`
- `docs/BUILD_WEEK_TDH_RELIABILITY_SWE_INSTRUCTION.md` — phased scope, T-1 through T-25, and acceptance requirements
- `docs/SWE_INSTRUCTION_DEBUG_TRIP_FIXTURE.md` — DEBUG-only simulator harness, T-45 through T-49, and non-persistence requirements
- `docs/SWE_INSTRUCTION_LIVE_ACTIVITY_LAYOUT_V2.md` — iOS 18 Live Activity layout/status rendering, T-14, T-50S, and production-path ActivityKit/SpringBoard D-7 acceptance
- `docs/SWE_INSTRUCTION_IOS18_BASELINE_AND_T50.md` — iOS 18 project baseline, minimal generated-project diff, T-50S, and deferred Dynamic Island automation
- `docs/SWE_INSTRUCTION_PRIORITY2_SIMULATOR_TRIAGE.md` — historical/superseded 2026-08-17 triage procedure; current status is in `DEVICE_VERIFICATION_CHECKLIST.md`
- `docs/FOLLOW_UPS.md` — register of deliberately deferred items: F-1 duration format divergence; F-2 Widget format; F-3 DI nightly automation; F-4 CI signing/Simulator entitlements; F-5 Print Preview wording; F-6 retired in-flight-progress proposal pending a trustworthy realtime source; F-7 XcodeGen version drift; F-8 Info.plist/build-setting duplication; F-9 Home Screen Widget visual acceptance

## If Touching Manual Operational / Personal Events

- `docs/MANUAL_EVENTS_LAYER_ARCHITECTURE.md`
- `docs/CREW_CALLOUT_PERIODS.md`
- `docs/INVARIANTS.md`
- `docs/ADR/ADR-002-utc-source-of-truth.md`

## If Touching Schedule Arrays or Model Ownership

- `docs/TERMINOLOGY.md`

## If Performing QA / Invariant Review

- `QWEN.md`
- `docs/INVARIANTS.md`
- relevant domain docs from the sections above

## If Debugging Simulator / Xcode Launch Issues

- `docs/SIMULATOR_TROUBLESHOOTING.md`

## Before Implementation

1. Identify the touched domain.
2. Read the relevant docs above.
3. If code and docs disagree, **stop and report the conflict** rather than guessing which is correct.

## Before Commit

1. Run the relevant tests.
2. Confirm whether docs need updates. If an invariant changed, update `docs/INVARIANTS.md` AND add or update the corresponding test.
3. If a CloudKit field/index/record-type changed, note that Production schema deploy is required before TestFlight or App Store use.

## Role Note

Codex primarily acts as PM / reviewer / orchestration agent.

Claude primarily acts as implementation SWE.

Qwen primarily acts as QA / invariant validation / regression detection agent.

Either Codex or Claude may implement changes, but all agents must follow the docs and invariants in this layer.

Qwen should not implement features or redesign architecture unless explicitly instructed by Codex. Its default role is diff-only QA review.

## Phase

This is Phase 0. Only the files listed in this index exist. Do not create additional doc folders (`Architecture/`, `Rendering/`, `EdgeCases/`, `Testing/`, etc.) without an explicit instruction — empty placeholders confuse readers more than they help.

# Agent Authority Matrix

| Role | Agent | Authority |
|---|---|---|
| PM | Codex | Product direction, orchestration, task decomposition |
| SWE | Claude | Implementation authority, scoped refactor authority, integration decisions |
| QA | Qwen | Validation authority, invariant enforcement, regression detection |

## Authority Rules

- Codex defines scope and acceptance criteria.
- Claude owns implementation decisions.
- Qwen validates implementation correctness against invariants.
- Qwen must not redesign architecture unless explicitly instructed by Codex.
- Invariant definitions are authoritative over agent opinions.
- ADRs override undocumented assumptions.
- No agent may silently override documented invariants or ADR decisions.
