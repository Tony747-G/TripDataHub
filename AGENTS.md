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

## Bid Period / Pay Period Calendar

- BP26-01 from 2025-11-30 to 2026-01-24 (PP25-13 from 2025-11-30 to 2025-12-27, PP26-01 from 2025-12-28 to 2026-01-24)
- BP26-02 from 2026-01-25 to 2026-03-21 (PP26-02 from 2026-01-25 to 2026-02-21, PP26-03 from 2026-02-22 to 2026-03-21)
- BP26-03 from 2026-03-22 to 2026-05-16 (PP26-04 from 2026-03-22 to 2026-04-18, PP26-05 from 2026-04-19 to 2026-05-16)
- BP26-04 from 2026-05-17 to 2026-07-11 (PP26-06 from 2026-05-17 to 2026-06-13, PP26-07 from 2026-06-14 to 2026-07-11)
- BP26-05 from 2026-07-12 to 2026-09-05 (PP26-08 from 2026-07-12 to 2026-08-08, PP26-09 from 2026-08-09 to 2026-09-05)
- BP26-06 from 2026-09-06 to 2026-10-31 (PP26-10 from 2026-09-06 to 2026-10-03, PP26-11 from 2026-10-04 to 2026-10-31)
- BP26-07 from 2026-11-01 to 2026-11-28 (PP26-12 from 2026-11-01 to 2026-11-28) This is the only 4 weeks Bid Period.
- BP27-01 from 2026-11-29 to 2027-01-23 (PP26-13 from 2026-11-29 to 2026-12-26, PP27-01 from 2026-12-27 to 2027-01-23)
- BP27-02 from 2027-01-24 to 2027-03-20 (PP27-02 from 2027-01-24 to 2027-02-20, PP27-03 from 2027-02-21 to 2027-03-20)
- BP27-03 from 2027-03-21 to 2027-05-15 (PP27-04 from 2027-03-21 to 2027-04-17, PP27-05 from 2027-04-18 to 2027-05-15)
- BP27-04 from 2027-05-16 to 2027-07-10 (PP27-06 from 2027-05-16 to 2027-06-12, PP27-07 from 2027-06-13 to 2027-07-10)
- BP27-05 from 2027-07-11 to 2027-09-04 (PP27-08 from 2027-07-11 to 2027-08-07, PP27-09 from 2027-08-08 to 2027-09-04)
- BP27-06 from 2027-09-05 to 2027-10-30 (PP27-10 from 2027-09-05 to 2027-10-02, PP27-11 from 2027-10-03 to 2027-10-30)
