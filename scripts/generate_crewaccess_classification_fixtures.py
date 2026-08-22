#!/usr/bin/env python3
"""Generates synthetic CrewAccess PDFs that pin Scheduled/Actual classification (INV-012).

The parser classifies each endpoint independently by comparing the PDF's own `Created (UTC)`
instant with that endpoint's instant:

    Created <  endpoint  ->  Scheduled observation
    Created >= endpoint  ->  Actual observation

Testing that rule requires PDFs whose Created time sits at chosen positions relative to the leg
times. The committed real-trip samples cannot do this: their Created stamps are fixed historical
values, so they only ever exercise "all Scheduled" or "all Actual".

These fixtures are fully synthetic. No real trip, crew identity or GEMS ID appears in them. They
reuse the byte layout of `generate_app_review_sample_pdf.py`, which the parser already reads.

Run from the repository root:

    python3 scripts/generate_crewaccess_classification_fixtures.py
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "sample_trip"

HEADER_COLUMNS = (
    "Day             Flight           Departure-Arrival                            "
    "Start               Start(LT)            End            End(LT)   Block A/C Cnx PNR DH Remark"
)


def leg_block(day, weekday, flight, route, start, start_lt, end, end_lt, block, hotel=None):
    """One duty day containing exactly one flight, matching the real CrewAccess layout."""
    lines = [
        f"                Duty start                                                    {start}               {start_lt}",
        f"{day} {weekday}            {flight:<16} {route:<44} {start}               {start_lt}                {end}          {end_lt}     {block}   747",
        f"                Duty end                                                                                               {end}          {end_lt}",
        f"Duty totals     Time: {block}       Block: {block}                                 Rest: 14:30",
    ]
    if hotel:
        lines.append(
            f"Hotel details   Status: BOOKED   Hotel: {hotel:<36} Hotel Transport:"
        )
    return lines


def build_lines(title, trip_id, trip_date, created, legs):
    lines = [
        title,
        "",
        "Trip Information",
        f"Date:         {trip_date}",
        "",
        f"Trip Id: {trip_id} {trip_date}",
        HEADER_COLUMNS,
    ]
    for leg in legs:
        lines.extend(leg_block(**leg))
    lines.extend(
        [
            "Crew on trip - (0)",
            "Pos Seniority Crew ID    Name",
            "No crew assigned for this sample. GEMS ID and Name: None",
            f"Created {created} (UTC) by TripDataHub",
            "",
            "This PDF is synthetic fixture data for automated tests only.",
        ]
    )
    return lines


def pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def build_pdf(lines) -> bytes:
    content_lines = ["BT", "/F1 8 Tf", "10 TL", "36 570 Td"]
    for line in lines:
        content_lines.append(f"({pdf_escape(line)}) Tj")
        content_lines.append("T*")
    content_lines.append("ET")
    stream = "\n".join(content_lines).encode("ascii")

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
        b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n" + stream + b"\nendstream",
    ]

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out.extend(f"{index} 0 obj\n".encode("ascii"))
        out.extend(obj)
        out.extend(b"\nendobj\n")

    xref_offset = len(out)
    out.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    out.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        out.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    out.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF\n".encode("ascii")
    )
    return bytes(out)


# Created 15Jun2026 10:00Z, chosen so that one parse covers every classification branch:
#
#   leg 1  14Jun 13:00Z -> 19:00Z   Created after both      -> ATD + ATA
#   leg 2  15Jun 10:00Z -> 22:00Z   Created == DEP exactly  -> ATD + STA  (exact boundary, M-2)
#   leg 3  16Jun 00:30Z -> 09:30Z   Created before both     -> STD + STA
CLASSIFICATION_MATRIX = {
    "filename": "crewaccess_classification_matrix.pdf",
    "title": "TripDataHub Classification Fixture",
    "trip_id": "C00001",
    "trip_date": "14Jun2026",
    "created": "15Jun2026 10:00",
    "legs": [
        dict(day=1, weekday="Su", flight="001", route="ANC-CVG",
             start="13:00", start_lt="05:00", end="19:00", end_lt="15:00",
             block="06:00", hotel="Fixture Inn"),
        dict(day=2, weekday="Mo", flight="002", route="CVG-HND",
             start="10:00", start_lt="06:00", end="22:00", end_lt="07:00",
             block="12:00", hotel="Fixture Tokyu"),
        dict(day=3, weekday="Tu", flight="003", route="HND-ANC",
             start="00:30", start_lt="09:30", end="09:30", end_lt="01:30",
             block="09:00"),
    ],
}

# Created 14Jun2026 19:00Z == leg 1's arrival instant exactly, pinning the arrival-side boundary.
#
#   leg 1  14Jun 13:00Z -> 19:00Z   Created == ARR exactly  -> ATD + ATA
#   leg 2  15Jun 10:00Z -> 22:00Z   Created before both     -> STD + STA
ARRIVAL_BOUNDARY = {
    "filename": "crewaccess_arrival_boundary.pdf",
    "title": "TripDataHub Arrival Boundary Fixture",
    "trip_id": "C00002",
    "trip_date": "14Jun2026",
    "created": "14Jun2026 19:00",
    "legs": [
        dict(day=1, weekday="Su", flight="001", route="ANC-CVG",
             start="13:00", start_lt="05:00", end="19:00", end_lt="15:00",
             block="06:00", hotel="Fixture Inn"),
        dict(day=2, weekday="Mo", flight="002", route="CVG-HND",
             start="10:00", start_lt="06:00", end="22:00", end_lt="07:00",
             block="12:00"),
    ],
}


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for spec in (CLASSIFICATION_MATRIX, ARRIVAL_BOUNDARY):
        spec = dict(spec)
        filename = spec.pop("filename")
        path = OUTPUT_DIR / filename
        path.write_bytes(build_pdf(build_lines(**spec)))
        print(path)


if __name__ == "__main__":
    main()
