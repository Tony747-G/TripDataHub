import Foundation

struct TripDataHubExport: Codable, Equatable, Sendable {
    let schemaVersion: String
    let exportedAt: String
    let generator: ExportGenerator
    let owner: ExportOwner
    let trip: ExportTrip
    let events: [ExportEvent]
}

struct ExportGenerator: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let build: String
}

struct ExportOwner: Codable, Equatable, Sendable {
    let name: String
    let gems: String
    let base: String
    let fleet: String
    let position: String
}

struct ExportTrip: Codable, Equatable, Sendable {
    let id: String
    let tripNumber: String
    let title: String
    let start: ExportTimestamp
    let end: ExportTimestamp
    let base: String
    let status: String
}

struct ExportTimestamp: Codable, Equatable, Sendable {
    let instant: String
    let local: String
    let timeZone: String
    let utcOffset: String
}

enum ExportEventType: String, Codable, Equatable, Sendable {
    case flight
    case deadhead
    case layover
    case hotel
    case groundTransport
    case report
    case release
}

struct ExportDerivedInterval: Codable, Equatable, Sendable {
    let start: ExportTimestamp
    let end: ExportTimestamp
    let durationMinutes: Int
    let derived: Bool
    let derivation: String
}

struct ExportScheduledRest: Codable, Equatable, Sendable {
    let dutyEnd: ExportTimestamp
    let nextDutyStart: ExportTimestamp
    let durationMinutes: Int
    let derived: Bool
    let calculationRule: ExportScheduledRestCalculationRule
}

struct ExportScheduledRestCalculationRule: Codable, Equatable, Sendable {
    let dutyEndMinutesAfterBlockIn: Int
    let dutyStartMinutesBeforeBlockOut: Int
}

struct ExportHotelStay: Codable, Equatable, Sendable {
    let checkIn: ExportTimestamp
    let checkOut: ExportTimestamp
    let durationMinutes: Int
}

struct ExportHotel: Codable, Equatable, Sendable {
    let name: String?
    let address: String?
    let phone: String?
    let sourceName: String?
    let nameNormalization: ExportHotelNameNormalization?

    init(
        name: String?,
        address: String?,
        phone: String?,
        sourceName: String? = nil,
        nameNormalization: ExportHotelNameNormalization? = nil
    ) {
        self.name = name
        self.address = address
        self.phone = phone
        self.sourceName = sourceName
        self.nameNormalization = nameNormalization
    }
}

struct ExportHotelNameNormalization: Codable, Equatable, Sendable {
    let derived: Bool
    let method: String
    let matchedBy: String
}

struct ExportEvent: Codable, Equatable, Sendable {
    let id: String
    let type: ExportEventType
    let sequence: Int
    let start: ExportTimestamp
    let end: ExportTimestamp
    let flightNumber: String?
    let origin: String?
    let destination: String?
    let aircraft: String?
    let blockTime: String?
    let station: String?
    let hotelName: String?
    let previousSegmentID: String?
    let nextSegmentID: String?
    let blockGap: ExportDerivedInterval?
    let scheduledRest: ExportScheduledRest?
    let hotelStay: ExportHotelStay?
    let hotel: ExportHotel?

    init(
        id: String,
        type: ExportEventType,
        sequence: Int,
        start: ExportTimestamp,
        end: ExportTimestamp,
        flightNumber: String? = nil,
        origin: String? = nil,
        destination: String? = nil,
        aircraft: String? = nil,
        blockTime: String? = nil,
        station: String? = nil,
        hotelName: String? = nil,
        previousSegmentID: String? = nil,
        nextSegmentID: String? = nil,
        blockGap: ExportDerivedInterval? = nil,
        scheduledRest: ExportScheduledRest? = nil,
        hotelStay: ExportHotelStay? = nil,
        hotel: ExportHotel? = nil
    ) {
        self.id = id
        self.type = type
        self.sequence = sequence
        self.start = start
        self.end = end
        self.flightNumber = flightNumber
        self.origin = origin
        self.destination = destination
        self.aircraft = aircraft
        self.blockTime = blockTime
        self.station = station
        self.hotelName = hotelName
        self.previousSegmentID = previousSegmentID
        self.nextSegmentID = nextSegmentID
        self.blockGap = blockGap
        self.scheduledRest = scheduledRest
        self.hotelStay = hotelStay
        self.hotel = hotel
    }
}

struct TripJSONExportOwnerSource: Equatable, Sendable {
    let profileName: String
    let profileGivenName: String
    let profileFamilyName: String
    let profileGEMS: String
    let profileBase: String
    let profileFleet: String
    let profilePosition: String
    let verifiedName: String
    let verifiedGEMS: String
    let verifiedBase: String
    let verifiedFleet: String
    let verifiedPosition: String
}

struct TripJSONExportOutput: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let temporaryDirectory: URL
}

enum TripJSONExportError: LocalizedError, Equatable {
    case tripDataUnavailable
    case invalidTimestamp(String)
    case missingOwnerField(String)
    case invalidOwnerGEMS
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .tripDataUnavailable:
            return "The stored JSON data for this trip is unavailable. Try importing the CrewAccess PDF again."
        case let .invalidTimestamp(value):
            return "The trip contains an invalid operational timestamp: \(value)."
        case let .missingOwnerField(field):
            return "The trip owner’s \(field) is unavailable. Update Profile and try again."
        case .invalidOwnerGEMS:
            return "The trip owner’s GEMS identifier is unavailable or invalid. Update Profile and try again."
        case .invalidUTF8:
            return "The generated JSON could not be represented as UTF-8."
        }
    }
}

enum TripJSONExportService {
    static let schemaVersion = "1.2"

    static func payload(
        for schedule: PayPeriodSchedule,
        candidates: [CrewAccessTripJSON]
    ) -> CrewAccessTripJSON? {
        let tripIDs = Set(schedule.legs.map { normalizedIdentifier($0.pairing) }.filter { !$0.isEmpty })
        let matching = candidates.filter { tripIDs.contains(normalizedIdentifier($0.tripId)) }
        guard matching.count > 1 else { return matching.first }

        let scheduleStart = schedule.legs.compactMap(\.depUTC).min()
        if let exactStartMatch = matching.first(where: { payload in
            payload.items.map(\.startUtc).min() == scheduleStart
        }) {
            return exactStartMatch
        }

        let scheduleDate = scheduleStart.flatMap(dateComponent)
        return matching.first(where: { payload in
            dateComponent(payload.tripInformationDate) == scheduleDate
        }) ?? matching.first
    }

    static func generator(bundle: Bundle = .main) -> ExportGenerator {
        ExportGenerator(
            name: "TripDataHub",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    static func publicExport(
        for schedule: PayPeriodSchedule,
        payload: CrewAccessTripJSON,
        ownerSource: TripJSONExportOwnerSource,
        generator: ExportGenerator = generator(),
        exportedAt: Date = Date()
    ) throws -> TripDataHubExport {
        let owner = try exportOwner(from: ownerSource, payload: payload)
        let tripNumber = normalizedIdentifier(payload.tripId)
        guard !tripNumber.isEmpty else { throw TripJSONExportError.tripDataUnavailable }

        let tripDate = dateComponent(payload.tripInformationDate)
            ?? payload.items.compactMap { dateComponent($0.startUtc) }.min()
            ?? "unknown-date"
        let tripID = "trip-\(stableIDComponent(tripNumber))-\(tripDate.lowercased())"

        let events = try publicEvents(
            payload: payload,
            schedule: schedule,
            tripID: tripID
        )

        guard let firstEvent = events.first,
              let lastEvent = events.max(by: { $0.end.instant < $1.end.instant })
        else {
            throw TripJSONExportError.tripDataUnavailable
        }

        let trip = ExportTrip(
            id: tripID,
            tripNumber: tripNumber,
            title: tripNumber,
            start: firstEvent.start,
            end: lastEvent.end,
            base: owner.base,
            status: "scheduled"
        )

        return TripDataHubExport(
            schemaVersion: schemaVersion,
            exportedAt: utcString(exportedAt),
            generator: generator,
            owner: owner,
            trip: trip,
            events: events
        )
    }

    static func normalizedGEMS(_ source: String) throws -> String {
        let digits = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty,
              digits.allSatisfy({ character in
                  guard let value = character.wholeNumberValue else { return false }
                  return (0...9).contains(value)
              }) else {
            throw TripJSONExportError.invalidOwnerGEMS
        }
        if digits.count < GEMSIDNormalizer.canonicalLength {
            return String(repeating: "0", count: GEMSIDNormalizer.canonicalLength - digits.count) + digits
        }
        return digits
    }

    static func encodedData(for export: TripDataHubExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        guard String(data: data, encoding: .utf8) != nil else {
            throw TripJSONExportError.invalidUTF8
        }
        return data
    }

    static func filename(for export: TripDataHubExport) -> String {
        let identifier = sanitizedFilenameComponent(export.trip.tripNumber, fallback: "trip")
        let startDate = dateComponent(export.trip.start.instant) ?? "unknown-date"
        return "TDH_\(identifier)_\(startDate).json"
    }

    static func makeTemporaryFile(
        for schedule: PayPeriodSchedule,
        payload: CrewAccessTripJSON,
        ownerSource: TripJSONExportOwnerSource,
        generator: ExportGenerator = generator(),
        exportedAt: Date = Date(),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> TripJSONExportOutput {
        let export = try publicExport(
            for: schedule,
            payload: payload,
            ownerSource: ownerSource,
            generator: generator,
            exportedAt: exportedAt
        )
        let directory = temporaryRoot
            .appendingPathComponent("TDHExport_\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(filename(for: export), isDirectory: false)
            try encodedData(for: export).write(to: fileURL, options: .atomic)
            return TripJSONExportOutput(url: fileURL, temporaryDirectory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    static func removeTemporaryFiles(
        for output: TripJSONExportOutput,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: output.temporaryDirectory)
    }

    private static func exportOwner(
        from source: TripJSONExportOwnerSource,
        payload: CrewAccessTripJSON
    ) throws -> ExportOwner {
        let canonicalGEMS = firstNonempty(source.profileGEMS, source.verifiedGEMS)
        let matchingCrew = payload.crew.first { crew in
            guard !canonicalGEMS.isEmpty else { return false }
            return crewGEMS(crew.crewID, matchesCanonical: canonicalGEMS)
        }

        // Never infer the owner from an arbitrary sole crew member. Crew data may be used only
        // after its GEMS ID matches the canonical Profile/verified identity.
        let rawGEMS = firstNonempty(source.profileGEMS, source.verifiedGEMS)
        let gems = try normalizedGEMS(rawGEMS)
        let name = resolvedOwnerName(
            profileDisplayName: source.profileName,
            profileGivenName: source.profileGivenName,
            profileFamilyName: source.profileFamilyName,
            verifiedName: source.verifiedName,
            matchingCrewName: matchingCrew?.name ?? ""
        )
        let base = firstNonempty(source.profileBase, source.verifiedBase).uppercased()
        let fleet = firstNonempty(
            source.profileFleet,
            source.verifiedFleet,
            consistentOperatingFleet(in: payload)
        ).uppercased()
        let position = normalizedPosition(firstNonempty(
            source.profilePosition,
            matchingCrew?.position ?? "",
            source.verifiedPosition
        )) ?? ""

        guard !name.isEmpty else { throw TripJSONExportError.missingOwnerField("name") }
        guard !base.isEmpty else { throw TripJSONExportError.missingOwnerField("base") }
        guard !fleet.isEmpty else { throw TripJSONExportError.missingOwnerField("fleet") }
        guard !position.isEmpty else { throw TripJSONExportError.missingOwnerField("position") }

        return ExportOwner(name: name, gems: gems, base: base, fleet: fleet, position: position)
    }

    private static func flightEvent(
        _ item: CrewAccessTripItemJSON,
        tripID: String,
        sequence: Int
    ) throws -> ExportEvent {
        let type: ExportEventType = item.deadhead ? .deadhead : .flight
        let origin = normalizedIdentifier(item.depAirport)
        let destination = normalizedIdentifier(item.arrAirport)
        let start = try exportTimestamp(item.startUtc, timeZoneID: item.originTz)
        let end = try exportTimestamp(item.endUtc, timeZoneID: item.destinationTz)
        return ExportEvent(
            id: "event-\(tripID)-\(type.rawValue)-\(sequence)",
            type: type,
            sequence: sequence,
            start: start,
            end: end,
            flightNumber: nilIfEmpty(item.flight),
            origin: nilIfEmpty(origin),
            destination: nilIfEmpty(destination),
            aircraft: nilIfEmpty(item.aircraft),
            blockTime: nilIfEmpty(item.block)
        )
    }

    static func publicEvents(
        payload: CrewAccessTripJSON,
        schedule: PayPeriodSchedule,
        tripID: String
    ) throws -> [ExportEvent] {
        // Ground transportation remains a deferred schema type. The parser does not retain
        // reliable structured transport details, so a GND row must not be mislabeled as a
        // flight or emitted as a partially invented groundTransport event.
        let items = payload.items.sorted { lhs, rhs in
            (lhs.startUtc, lhs.sequence, lhs.flight) < (rhs.startUtc, rhs.sequence, rhs.flight)
        }
        let payloadTripID = normalizedIdentifier(payload.tripId)
        let scheduleTripLegs = schedule.legs.filter {
            normalizedIdentifier($0.pairing) == payloadTripID
        }
        let rawHotels = parsedHotels(from: payload.hotelDetails)
        var events: [ExportEvent] = []
        var nextSequence = 1
        var legacyHotelIndex = 0

        for index in items.indices {
            let item = items[index]
            guard !isGroundTransport(item) else {
                continue
            }
            let flight = try flightEvent(
                item,
                tripID: tripID,
                sequence: nextSequence
            )
            events.append(flight)
            nextSequence += 1

            let remainingItems = items.suffix(from: index + 1)
            guard let nextIndex = remainingItems.firstIndex(where: {
                !isGroundTransport($0)
            }) else { continue }
            let nextItem = items[nextIndex]
            guard hasContinuousStationChain(
                from: item,
                through: items[(index + 1)..<nextIndex],
                to: nextItem
            ),
                  let blockIn = parseInstant(item.endUtc),
                  let nextBlockOut = parseInstant(nextItem.startUtc),
                  nextBlockOut > blockIn
            else { continue }

            let nextType: ExportEventType = nextItem.deadhead ? .deadhead : .flight
            let nextSegmentID = "event-\(tripID)-\(nextType.rawValue)-\(nextSequence + 1)"
            let station = normalizedIdentifier(item.arrAirport)
            let start = try exportTimestamp(item.endUtc, timeZoneID: item.destinationTz)
            let end = try exportTimestamp(nextItem.startUtc, timeZoneID: nextItem.originTz)
            let durationMinutes = Int(nextBlockOut.timeIntervalSince(blockIn) / 60)
            let scheduleLeg = scheduleTripLegs.first {
                $0.leg == item.sequence && $0.depUTC == item.startUtc
            } ?? scheduleTripLegs.first {
                $0.leg == item.sequence
            }
            let hasStructuredLayover = [
                scheduleLeg?.layoverStation,
                scheduleLeg?.layoverHotelName,
                scheduleLeg?.layoverDuration
            ].contains { nilIfEmpty($0 ?? "") != nil }
            let crossesTripDay = nextItem.sequence > item.sequence
            let crossesTripDayWithLayoverInterval = crossesTripDay && durationMinutes > 10 * 60
            guard crossesTripDayWithLayoverInterval || hasStructuredLayover else { continue }

            let hotel = resolvedHotel(
                station: station,
                scheduleName: scheduleLeg?.layoverHotelName,
                rawHotels: rawHotels,
                legacyIndex: &legacyHotelIndex
            )
            events.append(ExportEvent(
                id: "event-\(tripID)-layover-\(nextSequence)",
                type: .layover,
                sequence: nextSequence,
                start: start,
                end: end,
                station: nilIfEmpty(station),
                previousSegmentID: flight.id,
                nextSegmentID: nextSegmentID,
                blockGap: ExportDerivedInterval(
                    start: start,
                    end: end,
                    durationMinutes: durationMinutes,
                    derived: true,
                    derivation: "previousSegment.end_to_nextSegment.start"
                ),
                scheduledRest: try scheduledRest(
                    blockIn: blockIn,
                    nextBlockOut: nextBlockOut,
                    dutyEndTimeZoneID: item.destinationTz,
                    nextDutyStartTimeZoneID: nextItem.originTz
                ),
                hotel: hotel
            ))
            nextSequence += 1
        }
        return events
    }

    private static func isGroundTransport(_ item: CrewAccessTripItemJSON) -> Bool {
        item.flight.caseInsensitiveCompare("GND") == .orderedSame
    }

    private static func hasContinuousStationChain(
        from item: CrewAccessTripItemJSON,
        through intermediateItems: ArraySlice<CrewAccessTripItemJSON>,
        to nextItem: CrewAccessTripItemJSON
    ) -> Bool {
        var station = normalizedIdentifier(item.arrAirport)
        guard !station.isEmpty else { return false }

        for intermediate in intermediateItems {
            guard isGroundTransport(intermediate),
                  station == normalizedIdentifier(intermediate.depAirport) else {
                return false
            }
            station = normalizedIdentifier(intermediate.arrAirport)
        }
        return station == normalizedIdentifier(nextItem.depAirport)
    }

    static func scheduledRest(
        blockIn: Date,
        nextBlockOut: Date,
        dutyEndTimeZoneID: String?,
        nextDutyStartTimeZoneID: String?
    ) throws -> ExportScheduledRest? {
        let rule = ExportScheduledRestCalculationRule(
            dutyEndMinutesAfterBlockIn: 30,
            dutyStartMinutesBeforeBlockOut: 90
        )
        let dutyEndDate = blockIn.addingTimeInterval(
            TimeInterval(rule.dutyEndMinutesAfterBlockIn * 60)
        )
        let nextDutyStartDate = nextBlockOut.addingTimeInterval(
            TimeInterval(-rule.dutyStartMinutesBeforeBlockOut * 60)
        )
        guard nextDutyStartDate > dutyEndDate else { return nil }

        return ExportScheduledRest(
            dutyEnd: try exportTimestamp(
                utcString(dutyEndDate),
                timeZoneID: dutyEndTimeZoneID
            ),
            nextDutyStart: try exportTimestamp(
                utcString(nextDutyStartDate),
                timeZoneID: nextDutyStartTimeZoneID
            ),
            durationMinutes: Int(nextDutyStartDate.timeIntervalSince(dutyEndDate) / 60),
            derived: true,
            calculationRule: rule
        )
    }

    private struct ParsedHotel {
        let station: String?
        let name: String?
        let phone: String?
    }

    private static func parsedHotels(from details: [String]) -> [ParsedHotel] {
        details.compactMap { detail in
            let normalized = detail
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            guard !normalized.isEmpty else { return nil }

            if normalized.hasPrefix("Hotel details ") {
                guard let hotelRange = normalized.range(of: "Hotel: ") else { return nil }
                var hotelPart = String(normalized[hotelRange.upperBound...])
                if let transportRange = hotelPart.range(of: " Hotel Transport:") {
                    hotelPart = String(hotelPart[..<transportRange.lowerBound])
                }
                let phone = firstPhone(in: hotelPart)
                let name = hotelName(before: phone, in: hotelPart)
                    .replacingOccurrences(of: " UPS Only", with: "")
                    .replacingOccurrences(of: "UPS Only ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ParsedHotel(station: nil, name: nilIfEmpty(name), phone: phone)
            }

            guard let colon = normalized.range(of: ":") else { return nil }
            let station = normalizedIdentifier(String(normalized[..<colon.lowerBound]))
            let hotelPart = String(normalized[colon.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = firstPhone(in: hotelPart)
            let name = hotelName(before: phone, in: hotelPart)
            return ParsedHotel(
                station: nilIfEmpty(station),
                name: nilIfEmpty(name),
                phone: phone
            )
        }
    }

    private static func resolvedHotel(
        station: String,
        scheduleName: String?,
        rawHotels: [ParsedHotel],
        legacyIndex: inout Int
    ) -> ExportHotel? {
        let stationMatch = rawHotels.first { $0.station == station }
        let legacyHotels = rawHotels.filter { $0.station == nil }
        let source: ParsedHotel?
        if let stationMatch {
            source = stationMatch
        } else if legacyHotels.indices.contains(legacyIndex) {
            source = legacyHotels[legacyIndex]
            legacyIndex += 1
        } else {
            source = nil
        }
        // Prefer the retained PDF value so public export does not inherit older
        // display-only prefix normalization from TripLeg enrichment.
        let sourceName = source?.name ?? nilIfEmpty(scheduleName ?? "") ?? ""
        let normalizedName = HotelNameNormalizer.publicName(
            station: station,
            rawName: sourceName,
            phone: source?.phone
        )
        let name = nilIfEmpty(normalizedName.name)
        guard name != nil || source?.phone != nil else { return nil }
        let normalization = normalizedName.matchedBy.map {
            ExportHotelNameNormalization(
                derived: true,
                method: "knownHotelDirectory",
                matchedBy: $0
            )
        }
        return ExportHotel(
            name: name,
            address: nil,
            phone: source?.phone,
            sourceName: normalizedName.sourceName,
            nameNormalization: normalization
        )
    }

    private static func firstPhone(in value: String) -> String? {
        let patterns = [
            #"\+\d[\d\s-]{5,}\d"#,
            #"\b011[-\s]?\d[\d\s-]{5,}\d"#,
            #"\b[2-9]\d{2}-\d{3}-\d{4}\b"#
        ]
        for pattern in patterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                return String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func hotelName(before phone: String?, in value: String) -> String {
        guard let phone, let range = value.range(of: phone) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func exportTimestamp(
        _ instantValue: String,
        timeZoneID: String?
    ) throws -> ExportTimestamp {
        guard let date = parseInstant(instantValue) else {
            throw TripJSONExportError.invalidTimestamp(instantValue)
        }
        let timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
        let localFormatter = DateFormatter()
        localFormatter.calendar = Calendar(identifier: .gregorian)
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = timeZone
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        let offsetString = String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        return ExportTimestamp(
            instant: utcString(date),
            local: localFormatter.string(from: date),
            timeZone: timeZone.identifier,
            utcOffset: offsetString
        )
    }

    static func parseInstant(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    static func utcString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func normalizedOwnerName(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ").uppercased()
    }

    private static func resolvedOwnerName(
        profileDisplayName: String,
        profileGivenName: String,
        profileFamilyName: String,
        verifiedName: String,
        matchingCrewName: String
    ) -> String {
        let canonicalDisplayName = normalizedOwnerName(profileDisplayName)
        let combinedProfileName = normalizedOwnerName(
            [profileGivenName, profileFamilyName]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
        )
        let normalizedVerifiedName = normalizedOwnerName(verifiedName)
        let givenNameHint = normalizedOwnerName(profileGivenName).isEmpty
            ? (isSingleName(canonicalDisplayName) ? canonicalDisplayName : "")
            : normalizedOwnerName(profileGivenName)
        let normalizedMatchingCrewName = publicOrderCrewName(
            normalizedOwnerName(matchingCrewName),
            givenNameHint: givenNameHint
        )
        return [
            canonicalDisplayName,
            combinedProfileName,
            normalizedVerifiedName,
            normalizedMatchingCrewName
        ].first(where: isCompletePublicName)
            ?? firstNonempty(
                canonicalDisplayName,
                combinedProfileName,
                normalizedVerifiedName,
                normalizedMatchingCrewName
            )
    }

    private static func isCompletePublicName(_ value: String) -> Bool {
        let components = value.split(whereSeparator: \Character.isWhitespace)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            component.contains(where: \Character.isLetter)
        }
    }

    private static func isSingleName(_ value: String) -> Bool {
        value.split(whereSeparator: \Character.isWhitespace).count == 1
    }

    private static func publicOrderCrewName(_ value: String, givenNameHint: String) -> String {
        let components = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
        let givenComponents = givenNameHint
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !components.isEmpty,
              givenComponents.count == 1,
              let givenIndex = components.firstIndex(of: givenComponents[0]),
              givenIndex != components.startIndex
        else { return value }

        var ordered = components
        let givenName = ordered.remove(at: givenIndex)
        ordered.insert(givenName, at: ordered.startIndex)
        return ordered.joined(separator: " ")
    }

    static func normalizedPosition(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch compact {
        case "CAPTAIN", "CAPT", "CPT", "CA": return "CA"
        case "FIRSTOFFICER", "FO": return "FO"
        case "SECOND OFFICER", "SECONDOFFICER", "SO": return "SO"
        default: return compact.isEmpty ? nil : compact
        }
    }

    private static func crewGEMS(_ rawValue: String, matchesCanonical canonical: String) -> Bool {
        guard let raw = try? normalizedGEMS(rawValue),
              let normalizedCanonical = try? normalizedGEMS(canonical)
        else { return false }
        if raw == normalizedCanonical { return true }
        guard raw.count > normalizedCanonical.count,
              raw.hasSuffix(normalizedCanonical)
        else { return false }
        return raw.dropLast(normalizedCanonical.count).allSatisfy { $0 == "0" }
    }

    private static func consistentOperatingFleet(in payload: CrewAccessTripJSON) -> String {
        let fleets = Set(payload.items.filter { !$0.deadhead }.map(\.aircraft).filter { !$0.isEmpty })
        return fleets.count == 1 ? fleets.first ?? "" : ""
    }

    private static func firstNonempty(_ values: String...) -> String {
        values.first { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return !normalized.isEmpty && normalized != "-" && normalized != "UNKNOWN"
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func dateComponent(_ value: String) -> String? {
        guard let range = value.range(
            of: #"\d{4}-\d{2}-\d{2}"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(value[range])
    }

    static func stableIDComponent(_ value: String) -> String {
        sanitizedFilenameComponent(value.lowercased(), fallback: "trip")
    }

    private static func sanitizedFilenameComponent(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        var result = ""
        var lastWasSeparator = false
        for scalar in scalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator && !result.isEmpty {
                result.append("-")
                lastWasSeparator = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return result.isEmpty ? fallback : result
    }
}
