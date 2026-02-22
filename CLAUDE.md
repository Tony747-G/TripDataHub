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
