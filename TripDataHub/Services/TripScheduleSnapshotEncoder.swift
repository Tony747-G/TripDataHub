import Foundation

// MARK: - Web schedule payload types (design doc §8)

struct WebSchedulePayload: Codable {
    let schemaVersion: Int
    let generatedAtUTC: String
    let owner: WebOwner
    let currentTrip: WebCurrentTrip?
    let nextFlight: WebNextFlight?
    let scheduleItems: [WebScheduleItem]
}

struct WebOwner: Codable {
    let displayName: String
}

struct WebScheduleItem: Codable {
    let id: String
    let type: String
    let label: String
    let startUTC: String
    let endUTC: String
    let departureAirport: String?
    let arrivalAirport: String?
}

struct WebCurrentTrip: Codable {
    let tripId: String?
    let startUTC: String
    let endUTC: String
    let displayLabel: String
}

struct WebNextFlight: Codable {
    let flightId: String?
    let flightNumber: String
    let departureAirport: String
    let arrivalAirport: String
    let departureTimeUTC: String
    let arrivalTimeUTC: String
}

// MARK: - Encoder

enum TripScheduleSnapshotEncoder {
    static let schemaVersion = 1

    static func encode(
        ownerDisplayName: String,
        schedules: [PayPeriodSchedule],
        now: Date = Date()
    ) -> WebSchedulePayload {
        let legs = sortedLegs(from: schedules)
        let items = legs.compactMap { scheduleItem(from: $0) }
        return WebSchedulePayload(
            schemaVersion: schemaVersion,
            generatedAtUTC: formatUTC(now),
            owner: WebOwner(displayName: ownerDisplayName),
            currentTrip: currentTrip(from: legs, now: now),
            nextFlight: nextFlight(from: legs, now: now),
            scheduleItems: items
        )
    }

    static func json(
        ownerDisplayName: String,
        schedules: [PayPeriodSchedule],
        now: Date = Date()
    ) throws -> String {
        let payload = encode(ownerDisplayName: ownerDisplayName, schedules: schedules, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Private

    private static func sortedLegs(from schedules: [PayPeriodSchedule]) -> [TripLeg] {
        schedules
            .flatMap(\.legs)
            .sorted { (startDate($0) ?? .distantFuture) < (startDate($1) ?? .distantFuture) }
    }

    private static func scheduleItem(from leg: TripLeg) -> WebScheduleItem? {
        guard let start = leg.depUTC ?? leg.stdUTC,
              let end = leg.arrUTC ?? leg.staUTC else { return nil }
        return WebScheduleItem(
            id: leg.id.uuidString,
            type: "flight",
            label: "\(leg.flight) \(leg.depAirport)-\(leg.arrAirport)",
            startUTC: start,
            endUTC: end,
            departureAirport: leg.depAirport,
            arrivalAirport: leg.arrAirport
        )
    }

    private static func currentTrip(from legs: [TripLeg], now: Date) -> WebCurrentTrip? {
        var pairingMap: [String: [TripLeg]] = [:]
        for leg in legs { pairingMap[leg.pairing, default: []].append(leg) }

        for (pairing, tripLegs) in pairingMap {
            let sorted = tripLegs.sorted { (startDate($0) ?? .distantFuture) < (startDate($1) ?? .distantFuture) }
            guard let firstLeg = sorted.first,
                  let lastLeg = sorted.last,
                  let tripStart = startDate(firstLeg),
                  let tripEnd = endDate(lastLeg),
                  tripStart <= now, now <= tripEnd else { continue }

            var airports = [firstLeg.depAirport] + sorted.map(\.arrAirport)
            // Deduplicate consecutive identical airports (e.g. layover stops)
            airports = airports.reduce(into: [String]()) { acc, a in
                if acc.last != a { acc.append(a) }
            }
            return WebCurrentTrip(
                tripId: pairing,
                startUTC: formatUTC(tripStart),
                endUTC: formatUTC(tripEnd),
                displayLabel: airports.joined(separator: "-")
            )
        }
        return nil
    }

    private static func nextFlight(from legs: [TripLeg], now: Date) -> WebNextFlight? {
        guard let leg = legs.first(where: { (startDate($0) ?? .distantPast) > now }),
              let dep = startDate(leg),
              let arr = endDate(leg) else { return nil }
        return WebNextFlight(
            flightId: leg.id.uuidString,
            flightNumber: leg.flight,
            departureAirport: leg.depAirport,
            arrivalAirport: leg.arrAirport,
            departureTimeUTC: formatUTC(dep),
            arrivalTimeUTC: formatUTC(arr)
        )
    }

    private static func startDate(_ leg: TripLeg) -> Date? {
        parseUTC(leg.depUTC ?? leg.stdUTC)
    }

    private static func endDate(_ leg: TripLeg) -> Date? {
        parseUTC(leg.arrUTC ?? leg.staUTC)
    }

    private static func parseUTC(_ string: String?) -> Date? {
        guard let s = string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func formatUTC(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
