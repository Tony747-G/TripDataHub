#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "web" / "sample" / "TripDataHub_App_Review_Sample_A00001.pdf"


LINES = [
    "TripDataHub App Review Sample",
    "",
    "Trip Information",
    "Date:         01Jun2026",
    "",
    "Trip Id: A00001 01Jun2026",
    "Day             Flight           Departure-Arrival                            Start               Start(LT)            End            End(LT)   Block A/C Cnx PNR DH Remark",
    "                Duty start                                                    12:00               04:00",
    "1 Mo            001              ANC-CVG                                      13:00               05:00                19:00          15:00     06:00   747",
    "                Duty end                                                                                               19:30          15:30",
    "Duty totals     Time: 7:30       Block: 6:00                                  Rest: 14:30",
    "Hotel details   Status: BOOKED   Hotel: Holiday Inn                           Hotel Transport:",
    "                Duty start                                                    09:00               05:00",
    "2 Tu            002              CVG-HND                                      10:00               06:00                22:00          07:00     12:00   747",
    "                Duty end                                                                                               22:30          07:30",
    "Duty totals     Time: 13:30      Block: 12:00                                 Rest: 24:30",
    "Hotel details   Status: BOOKED   Hotel: Tokyu Haneda                          Hotel Transport:",
    "                Duty start                                                    23:00               08:00",
    "3 We            DH 003           HND-ANC                                      00:30               09:30                09:30          01:30     09:00   747",
    "                Duty end                                                                                               10:00          02:00",
    "Duty totals     Time: 11:00      Block: 9:00                                  Rest:",
    "Crew on trip - (0)",
    "Pos Seniority Crew ID    Name",
    "No crew assigned for this sample. GEMS ID and Name: None",
    "Created 01Jun2026 00:00 (UTC) by TripDataHub",
    "",
    "This PDF is synthetic sample data for App Store Review only.",
]


def pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def build_pdf() -> bytes:
    content_lines = [
        "BT",
        "/F1 8 Tf",
        "10 TL",
        "36 570 Td",
    ]
    for line in LINES:
        content_lines.append(f"({pdf_escape(line)}) Tj")
        content_lines.append("T*")
    content_lines.append("ET")
    stream = "\n".join(content_lines).encode("ascii")

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
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
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n".encode("ascii")
    )
    return bytes(out)


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(build_pdf())
    print(OUTPUT)


if __name__ == "__main__":
    main()
