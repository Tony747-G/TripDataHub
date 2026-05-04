import Foundation

struct WebSchedulePayload: Codable, Equatable {
    let schemaVersion: Int
    let generatedAtUTC: String
    let owner: WebScheduleOwner
    let currentTrip: WebCurrentTrip?
    let nextFlight: WebNextFlight?
    let timelineCards: [WebTimelineCard]
    let scheduleItems: [WebScheduleItem]
    let trips: [WebCrewAccessTrip]
}

struct WebScheduleOwner: Codable, Equatable {
    let displayName: String
}

struct WebScheduleItem: Codable, Equatable {
    let id: String
    let type: String
    let label: String
    let startUTC: String
    let endUTC: String
    let departureAirport: String?
    let arrivalAirport: String?
}

struct WebCurrentTrip: Codable, Equatable {
    let tripId: String
    let startUTC: String
    let endUTC: String
    let displayLabel: String
}

struct WebNextFlight: Codable, Equatable {
    let flightId: String
    let flightNumber: String
    let departureAirport: String
    let arrivalAirport: String
    let departureTimeUTC: String
    let arrivalTimeUTC: String
}

struct WebTimelineCard: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let type: String
    let dayKey: String
    let dayLabel: String
    let tripId: String
    let title: String
    let subtitle: String?
    let timeRange: String?
    let detail: String?
    let trailing: String?
    let icon: String
    let iconTone: String
    let startUTC: String
    let endUTC: String
    let station: String?
    let hotelName: String?
}

struct WebCrewAccessTrip: Codable, Equatable {
    let tripId: String
    let tripInformationDate: String
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
    let dutyTotals: [String]
    let hotelDetails: [String]
    let route: String
    let startUTC: String?
    let endUTC: String?
    let items: [WebCrewAccessTripItem]
}

struct WebCrewAccessTripItem: Codable, Equatable {
    let sequence: Int
    let depAirport: String
    let arrAirport: String
    let deadhead: Bool
    let flight: String
    let startUTC: String
    let endUTC: String
    let startLocalDisplay: String
    let endLocalDisplay: String
    let originTz: String?
    let destinationTz: String?
    let aircraft: String
    let block: String
    let tailNumber: String?
}

enum TripScheduleSnapshotEncoder {
    static let schemaVersion = 3
    private static let legacyScheduleSchemaVersion = 1
    private static let minimumLayoverMinutes = 180

    static func encode(
        ownerDisplayName: String,
        crewAccessTrips: [CrewAccessTripJSON],
        now: Date = Date()
    ) -> WebSchedulePayload {
        let trips = crewAccessTrips
            .map(webTrip)
            .sorted { lhs, rhs in
                (lhs.startUTC ?? lhs.tripInformationDate) < (rhs.startUTC ?? rhs.tripInformationDate)
            }
        let items = trips.flatMap(flattenScheduleItems)
        return WebSchedulePayload(
            schemaVersion: schemaVersion,
            generatedAtUTC: formatUTC(now),
            owner: WebScheduleOwner(displayName: ownerDisplayName),
            currentTrip: currentTrip(from: trips, now: now),
            nextFlight: nextFlight(from: trips.flatMap(\.items), now: now),
            timelineCards: timelineCards(from: trips),
            scheduleItems: items,
            trips: trips
        )
    }

    static func encode(
        ownerDisplayName: String,
        schedules: [PayPeriodSchedule],
        now: Date = Date()
    ) -> WebSchedulePayload {
        let legs = sortedLegs(from: schedules)
        let items = legs.compactMap(scheduleItem)
        return WebSchedulePayload(
            schemaVersion: legacyScheduleSchemaVersion,
            generatedAtUTC: formatUTC(now),
            owner: WebScheduleOwner(displayName: ownerDisplayName),
            currentTrip: currentTrip(from: legs, now: now),
            nextFlight: nextFlight(from: legs, now: now),
            timelineCards: [],
            scheduleItems: items,
            trips: []
        )
    }

    static func json(
        ownerDisplayName: String,
        crewAccessTrips: [CrewAccessTripJSON],
        now: Date = Date()
    ) throws -> String {
        let payload = encode(ownerDisplayName: ownerDisplayName, crewAccessTrips: crewAccessTrips, now: now)
        return try jsonString(from: payload)
    }

    static func json(
        ownerDisplayName: String,
        schedules: [PayPeriodSchedule],
        now: Date = Date()
    ) throws -> String {
        let payload = encode(ownerDisplayName: ownerDisplayName, schedules: schedules, now: now)
        return try jsonString(from: payload)
    }

    private static func jsonString(from payload: WebSchedulePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func webTrip(from trip: CrewAccessTripJSON) -> WebCrewAccessTrip {
        let sortedItems = trip.items
            .sorted { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.startUtc < rhs.startUtc
                }
                return lhs.sequence < rhs.sequence
            }
            .map(webTripItem)
        let airports = sortedItems.first.map { [$0.depAirport] + sortedItems.map(\.arrAirport) } ?? []
        let route = airports.reduce(into: [String]()) { result, airport in
            if result.last != airport { result.append(airport) }
        }.joined(separator: "-")
        return WebCrewAccessTrip(
            tripId: trip.tripId,
            tripInformationDate: trip.tripInformationDate,
            creditTime: trip.creditTime,
            tripDays: trip.tripDays,
            tafb: trip.tafb,
            dutyTotals: trip.dutyTotals,
            hotelDetails: trip.hotelDetails,
            route: route,
            startUTC: sortedItems.first?.startUTC,
            endUTC: sortedItems.last?.endUTC,
            items: sortedItems
        )
    }

    private static func webTripItem(from item: CrewAccessTripItemJSON) -> WebCrewAccessTripItem {
        WebCrewAccessTripItem(
            sequence: item.sequence,
            depAirport: item.depAirport,
            arrAirport: item.arrAirport,
            deadhead: item.deadhead,
            flight: item.flight,
            startUTC: item.startUtc,
            endUTC: item.endUtc,
            startLocalDisplay: item.startLocalDisplay,
            endLocalDisplay: item.endLocalDisplay,
            originTz: item.originTz,
            destinationTz: item.destinationTz,
            aircraft: item.aircraft,
            block: item.block,
            tailNumber: item.tailNumber
        )
    }

    private static func flattenScheduleItems(from trip: WebCrewAccessTrip) -> [WebScheduleItem] {
        trip.items.map { item in
            WebScheduleItem(
                id: "\(trip.tripId)-\(item.sequence)-\(item.flight)",
                type: item.deadhead ? "deadhead" : "flight",
                label: "\(item.flight) \(item.depAirport)-\(item.arrAirport)",
                startUTC: item.startUTC,
                endUTC: item.endUTC,
                departureAirport: item.depAirport,
                arrivalAirport: item.arrAirport
            )
        }
    }

    private static func timelineCards(from trips: [WebCrewAccessTrip]) -> [WebTimelineCard] {
        trips.flatMap { trip in
            var cards: [WebTimelineCard] = []
            let hotelByStation = hotelByStation(from: trip.hotelDetails, items: trip.items)
            for index in trip.items.indices {
                let item = trip.items[index]
                cards.append(flightTimelineCard(from: item, trip: trip))

                guard index < trip.items.index(before: trip.items.endIndex) else { continue }
                let next = trip.items[trip.items.index(after: index)]
                if let layover = layoverTimelineCard(
                    arrivingItem: item,
                    departingItem: next,
                    trip: trip,
                    hotelByStation: hotelByStation
                ) {
                    cards.append(layover)
                }
            }
            return cards
        }
    }

    private static func flightTimelineCard(from item: WebCrewAccessTripItem, trip: WebCrewAccessTrip) -> WebTimelineCard {
        let title = "\(item.depAirport) - \(item.arrAirport)"
        let flightText = displayFlightText(flight: item.flight, deadhead: item.deadhead)
        let blockText = "Block: \(item.block)"
        return WebTimelineCard(
            id: "\(trip.tripId)-flight-\(item.sequence)-\(item.flight)",
            type: "flight",
            dayKey: dayKey(fromUTC: item.startUTC),
            dayLabel: dayLabel(fromUTC: item.startUTC),
            tripId: trip.tripId,
            title: title,
            subtitle: flightText,
            timeRange: localTimeRange(start: item.startLocalDisplay, end: item.endLocalDisplay),
            detail: blockText,
            trailing: nil,
            icon: item.deadhead ? "paperplane" : "airplane",
            iconTone: "normal",
            startUTC: item.startUTC,
            endUTC: item.endUTC,
            station: nil,
            hotelName: nil
        )
    }

    private static func layoverTimelineCard(
        arrivingItem: WebCrewAccessTripItem,
        departingItem: WebCrewAccessTripItem,
        trip: WebCrewAccessTrip,
        hotelByStation: [String: String]
    ) -> WebTimelineCard? {
        guard normalizedAirport(arrivingItem.arrAirport) == normalizedAirport(departingItem.depAirport),
              let arrival = parseUTC(arrivingItem.endUTC),
              let departure = parseUTC(departingItem.startUTC) else { return nil }
        let minutes = Int(departure.timeIntervalSince(arrival) / 60)
        guard minutes >= minimumLayoverMinutes else { return nil }

        let station = normalizedAirport(arrivingItem.arrAirport)
        let hotel = hotelByStation[station]
        return WebTimelineCard(
            id: "\(trip.tripId)-layover-\(arrivingItem.sequence)-\(departingItem.sequence)",
            type: "layover",
            dayKey: dayKey(fromUTC: arrivingItem.endUTC),
            dayLabel: dayLabel(fromUTC: arrivingItem.endUTC),
            tripId: trip.tripId,
            title: "Layover at \(station)",
            subtitle: hotel,
            timeRange: nil,
            detail: nil,
            trailing: "Rest: \(durationHHMM(minutes: minutes))",
            icon: "hotel",
            iconTone: "normal",
            startUTC: arrivingItem.endUTC,
            endUTC: departingItem.startUTC,
            station: station,
            hotelName: hotel
        )
    }

    private static func hotelByStation(from details: [String], items: [WebCrewAccessTripItem]) -> [String: String] {
        var result: [String: String] = [:]
        for detail in details {
            let parsed = parseHotelDetail(detail)
            let station = normalizedAirport(parsed.station)
            if !station.isEmpty, !parsed.hotelName.isEmpty {
                result[station] = parsed.hotelName
            }
        }

        let legacyDetails = details.filter { $0.hasPrefix("Hotel details ") }
        var legacyIndex = 0
        for index in items.indices.dropLast() {
            guard legacyIndex < legacyDetails.count,
                  let nextIndex = items.index(index, offsetBy: 1, limitedBy: items.index(before: items.endIndex))
            else { break }
            let item = items[index]
            let next = items[nextIndex]
            guard let end = parseUTC(item.endUTC),
                  let nextStart = parseUTC(next.startUTC),
                  nextStart.timeIntervalSince(end) >= TimeInterval(minimumLayoverMinutes * 60) else {
                continue
            }
            let station = normalizedAirport(item.arrAirport)
            if result[station] == nil {
                let parsed = parseHotelDetail(legacyDetails[legacyIndex])
                if !parsed.hotelName.isEmpty {
                    result[station] = parsed.hotelName
                }
            }
            legacyIndex += 1
        }
        return result
    }

    private static func parseHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        if detail.hasPrefix("Hotel details ") {
            return parseLegacyHotelDetail(detail)
        }

        guard let colonRange = detail.range(of: ": ") else {
            return (detail.trimmingCharacters(in: .whitespaces), "")
        }
        let station = String(detail[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(detail[colonRange.upperBound...])
        if let parenRange = rest.range(of: " (", options: .backwards) {
            rest = String(rest[..<parenRange.lowerBound])
        }
        let words = rest.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return (station, hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    private static func parseLegacyHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        if let colonRange = detail.range(of: ": ") {
            let prefix = String(detail[..<colonRange.lowerBound])
            let station = prefix
                .replacingOccurrences(of: "Hotel details", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(detail[colonRange.upperBound...])
            let hotel = rest
                .components(separatedBy: " / ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (station, hotel)
        }

        guard let hotelRange = detail.range(of: "Hotel: ") else { return ("", "") }
        let afterHotel = String(detail[hotelRange.upperBound...])
        let hotelOnly: String
        if let transportRange = afterHotel.range(of: " Hotel Transport:") {
            hotelOnly = String(afterHotel[..<transportRange.lowerBound])
        } else {
            hotelOnly = afterHotel
        }

        let cleaned = hotelOnly
            .replacingOccurrences(of: " UPS Only", with: "")
            .replacingOccurrences(of: "UPS Only ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let digitCount = word.filter(\.isNumber).count
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || digitCount >= 3 || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return ("", hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    private static func currentTrip(from trips: [WebCrewAccessTrip], now: Date) -> WebCurrentTrip? {
        trips.compactMap { trip in
            guard let start = parseUTC(trip.startUTC),
                  let end = parseUTC(trip.endUTC),
                  start <= now,
                  now <= end else { return nil }
            return WebCurrentTrip(
                tripId: trip.tripId,
                startUTC: formatUTC(start),
                endUTC: formatUTC(end),
                displayLabel: trip.route
            )
        }
        .sorted { $0.startUTC < $1.startUTC }
        .first
    }

    private static func nextFlight(from items: [WebCrewAccessTripItem], now: Date) -> WebNextFlight? {
        guard let item = items
            .sorted(by: { $0.startUTC < $1.startUTC })
            .first(where: { (parseUTC($0.startUTC) ?? .distantPast) > now }),
              let departure = parseUTC(item.startUTC),
              let arrival = parseUTC(item.endUTC) else { return nil }
        return WebNextFlight(
            flightId: "\(item.sequence)-\(item.flight)-\(item.startUTC)",
            flightNumber: item.flight,
            departureAirport: item.depAirport,
            arrivalAirport: item.arrAirport,
            departureTimeUTC: formatUTC(departure),
            arrivalTimeUTC: formatUTC(arrival)
        )
    }

    private static func sortedLegs(from schedules: [PayPeriodSchedule]) -> [TripLeg] {
        schedules
            .flatMap(\.legs)
            .sorted { (startDate($0) ?? .distantFuture) < (startDate($1) ?? .distantFuture) }
    }

    private static func scheduleItem(from leg: TripLeg) -> WebScheduleItem? {
        guard let start = startUTCString(for: leg),
              let end = endUTCString(for: leg) else { return nil }
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
        let grouped = Dictionary(grouping: legs, by: \.pairing)

        return grouped.values
            .compactMap { tripLegs -> WebCurrentTrip? in
                let sorted = tripLegs.sorted {
                    (startDate($0) ?? .distantFuture) < (startDate($1) ?? .distantFuture)
                }
                guard let first = sorted.first,
                      let last = sorted.last,
                      let start = startDate(first),
                      let end = endDate(last),
                      start <= now,
                      now <= end else { return nil }

                let airports = ([first.depAirport] + sorted.map(\.arrAirport))
                    .reduce(into: [String]()) { result, airport in
                        if result.last != airport { result.append(airport) }
                    }
                return WebCurrentTrip(
                    tripId: first.pairing,
                    startUTC: formatUTC(start),
                    endUTC: formatUTC(end),
                    displayLabel: airports.joined(separator: "-")
                )
            }
            .sorted { $0.startUTC < $1.startUTC }
            .first
    }

    private static func nextFlight(from legs: [TripLeg], now: Date) -> WebNextFlight? {
        guard let leg = legs.first(where: { (startDate($0) ?? .distantPast) > now }),
              let departure = startDate(leg),
              let arrival = endDate(leg) else { return nil }
        return WebNextFlight(
            flightId: leg.id.uuidString,
            flightNumber: leg.flight,
            departureAirport: leg.depAirport,
            arrivalAirport: leg.arrAirport,
            departureTimeUTC: formatUTC(departure),
            arrivalTimeUTC: formatUTC(arrival)
        )
    }

    private static func startUTCString(for leg: TripLeg) -> String? {
        leg.depUTC ?? leg.stdUTC
    }

    private static func endUTCString(for leg: TripLeg) -> String? {
        leg.arrUTC ?? leg.staUTC
    }

    private static func displayFlightText(flight: String, deadhead: Bool) -> String {
        let trimmed = flight.trimmingCharacters(in: .whitespacesAndNewlines)
        if deadhead {
            return trimmed.isEmpty ? "DH" : "DH \(trimmed)"
        }
        if trimmed.uppercased().hasPrefix("5X") {
            return trimmed
        }
        return "5X\(trimmed)"
    }

    private static func localTimeRange(start: String, end: String) -> String {
        "\(timePart(from: start)) - \(timePart(from: end))\(dayShiftLabel(from: start, to: end))"
    }

    private static func timePart(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return trimmed
    }

    private static func dayShiftLabel(from start: String, to end: String) -> String {
        let startDay = String(start.prefix(10))
        let endDay = String(end.prefix(10))
        guard startDay != endDay,
              let startDate = SharedDateFormatters.utcDayOnly.date(from: startDay),
              let endDate = SharedDateFormatters.utcDayOnly.date(from: endDay)
        else { return "" }
        let diff = Calendar(identifier: .gregorian).dateComponents([.day], from: startDate, to: endDate).day ?? 0
        guard diff != 0 else { return "" }
        let sign = diff > 0 ? "+" : ""
        return " (\(sign)\(diff)d)"
    }

    private static func durationHHMM(minutes: Int) -> String {
        let safeMinutes = max(0, minutes)
        return "\(safeMinutes / 60):\(String(format: "%02d", safeMinutes % 60))"
    }

    private static func normalizedAirport(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func dayKey(fromUTC value: String) -> String {
        guard let date = parseUTC(value) else {
            return String(value.prefix(10))
        }
        return SharedDateFormatters.utcDayOnly.string(from: date)
    }

    private static func dayLabel(fromUTC value: String) -> String {
        guard let date = parseUTC(value) else {
            return String(value.prefix(10))
        }
        return utcDayHeaderFormatter.string(from: date)
    }

    private static func startDate(_ leg: TripLeg) -> Date? {
        parseUTC(startUTCString(for: leg))
    }

    private static func endDate(_ leg: TripLeg) -> Date? {
        parseUTC(endUTCString(for: leg))
    }

    private static func parseUTC(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func formatUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static let utcDayHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, MMM d yyyy"
        return formatter
    }()
}
