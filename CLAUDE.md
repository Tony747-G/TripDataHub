# TripData – CrewAccess Print-PDF Import Notes

## Context
CrewAccess is behind Zscaler + MFA; automated scraping is not feasible.
The only reliable export is: Zscaler -> Print -> PDF viewer window -> Share.
Normal share from page sends URL; the print viewer share sends a PDF file.

Sample PDF confirms selectable text exists (prefer text extraction over OCR).

## Recommended implementation (iOS)
### 1) Extension type
Use Action Extension (or Share Extension if easier) that activates for UTType.pdf.

### 2) Handoff
- Configure App Group (e.g., group.com.<bundle>.tripdata)
- In extension:
  - Get PDF as file URL from NSExtensionContext / NSItemProvider
  - Copy to App Group container:
    - filename: "import_<timestamp>_<uuid>.pdf"
  - Save a small manifest JSON in App Group:
    - { "pdfPath": "<relative path>", "createdAt": "...", "source": "share-extension" }
  - Open main app using deep link / universal link:
    - tripdata://import?manifest=<id>
  - Complete request.

### 3) Main app import
- On app open with deep link:
  - read manifest from App Group
  - load PDF file
  - extract text using a PDF text extractor (PDFKit on iOS)
  - parse -> Trip model -> persist
  - show success (trip id + date + legs count)

### 4) Text extraction
Use PDFKit:
- PDFDocument(url:) -> iterate pages -> page.string
Concatenate with page separators to keep structure.

If extracted text is empty/too short:
- OCR fallback optional (Vision framework) but keep off for MVP.

## Parsing strategy
Parse line-oriented:
- Normalize whitespace, keep line breaks.
- Identify header fields:
  - "Trip Information Date" : <date>
  - "Trip Id" : <id>
- Identify duty blocks:
  - lines starting with "Duty start" / "Duty end"
- Leg rows:
  - pattern includes optional weekday, optional "DH", flight number, "AAA-BBB", times
  - Keep both UTC and LT if present; prefer UTC fields in JSON.
- Extract totals blocks and hotel blocks with key-based parsing ("Hotel Details", "Status:", etc.)
- Crew list:
  - Look for "Crew:" section and table-like rows.

## JSON schema (MVP)
{
  "source": "crewaccess_print_pdf",
  "tripId": "...",
  "tripInfoDate": "...",
  "duties": [
    {
      "dutyStartUtc": "...",
      "dutyEndUtc": "...",
      "legs": [
        {
          "isDeadhead": true/false,
          "flightNumber": "...",
          "depIata": "AAA",
          "arrIata": "BBB",
          "startUtc": "...",
          "endUtc": "...",
          "startLocal": "...",
          "endLocal": "...",
          "aircraft": "...",
          "block": "HH:MM"
        }
      ],
      "totals": { "time": "...", "block": "...", "rest": "..." },
      "hotel": { "name": "...", "phone": "...", "transport": "..." }
    }
  ],
  "crew": [
    { "pos": "...", "seniority": "...", "crewId": "...", "name": "..." }
  ]
}

## Testing
- Add sample PDF(s) under Tests/Fixtures/
- Add snapshot test:
  - parse(pdf) -> JSON
  - compare to golden JSON file in repo
- Add “minimum invariants” tests:
  - no missing legs
  - all IATA are 3 letters
  - all UTC times parse
  - duty blocks count reasonable

## Notes
- Keep everything local (no cloud) for MVP.
- The primary risk is share-sheet activation and reliable file copying. Keep activation rules strict: PDFs only.

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
