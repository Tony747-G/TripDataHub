#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_SWIFT="/tmp/trip_leg_display_support_validate.swift"
TMP_BIN="/tmp/trip_leg_display_support_validate"

cat > "$TMP_SWIFT" <<'SWIFT'
import Foundation

func makeLeg(status: String, flight: String) -> TripLeg {
    TripLeg(
        payPeriod: "PP26-03",
        pairing: "1234",
        leg: 1,
        flight: flight,
        depAirport: "SEA",
        depLocal: "2026-03-01T08:00",
        arrAirport: "ANC",
        arrLocal: "2026-03-01T11:00",
        depUTC: "2026-03-01T16:00:00Z",
        arrUTC: "2026-03-01T19:00:00Z",
        status: status,
        block: "3:00"
    )
}

func assertEqual(_ actual: String, _ expected: String, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        Foundation.exit(1)
    }
}

@main
struct Validate {
    static func main() {
        assertEqual(makeLeg(status: "DH", flight: "AS123").displayFlightNumberText, "DH AS123", "DH alpha prefix should include space")
        assertEqual(makeLeg(status: "CML", flight: "AB12").displayFlightNumberText, "CML AB12", "CML alpha prefix should include space")
        assertEqual(makeLeg(status: "DH", flight: "1234").displayFlightNumberText, "DH1234", "DH numeric should not add space")
        assertEqual(makeLeg(status: "CML", flight: "5678").displayFlightNumberText, "CML5678", "CML numeric should not add space")
        assertEqual(makeLeg(status: "-", flight: "8123").displayFlightNumberText, "5X8123", "regular flights should add 5X")
        assertEqual(makeLeg(status: "-", flight: "5X8123").displayFlightNumberText, "5X8123", "existing 5X should be preserved")
        print("TripLeg display flight formatter validation passed.")
    }
}
SWIFT

xcrun swiftc \
  -o "$TMP_BIN" \
  "$TMP_SWIFT" \
  "$ROOT/TripDataHub/Models/TripModels.swift" \
  "$ROOT/TripDataHub/Models/TripLegDisplaySupport.swift"

"$TMP_BIN"
