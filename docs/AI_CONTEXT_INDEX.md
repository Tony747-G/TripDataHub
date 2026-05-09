# AI Context Index

This is the routing layer for AI sessions working on TripDataHub. It tells you what to read, when to read it, and what to do when code and docs disagree. Keep it short.

## Always Read

- `AGENTS.md` — cross-agent constitution
- `docs/AI_CONTEXT_INDEX.md` (this file)

## If Touching CloudKit

- `docs/CLOUDKIT.md`
- `docs/ADR/ADR-001-public-cloudkit-phase1.md`
- `docs/ADR/ADR-003-crewaccess-file-cloudkit-sync.md`

## If Touching Time / Timeline / Calendar / iPad Calendar

- `docs/INVARIANTS.md`
- `docs/BID_PERIODS.md`
- `docs/ADR/ADR-002-utc-source-of-truth.md`

## If Touching Schedule Arrays or Model Ownership

- `docs/TERMINOLOGY.md`

## Before Implementation

1. Identify the touched domain.
2. Read the relevant docs above.
3. If code and docs disagree, **stop and report the conflict** rather than guessing which is correct.

## Before Commit

1. Run the relevant tests.
2. Confirm whether docs need updates. If an invariant changed, update `docs/INVARIANTS.md` AND add or update the corresponding test.
3. If a CloudKit field/index/record-type changed, note that Production schema deploy is required before TestFlight or App Store use.

## Role Note

Codex primarily acts as PM / reviewer / orchestration agent. Claude primarily acts as implementation SWE. Either agent may implement changes, but both must follow the docs and invariants in this layer.

## Phase

This is Phase 0. Only the files listed in this index exist. Do not create additional doc folders (`Architecture/`, `Rendering/`, `EdgeCases/`, `Testing/`, etc.) without an explicit instruction — empty placeholders confuse readers more than they help.
