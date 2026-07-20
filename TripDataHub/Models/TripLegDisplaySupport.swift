import Foundation

struct HotelNameNormalizationResult: Equatable, Sendable {
    let name: String
    let sourceName: String?
    let matchedBy: String?
}

enum HotelNameNormalizer {
    struct KnownHotel: Equatable, Sendable {
        let station: String
        let normalizedPhone: String
        let rawName: String
        let canonicalName: String
    }

    static let knownHotels = [
        KnownHotel(
            station: "SDF",
            normalizedPhone: "+15023672251",
            rawName: "Crowne Plaza Louisville Airpor",
            canonicalName: "Crowne Plaza Louisville Airport Expo Center"
        )
    ]

    static func publicName(
        station: String,
        rawName: String,
        phone: String?,
        directory: [KnownHotel] = knownHotels
    ) -> HotelNameNormalizationResult {
        let sourceName = collapsedWhitespace(rawName)
        let stationKey = station.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let phoneKey = phone.flatMap(normalizedPhone)

        if let phoneKey {
            let stationAndPhoneMatches = directory.filter {
                $0.station == stationKey && $0.normalizedPhone == phoneKey
            }
            if stationAndPhoneMatches.count == 1, let match = stationAndPhoneMatches.first {
                return normalizedResult(match, sourceName: sourceName, matchedBy: "stationAndPhone")
            }

            let phoneMatches = directory.filter { $0.normalizedPhone == phoneKey }
            if phoneMatches.count == 1, let match = phoneMatches.first {
                return normalizedResult(match, sourceName: sourceName, matchedBy: "phone")
            }
        }

        let stationAndRawNameMatches = directory.filter {
            $0.station == stationKey && exactRawNameMatch($0.rawName, sourceName)
        }
        if stationAndRawNameMatches.count == 1, let match = stationAndRawNameMatches.first {
            return normalizedResult(match, sourceName: sourceName, matchedBy: "stationAndRawName")
        }

        let rawNameMatches = directory.filter { exactRawNameMatch($0.rawName, sourceName) }
        if rawNameMatches.count == 1, let match = rawNameMatches.first {
            return normalizedResult(match, sourceName: sourceName, matchedBy: "rawName")
        }

        return HotelNameNormalizationResult(
            name: sourceName,
            sourceName: nil,
            matchedBy: nil
        )
    }

    static func normalizedPhone(_ rawPhone: String) -> String? {
        let digits = rawPhone.compactMap { character -> String? in
            guard let value = character.wholeNumberValue else { return nil }
            return String(value)
        }.joined()
        guard !digits.isEmpty else { return nil }

        if digits.hasPrefix("011"), digits.count > 3 {
            return "+" + String(digits.dropFirst(3))
        }
        if digits.count == 10 {
            return "+1" + digits
        }
        if digits.count == 11, digits.hasPrefix("1") {
            return "+" + digits
        }
        return "+" + digits
    }

    private static func normalizedResult(
        _ hotel: KnownHotel,
        sourceName: String,
        matchedBy: String
    ) -> HotelNameNormalizationResult {
        let differs = hotel.canonicalName != sourceName
        return HotelNameNormalizationResult(
            name: hotel.canonicalName,
            sourceName: differs && !sourceName.isEmpty ? sourceName : nil,
            matchedBy: differs ? matchedBy : nil
        )
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func exactRawNameMatch(_ lhs: String, _ rhs: String) -> Bool {
        collapsedWhitespace(lhs).caseInsensitiveCompare(collapsedWhitespace(rhs)) == .orderedSame
    }

    static func displayName(station: String, parsedName: String) -> String {
        let normalizedStation = station
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedName = parsedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedStation == "SYD",
           normalizedName.hasPrefix("crowne plaza sydney darling ha")
            || normalizedName.hasPrefix("crown plaza sydney darling ha") {
            return "Crowne Plaza Sydney Darling Harbour"
        }
        return parsedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FlightNumberNormalizer {
    static func displayValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains(where: \.isLetter) {
            return trimmed
        }
        return "5X\(trimmed)"
    }
}

extension TripLeg {
    var displayFlightNumberText: String {
        let normalized = status.uppercased()
        let base = FlightNumberNormalizer.displayValue(flight)
        if normalized == "DH" || normalized == "CML" {
            return base.isEmpty ? normalized : "\(normalized) \(base)"
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
