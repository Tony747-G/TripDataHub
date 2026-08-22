# TripDataHub Agent Guide

TripDataHub is an iOS/iPadOS app for importing CrewAccess schedules, presenting crew-duty chronology, and synchronizing operational data. This file is a lightweight entry point, not a complete specification.

## Load Context Progressively

1. Read `docs/AI_CONTEXT_INDEX.md`.
2. Identify the domain touched by the request and read only the documents it routes to.
3. Inspect the nearby implementation and tests before deciding how to change them.

Do not copy domain rules into this file. Keep detailed architecture, invariants, terminology, period rules, and test guidance in `docs/` so each rule has one maintained home.

If code, tests, and documentation disagree, report the conflict instead of silently choosing one.

## Working Guidance

- Follow the user's requested scope and distinguish analysis, implementation, and Git delivery.
- Reuse existing models, services, and UI patterns when they fit; avoid parallel implementations of the same contract.
- Match the surrounding code's naming, structure, comment density, and platform conventions.
- Use judgment where no project-specific rule exists. Add a durable rule only for a recurring, non-obvious TripDataHub constraint.
- Treat real schedules, crew identities, and imported files as private. Use synthetic fixtures in tests and documentation.
- When behavior has equivalent iOS and iPadOS surfaces, inspect both as required by the project invariants.
- Validate in proportion to the change. Run focused tests first, then broader tests or an unsigned build when the risk warrants it.
- Treat commit, push, release, and publishing as separate delivery actions; perform them only when requested.

## Keep This File Small

Prefer improving `docs/AI_CONTEXT_INDEX.md` routing or the relevant domain document over expanding this file. Examples, long tables, implementation recipes, and historical notes belong in progressively loaded references.
