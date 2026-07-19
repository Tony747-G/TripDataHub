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
    case hotel
    case groundTransport
    case report
    case release
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
    static let schemaVersion = "1.0"

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

        var events = try payload.items.map { item in
            try flightEvent(item, tripID: tripID)
        }
        events.append(contentsOf: try hotelEvents(for: schedule, tripID: tripID))
        events.sort(by: eventSort)

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
        let digits = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .compactMap { character -> String? in
                guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
                return String(value)
            }
            .joined()
        guard !digits.isEmpty else { throw TripJSONExportError.invalidOwnerGEMS }
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
        let fallbackCrew = matchingCrew ?? (payload.crew.count == 1 ? payload.crew.first : nil)

        let rawGEMS = firstNonempty(source.profileGEMS, source.verifiedGEMS, fallbackCrew?.crewID ?? "")
        let gems = try normalizedGEMS(rawGEMS)
        let name = resolvedOwnerName(
            profileDisplayName: source.profileName,
            profileGivenName: source.profileGivenName,
            profileFamilyName: source.profileFamilyName,
            verifiedName: source.verifiedName,
            matchingCrewName: matchingCrew?.name ?? "",
            fallbackCrewName: fallbackCrew?.name ?? ""
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
            source.verifiedPosition,
            fallbackCrew?.position ?? ""
        ))

        guard !name.isEmpty else { throw TripJSONExportError.missingOwnerField("name") }
        guard !base.isEmpty else { throw TripJSONExportError.missingOwnerField("base") }
        guard !fleet.isEmpty else { throw TripJSONExportError.missingOwnerField("fleet") }
        guard !position.isEmpty else { throw TripJSONExportError.missingOwnerField("position") }

        return ExportOwner(name: name, gems: gems, base: base, fleet: fleet, position: position)
    }

    private static func flightEvent(_ item: CrewAccessTripItemJSON, tripID: String) throws -> ExportEvent {
        let type: ExportEventType = item.deadhead ? .deadhead : .flight
        let origin = normalizedIdentifier(item.depAirport)
        let destination = normalizedIdentifier(item.arrAirport)
        let start = try exportTimestamp(item.startUtc, timeZoneID: item.originTz)
        let end = try exportTimestamp(item.endUtc, timeZoneID: item.destinationTz)
        return ExportEvent(
            id: "event-\(tripID)-\(type.rawValue)-\(item.sequence)",
            type: type,
            sequence: item.sequence,
            start: start,
            end: end,
            flightNumber: nilIfEmpty(item.flight),
            origin: nilIfEmpty(origin),
            destination: nilIfEmpty(destination),
            aircraft: nilIfEmpty(item.aircraft),
            blockTime: nilIfEmpty(item.block),
            station: nil,
            hotelName: nil
        )
    }

    private static func hotelEvents(
        for schedule: PayPeriodSchedule,
        tripID: String
    ) throws -> [ExportEvent] {
        let orderedLegs = schedule.legs.sorted { lhs, rhs in
            (lhs.depUTC ?? "", lhs.leg, lhs.id.uuidString) < (rhs.depUTC ?? "", rhs.leg, rhs.id.uuidString)
        }
        var events: [ExportEvent] = []
        for (index, leg) in orderedLegs.enumerated() {
            guard let hotelName = nilIfEmpty(leg.layoverHotelName ?? ""),
                  let startUTC = leg.arrUTC,
                  orderedLegs.indices.contains(index + 1),
                  let endUTC = orderedLegs[index + 1].depUTC
            else { continue }
            let station = normalizedIdentifier(leg.layoverStation ?? leg.arrAirport)
            let timeZoneID = IATATimeZoneResolver.shared.resolve(station)
            let sequence = leg.leg
            events.append(ExportEvent(
                id: "event-\(tripID)-hotel-\(sequence)",
                type: .hotel,
                sequence: sequence,
                start: try exportTimestamp(startUTC, timeZoneID: timeZoneID),
                end: try exportTimestamp(endUTC, timeZoneID: timeZoneID),
                flightNumber: nil,
                origin: nil,
                destination: nil,
                aircraft: nil,
                blockTime: nil,
                station: nilIfEmpty(station),
                hotelName: hotelName
            ))
        }
        return events
    }

    private static func exportTimestamp(
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

    private static func parseInstant(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func utcString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func eventSort(_ lhs: ExportEvent, _ rhs: ExportEvent) -> Bool {
        (lhs.start.instant, lhs.sequence, lhs.id) < (rhs.start.instant, rhs.sequence, rhs.id)
    }

    private static func normalizedOwnerName(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ").uppercased()
    }

    private static func resolvedOwnerName(
        profileDisplayName: String,
        profileGivenName: String,
        profileFamilyName: String,
        verifiedName: String,
        matchingCrewName: String,
        fallbackCrewName: String
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
        let normalizedFallbackCrewName = publicOrderCrewName(
            normalizedOwnerName(fallbackCrewName),
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
                normalizedMatchingCrewName,
                normalizedFallbackCrewName
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

    private static func normalizedPosition(_ value: String) -> String {
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
        default: return compact
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

    private static func stableIDComponent(_ value: String) -> String {
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
