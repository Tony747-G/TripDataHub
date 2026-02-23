#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_SWIFT="/tmp/crewaccess_validate.swift"
TMP_BIN="/tmp/crewaccess_validate"
TMP_JSON="/tmp/crewaccess_validate_output.json"
TMP_NORM="/tmp/crewaccess_validate_output.normalized.json"
EXP_NORM="/tmp/crewaccess_expected.normalized.json"

CASES=(
  "sample_trip/2026-03-04_A70878.pdf|sample_trip/golden_A70651.json"
  "sample_trip/2026-01-15_A70752.pdf|sample_trip/golden_A70752.json"
  "sample_trip/2026-01-29_A70502.pdf|sample_trip/golden_A70502.json"
)

cat > "$TMP_SWIFT" <<'SWIFT'
import Foundation

@main
struct Validate {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            fputs("usage: crewaccess_validate <pdf> <out_json>\n", stderr)
            Foundation.exit(2)
        }

        let pdfURL = URL(fileURLWithPath: args[1])
        let outURL = URL(fileURLWithPath: args[2])
        let data = try Data(contentsOf: pdfURL)

        let service = CrewAccessPDFImportService()
        let draft = service.analyzeTrip(pdfData: data, sourceFileName: pdfURL.lastPathComponent)

        if !draft.errors.isEmpty || draft.jsonPayload == nil {
            fputs("parser failed for \(pdfURL.lastPathComponent)\n", stderr)
            for item in draft.errors {
                fputs("- [\(item.code.rawValue)] \(item.message)\n", stderr)
            }
            Foundation.exit(1)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(draft.jsonPayload)
        try json.write(to: outURL, options: Data.WritingOptions.atomic)
    }
}
SWIFT

xcrun swiftc \
  -o "$TMP_BIN" \
  "$TMP_SWIFT" \
  "$ROOT/BidProSchedule/Services/CrewAccessPDFImportService.swift" \
  "$ROOT/BidProSchedule/Services/IATATimeZoneResolver.swift" \
  "$ROOT/BidProSchedule/Models/TripModels.swift"

for case_entry in "${CASES[@]}"; do
  pdf_rel="${case_entry%%|*}"
  expected_rel="${case_entry##*|}"
  pdf="$ROOT/$pdf_rel"
  expected="$ROOT/$expected_rel"

  "$TMP_BIN" "$pdf" "$TMP_JSON"

  perl -0pe 's/"generatedAt"\s*:\s*"[^"]+"/"generatedAt" : "__DYNAMIC__"/g' "$TMP_JSON" > "$TMP_NORM"
  perl -0pe 's/"generatedAt"\s*:\s*"[^"]+"/"generatedAt" : "__DYNAMIC__"/g' "$expected" > "$EXP_NORM"

  diff -u "$EXP_NORM" "$TMP_NORM"
  echo "Validated: $expected_rel"
done

echo "CrewAccess parser validation passed."
