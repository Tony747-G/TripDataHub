# TripData – CrewAccess Trip PDF Import (Zscaler Print -> Share -> App)

## Goal
Implement a frictionless import flow for non-technical pilots:
CrewAccess (behind Zscaler + MFA) -> Zscaler Print -> PDF viewer window -> iOS Share Sheet -> TripData import -> parsed JSON -> app timeline.

Key discovery:
- Sharing the normal page sends only URL.
- From Zscaler print viewer window, sharing sends a real PDF file (not a URL).
- The PDF contains selectable text (not a screenshot). Prefer PDF text extraction, OCR only as fallback.

## UX requirements (must)
- User taps Share in the print-PDF viewer and selects TripData action (like RosterBuster “Download Roster”).
- Minimal UI: ideally one tap to confirm import, then success screen.
- Do NOT require user to manage files or JSON.

## Architecture constraints
- Avoid doing heavy parsing/OCR inside the extension. iOS extensions have strict memory/time limits.
- Extension should:
  1) accept UTType.pdf
  2) copy PDF into App Group shared container
  3) launch main app via deep link with reference to stored file
- Main app performs:
  - PDF text extraction
  - parsing into Trip JSON schema
  - normalization (UTC is source of truth)
  - persistence into local storage used by TripData timeline

## Parsing rules (baseline)
- Parse “Trip Information Date” and “Trip Id”.
- Split into duty blocks based on “Duty start” / “Duty end” lines.
- Extract leg rows:
  - dep-arr IATA (AAA-BBB)
  - DH flag (deadhead)
  - flight number
  - UTC start/end (ISO8601)
  - LT start/end (keep for display; UTC is truth)
  - aircraft (e.g., 747)
  - block time if present
- Extract duty totals if present (Time/Block/Rest).
- Extract hotel details if present.
- Extract crew list if present (pos, seniority, crew id, name).

## OCR fallback
Only if PDF text extraction yields too little text OR parsing fails due to image-only PDF.
Keep OCR implementation optional and behind feature flag.

## Deliverables
1) iOS Action Extension target that appears in share sheet for PDFs.
2) App Group shared file handoff from extension to main app.
3) Main-app import screen that processes the received PDF and imports trip.
4) Parser + tests using provided sample PDFs (at least 10 cases eventually; start with 1 sample).
5) JSON schema and a “golden JSON” snapshot test for the sample.

## Acceptance criteria
- On sample PDF, parser produces stable JSON (no missing legs, correct IATA, correct UTC times).
- End-to-end: share PDF -> TripData shows imported trip without manual file steps.

## Non-goals (for MVP)
- Automating login/MFA/Zscaler navigation.
- Cloud storage or account system.
- Geopolitical warning engine (later phase).
