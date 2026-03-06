import Foundation

extension TripLeg {
    var displayFlightNumberText: String {
        let normalized = status.uppercased()
        let base = flight.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "DH" || normalized == "CML" {
            if let first = base.unicodeScalars.first, CharacterSet.letters.contains(first) {
                return "\(normalized) \(base)"
            }
            return "\(normalized)\(base)"
        }
        if normalized == "-" {
            if base.uppercased().hasPrefix("5X") { return base }
            return "5X\(base)"
        }
        return base
    }
}

enum LegConnectionTextBuilder {
    private static let preciseUTCFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicUTCFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseUTC(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = preciseUTCFormatter.date(from: value) {
            return date
        }
        return basicUTCFormatter.date(from: value)
    }

    static func connectionInfo(
        after leg: TripLeg,
        nextLegByID: [UUID: TripLeg]
    ) -> (minutes: Int, airport: String, sameStation: Bool)? {
        guard let next = nextLegByID[leg.id],
              let arr = parseUTC(leg.arrUTC),
              let dep = parseUTC(next.depUTC)
        else {
            return nil
        }
        let seconds = Int(dep.timeIntervalSince(arr))
        guard seconds > 0 else { return nil }
        let minutes = seconds / 60
        let airport = leg.arrAirport.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextDepartureAirport = next.depAirport.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameStation = !airport.isEmpty && airport.caseInsensitiveCompare(nextDepartureAirport) == .orderedSame
        return (minutes: minutes, airport: airport, sameStation: sameStation)
    }

    static func blockAndConnectionText(
        for leg: TripLeg,
        nextLegByID: [UUID: TripLeg]
    ) -> String {
        let blockText = "Block: \(leg.block)"
        guard let info = connectionInfo(after: leg, nextLegByID: nextLegByID) else {
            return blockText
        }

        let hh = info.minutes / 60
        let mm = info.minutes % 60
        let duration = "\(hh):\(String(format: "%02d", mm))"
        let label: String
        if info.sameStation, info.minutes < 5 * 60 {
            label = "Connection"
        } else if info.minutes <= 10 * 60 {
            label = "Rest"
        } else {
            label = "Layover"
        }

        if info.airport.isEmpty {
            return "\(blockText) / \(label): \(duration)"
        }
        return "\(blockText) / \(label) at \(info.airport): \(duration)"
    }
}
