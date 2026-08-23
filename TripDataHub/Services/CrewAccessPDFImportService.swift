import Foundation
import PDFKit
import os

private let logger = Logger(subsystem: "com.sfune.TripDataHub", category: "Import")

protocol CrewAccessPDFImportServiceProtocol: Sendable {
    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft
}

struct CrewAccessImportDraft {
    let sourceFileName: String?
    let tripId: String
    let tripDate: String
    let parsedSchedule: PayPeriodSchedule?
    let jsonPayload: CrewAccessTripJSON?
    let warnings: [ImportWarning]
    let errors: [ImportErrorItem]
    let rawExtractStats: RawExtractStats
}

struct PendingImport: Identifiable {
    let id: UUID
    let source: PendingImportSource
    let sourceFileName: String?
    let tripId: String
    let tripDate: String
    let parsedSchedule: PayPeriodSchedule?
    let jsonPayload: CrewAccessTripJSON?
    let warnings: [ImportWarning]
    let errors: [ImportErrorItem]
    let createdAt: Date
    let rawExtractStats: RawExtractStats

    var canConfirm: Bool {
        errors.isEmpty && parsedSchedule != nil && jsonPayload != nil
    }
}

enum PendingImportSource: String {
    case crewAccessPDF = "crewaccess-pdf"
}

struct RawExtractStats {
    let pageCount: Int
    let characterCount: Int
    let lineCount: Int
}

enum ImportErrorCode: String {
    case pdfTextEmpty
    case schemaMismatch
    case missingRequiredFields
    case utcParseFailed
    case ltToUtcNeedsTzButMissing
    case actualTimeAmbiguous
    case actualTimeInvalid
}

struct ImportErrorItem: Identifiable {
    let id = UUID()
    let code: ImportErrorCode
    let message: String
    let remediation: String
}

enum ImportWarningCode: String {
    case unknownIata
    case unknownTz
    case partialLegParseFailed
    case lowConfidence
    case dstBoundaryCrossing

    var displayTitle: String {
        switch self {
        case .unknownIata:
            return "Unknown airport code"
        case .unknownTz:
            return "Missing timezone mapping"
        case .partialLegParseFailed:
            return "Some PDF rows could not be imported"
        case .lowConfidence:
            return "Low confidence parse"
        case .dstBoundaryCrossing:
            return "Daylight saving time boundary"
        }
    }

    var displayGuidance: String {
        switch self {
        case .unknownIata, .unknownTz:
            return "Check the affected airport and add a timezone override if needed."
        case .partialLegParseFailed:
            return "Compare the previewed legs with CrewAccess before confirming."
        case .lowConfidence:
            return "Review the imported trip carefully before confirming."
        case .dstBoundaryCrossing:
            return "Verify the local and UTC times around the daylight saving time change."
        }
    }
}

struct ImportWarning: Identifiable {
    let id = UUID()
    let code: ImportWarningCode
    let message: String
}

struct CrewAccessTripJSON: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let source: String
    let sourceVersion: String
    let mappingVersion: String
    let generatedAt: String
    let pdfCreatedUtc: String?
    let tripId: String
    let tripInformationDate: String
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
    let dutyTotals: [String]
    let hotelDetails: [String]
    let crew: [CrewAccessCrewJSON]
    let items: [CrewAccessTripItemJSON]

    init(
        schemaVersion: Int,
        source: String,
        sourceVersion: String,
        mappingVersion: String,
        generatedAt: String,
        pdfCreatedUtc: String? = nil,
        tripId: String,
        tripInformationDate: String,
        creditTime: String?,
        tripDays: String?,
        tafb: String?,
        dutyTotals: [String],
        hotelDetails: [String],
        crew: [CrewAccessCrewJSON],
        items: [CrewAccessTripItemJSON]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.sourceVersion = sourceVersion
        self.mappingVersion = mappingVersion
        self.generatedAt = generatedAt
        self.pdfCreatedUtc = pdfCreatedUtc
        self.tripId = tripId
        self.tripInformationDate = tripInformationDate
        self.creditTime = creditTime
        self.tripDays = tripDays
        self.tafb = tafb
        self.dutyTotals = dutyTotals
        self.hotelDetails = hotelDetails
        self.crew = crew
        self.items = items
    }
}

struct CrewAccessTripItemJSON: Codable, Equatable, Sendable {
    let sequence: Int
    let depAirport: String
    let arrAirport: String
    let deadhead: Bool
    let flight: String
    let startUtc: String
    let endUtc: String
    let startLocalDisplay: String
    let endLocalDisplay: String
    let originTz: String?
    let destinationTz: String?
    let timeDerivation: String
    let aircraft: String
    let block: String
    // Scheduled / Actual times for LogTen CSV export
    let stdUtc: String?       // Scheduled Time of Departure (UTC)
    let staUtc: String?       // Scheduled Time of Arrival (UTC)
    let atdUtc: String?       // Actual Time of Departure (UTC) — nil until actual data available
    let ataUtc: String?       // Actual Time of Arrival (UTC)   — nil until actual data available
    let tailNumber: String?   // Aircraft registration (e.g. N123UP)
    let stableLegId: String?
    let originalStdUtc: String?
    let originalStaUtc: String?
    let scheduledDepartureObservedAtUtc: String?
    let scheduledArrivalObservedAtUtc: String?
    let actualDepartureObservedAtUtc: String?
    let actualArrivalObservedAtUtc: String?
    let tripImportedAtUtc: String?
    let actualsImportedAtUtc: String?

    // Memberwise initializer (required because custom Decodable init is defined below)
    init(
        sequence: Int,
        depAirport: String,
        arrAirport: String,
        deadhead: Bool,
        flight: String,
        startUtc: String,
        endUtc: String,
        startLocalDisplay: String,
        endLocalDisplay: String,
        originTz: String?,
        destinationTz: String?,
        timeDerivation: String,
        aircraft: String,
        block: String,
        stdUtc: String?,
        staUtc: String?,
        atdUtc: String?,
        ataUtc: String?,
        tailNumber: String?,
        stableLegId: String? = nil,
        originalStdUtc: String? = nil,
        originalStaUtc: String? = nil,
        scheduledDepartureObservedAtUtc: String? = nil,
        scheduledArrivalObservedAtUtc: String? = nil,
        actualDepartureObservedAtUtc: String? = nil,
        actualArrivalObservedAtUtc: String? = nil,
        tripImportedAtUtc: String? = nil,
        actualsImportedAtUtc: String? = nil
    ) {
        self.sequence          = sequence
        self.depAirport        = depAirport
        self.arrAirport        = arrAirport
        self.deadhead          = deadhead
        self.flight            = flight
        self.startUtc          = startUtc
        self.endUtc            = endUtc
        self.startLocalDisplay = startLocalDisplay
        self.endLocalDisplay   = endLocalDisplay
        self.originTz          = originTz
        self.destinationTz     = destinationTz
        self.timeDerivation    = timeDerivation
        self.aircraft          = aircraft
        self.block             = block
        self.stdUtc            = stdUtc
        self.staUtc            = staUtc
        self.atdUtc            = atdUtc
        self.ataUtc            = ataUtc
        self.tailNumber        = tailNumber
        self.stableLegId       = stableLegId
        self.originalStdUtc    = originalStdUtc
        self.originalStaUtc    = originalStaUtc
        self.scheduledDepartureObservedAtUtc = scheduledDepartureObservedAtUtc
        self.scheduledArrivalObservedAtUtc = scheduledArrivalObservedAtUtc
        self.actualDepartureObservedAtUtc = actualDepartureObservedAtUtc
        self.actualArrivalObservedAtUtc = actualArrivalObservedAtUtc
        self.tripImportedAtUtc = tripImportedAtUtc
        self.actualsImportedAtUtc = actualsImportedAtUtc
    }

    // Custom decoder for backward compatibility with JSON files that lack newer fields
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence          = try c.decode(Int.self,    forKey: .sequence)
        depAirport        = try c.decode(String.self, forKey: .depAirport)
        arrAirport        = try c.decode(String.self, forKey: .arrAirport)
        deadhead          = try c.decode(Bool.self,   forKey: .deadhead)
        flight            = try c.decode(String.self, forKey: .flight)
        startUtc          = try c.decode(String.self, forKey: .startUtc)
        endUtc            = try c.decode(String.self, forKey: .endUtc)
        startLocalDisplay = try c.decode(String.self, forKey: .startLocalDisplay)
        endLocalDisplay   = try c.decode(String.self, forKey: .endLocalDisplay)
        originTz          = try c.decodeIfPresent(String.self, forKey: .originTz)
        destinationTz     = try c.decodeIfPresent(String.self, forKey: .destinationTz)
        timeDerivation    = try c.decode(String.self, forKey: .timeDerivation)
        aircraft          = try c.decode(String.self, forKey: .aircraft)
        block             = try c.decode(String.self, forKey: .block)
        stdUtc            = try c.decodeIfPresent(String.self, forKey: .stdUtc)
        staUtc            = try c.decodeIfPresent(String.self, forKey: .staUtc)
        atdUtc            = try c.decodeIfPresent(String.self, forKey: .atdUtc)
        ataUtc            = try c.decodeIfPresent(String.self, forKey: .ataUtc)
        tailNumber        = try c.decodeIfPresent(String.self, forKey: .tailNumber)
        stableLegId       = try c.decodeIfPresent(String.self, forKey: .stableLegId)
        originalStdUtc    = try c.decodeIfPresent(String.self, forKey: .originalStdUtc)
        originalStaUtc    = try c.decodeIfPresent(String.self, forKey: .originalStaUtc)
        scheduledDepartureObservedAtUtc = try c.decodeIfPresent(String.self, forKey: .scheduledDepartureObservedAtUtc)
        scheduledArrivalObservedAtUtc = try c.decodeIfPresent(String.self, forKey: .scheduledArrivalObservedAtUtc)
        actualDepartureObservedAtUtc = try c.decodeIfPresent(String.self, forKey: .actualDepartureObservedAtUtc)
        actualArrivalObservedAtUtc = try c.decodeIfPresent(String.self, forKey: .actualArrivalObservedAtUtc)
        tripImportedAtUtc = try c.decodeIfPresent(String.self, forKey: .tripImportedAtUtc)
        actualsImportedAtUtc = try c.decodeIfPresent(String.self, forKey: .actualsImportedAtUtc)
    }
}

enum CrewAccessActualTimeResolutionError: Error, Equatable, LocalizedError {
    case invalidTime(String)
    case ambiguousDeparture(String)
    case ambiguousArrival(String)
    case arrivalBeforeDeparture

    var errorDescription: String? {
        switch self {
        case let .invalidTime(value):
            return "Actual UTC time \(value) is outside the supported HH:mm contract."
        case let .ambiguousDeparture(value):
            return "Actual departure \(value) is exactly 12 hours from STD and has an ambiguous UTC date."
        case let .ambiguousArrival(value):
            return "Actual arrival \(value) is exactly 12 hours from STA and has an ambiguous UTC date."
        case .arrivalBeforeDeparture:
            return "Actual arrival must not be earlier than actual departure."
        }
    }
}

enum CrewAccessActualTimeResolver {
    private static let operationalWindow: TimeInterval = 12 * 60 * 60

    /// Resolves an ATD clock value against STD by evaluating the scheduled UTC date and its
    /// adjacent dates. A valid HH:mm always has a candidate no farther than 12 hours away; the
    /// exact 12-hour case is rejected because the preceding and following dates are equidistant.
    static func departure(enteredHHMM: String, scheduledDepartureUTC: Date) throws -> Date {
        try resolve(
            enteredHHMM: enteredHHMM,
            scheduledUTC: scheduledDepartureUTC,
            ambiguousError: .ambiguousDeparture(enteredHHMM)
        )
    }

    /// ATA uses the same adjacent-date and ±12-hour rule as ATD, anchored to STA.
    static func arrival(enteredHHMM: String, scheduledArrivalUTC: Date) throws -> Date {
        try resolve(
            enteredHHMM: enteredHHMM,
            scheduledUTC: scheduledArrivalUTC,
            ambiguousError: .ambiguousArrival(enteredHHMM)
        )
    }

    private static func resolve(
        enteredHHMM: String,
        scheduledUTC: Date,
        ambiguousError: CrewAccessActualTimeResolutionError
    ) throws -> Date {
        let components = enteredHHMM.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].count == 2,
              components[1].count == 2,
              let hour = Int(components[0]), (0..<24).contains(hour),
              let minute = Int(components[1]), (0..<60).contains(minute) else {
            throw CrewAccessActualTimeResolutionError.invalidTime(enteredHHMM)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scheduledDay = calendar.startOfDay(for: scheduledUTC)
        let candidates = [-1, 0, 1].compactMap { dayOffset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: scheduledDay) else {
                return nil
            }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        let ranked = candidates
            .map { ($0, abs($0.timeIntervalSince(scheduledUTC))) }
            .filter { $0.1 <= operationalWindow }
            .sorted { $0.1 < $1.1 }
        guard let nearest = ranked.first else {
            throw CrewAccessActualTimeResolutionError.invalidTime(enteredHHMM)
        }
        if ranked.count > 1, ranked[1].1 == nearest.1 {
            throw ambiguousError
        }
        return nearest.0
    }
}

struct CrewAccessCrewJSON: Codable, Equatable, Sendable {
    let position: String
    let seniority: String
    let crewID: String
    let name: String
}

private struct ParsedLegRow {
    let sequence: Int
    let weekdayToken: String
    let deadhead: Bool
    let flight: String
    let depAirport: String
    let arrAirport: String
    let startUTC: String
    let startLT: String
    let endUTC: String
    let endLT: String
    let block: String
    let aircraft: String
    let sourceLine: String
}

final class CrewAccessPDFImportService: CrewAccessPDFImportServiceProtocol {
    static let parserVersion = "crewaccess-parser-1.0"

    private static let tripDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "ddMMMyyyy"
        return formatter
    }()

    private static let isoUTCFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let utcDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let crewAccessCreatedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "ddMMMyyyy HH:mm"
        return formatter
    }()

    private let minTextCharacterThreshold = 120
    private let tzResolver: IATATimeZoneResolving

    init(tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared) {
        self.tzResolver = tzResolver
    }

    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        // One logical timestamp for this TripDataHub import operation. Do not use the PDF Created
        // timestamp here: that records when CrewAccess observed/published the values.
        let importedAtUTCString = Self.isoUTCFormatter.string(from: Date())
        logger.info("[Import] analyzeTrip start file=\(sourceFileName ?? "unknown", privacy: .private) bytes=\(pdfData.count, privacy: .public)")
        var warnings: [ImportWarning] = []
        var errors: [ImportErrorItem] = []

        guard let document = PDFDocument(data: pdfData) else {
            let stats = RawExtractStats(pageCount: 0, characterCount: 0, lineCount: 0)
            errors.append(ImportErrorItem(
                code: .pdfTextEmpty,
                message: "PDF could not be opened.",
                remediation: "Open a valid CrewAccess print PDF and retry."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: "UNKNOWN",
                tripDate: "UNKNOWN",
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }

        var extractedText = ""
        for pageIndex in 0..<document.pageCount {
            if let pageText = document.page(at: pageIndex)?.string {
                extractedText += pageText + "\n"
            }
        }

        let lines = extractedText
            .components(separatedBy: .newlines)
            .map { normalizeWhitespace($0) }
            .filter { !$0.isEmpty }

        let stats = RawExtractStats(
            pageCount: document.pageCount,
            characterCount: extractedText.count,
            lineCount: lines.count
        )

        logger.info("[Parse] rawText chars=\(stats.characterCount, privacy: .public) lines=\(stats.lineCount, privacy: .public)")
        let dateTokenCount = countRegexMatches(in: extractedText, pattern: #"\b\d{2}[A-Z]{3}\b"#)
        let airportTokenCount = countRegexMatches(in: extractedText, pattern: #"\b[A-Z]{3}\b"#)
        let flightTokenCount = countRegexMatches(in: extractedText, pattern: #"\b\d{3,4}\b"#)
        logger.info("[Parse] candidates dateTokens=\(dateTokenCount, privacy: .public) airportTokens=\(airportTokenCount, privacy: .public) flightTokens=\(flightTokenCount, privacy: .public)")
        let legAnchorPattern = #"^\d+\s*[A-Za-z]{2}\s*(?:(?:DH)\s+)?[A-Za-z0-9]+\s+[A-Z]{3}\s*[-–—]\s*[A-Z]{3}\b"#
        let anchorLines = lines.filter { $0.range(of: legAnchorPattern, options: .regularExpression) != nil }
        let anchorSample = anchorLines.prefix(3).joined(separator: " || ")
        logger.info("[Parse] anchorMatches=\(anchorLines.count, privacy: .public) sample=\(anchorSample, privacy: .private)")

        if extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || extractedText.count < minTextCharacterThreshold {
            errors.append(ImportErrorItem(
                code: .pdfTextEmpty,
                message: "PDF text extraction returned too little text (chars: \(stats.characterCount), lines: \(stats.lineCount)).",
                remediation: "This PDF may be image-only. Re-export a text-selectable CrewAccess print PDF and retry."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: "UNKNOWN",
                tripDate: "UNKNOWN",
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }

        let tripInfoDateText = extractValue(from: lines, prefix: "Date:")
        let tripInfoDate = tripInfoDateText.flatMap { Self.tripDateFormatter.date(from: $0.uppercased()) }
        let pdfCreatedUTC = Self.extractPDFCreatedUTC(from: lines)
        let pdfCreatedUTCString = pdfCreatedUTC.map { Self.isoUTCFormatter.string(from: $0) }

        guard let tripIDLine = extractValue(from: lines, prefix: "Trip Id:") else {
            errors.append(ImportErrorItem(
                code: .missingRequiredFields,
                message: "Trip Id was not found.",
                remediation: "Verify this is CrewAccess Trip Information PDF layout."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: "UNKNOWN",
                tripDate: tripInfoDateText ?? "UNKNOWN",
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }

        let tripIdParts = tripIDLine
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tripID = tripIdParts.first ?? "UNKNOWN"
        let tripStartDateTextFromTripId = tripIdParts.dropFirst().first
        let tripStartDateFromTripId = tripStartDateTextFromTripId.flatMap {
            Self.tripDateFormatter.date(from: $0.uppercased())
        }
        let effectiveTripDateText = tripStartDateTextFromTripId ?? tripInfoDateText ?? "UNKNOWN"
        guard let tripDate = tripStartDateFromTripId ?? tripInfoDate else {
            errors.append(ImportErrorItem(
                code: .missingRequiredFields,
                message: "Trip start date next to Trip Id was not found.",
                remediation: "Verify Trip Id line includes date (e.g. Trip Id: A70870 04Mar2026)."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: tripID,
                tripDate: effectiveTripDateText,
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }
        if tripID == "UNKNOWN" {
            errors.append(ImportErrorItem(
                code: .missingRequiredFields,
                message: "Trip Id was empty.",
                remediation: "Verify this is CrewAccess Trip Information PDF layout."
            ))
        }

        let legPattern = #"^(\d+)\s*([A-Za-z]{2})\s*(?:(DH)\s+)?([A-Za-z0-9]+)\s+([A-Z]{3})\s*[-–—]\s*([A-Z]{3})\s+(\d{2}:\d{2})\s+(\d{2}:\d{2})\s+(\d{2}:\d{2})\s+(\d{2}:\d{2})\s+([0-9:.-]+|-)\s+([A-Za-z0-9-]+).*$"#
        let tripSummary = extractTripSummary(from: lines)
        var legRows: [ParsedLegRow] = []
        var dutyTotals: [String] = []
        var hotelDetails: [String] = []
        var crewRows: [CrewAccessCrewJSON] = []
        var likelyLegButUnmatchedLines: [String] = []

        for line in lines {
            if line.hasPrefix("Duty totals ") {
                dutyTotals.append(line)
                continue
            }
            if line.hasPrefix("Hotel details ") {
                hotelDetails.append(line)
                continue
            }
            if let crew = parseCrewLine(line) {
                crewRows.append(crew)
                continue
            }
            if let parsed = matchLegRow(line, pattern: legPattern) {
                legRows.append(parsed)
            } else if lineContainsLikelyLeg(line) {
                likelyLegButUnmatchedLines.append(line)
                warnings.append(ImportWarning(
                    code: .partialLegParseFailed,
                    message: "Partial leg parse failure: \(line)"
                ))
            }
        }

        let parsedSequences = legRows.map(\.sequence).sorted()
        logger.info("[Parse] parsedSequences=\(parsedSequences.map(String.init).joined(separator: ","), privacy: .public)")
        let unmatchedSample = likelyLegButUnmatchedLines.prefix(3).joined(separator: " || ")
        logger.info("[Parse] likelyLegButUnmatched=\(likelyLegButUnmatchedLines.count, privacy: .public) sample=\(unmatchedSample, privacy: .private)")
        let warningCounts = Dictionary(grouping: warnings, by: \.code).mapValues(\.count)
        logger.info("[Parse] warningBreakdown partialLegParseFailed=\(warningCounts[.partialLegParseFailed] ?? 0, privacy: .public) unknownIata=\(warningCounts[.unknownIata] ?? 0, privacy: .public) unknownTz=\(warningCounts[.unknownTz] ?? 0, privacy: .public) lowConfidence=\(warningCounts[.lowConfidence] ?? 0, privacy: .public) dstBoundaryCrossing=\(warningCounts[.dstBoundaryCrossing] ?? 0, privacy: .public)")

        if legRows.isEmpty {
            errors.append(ImportErrorItem(
                code: .schemaMismatch,
                message: "No leg rows were parsed from CrewAccess PDF.",
                remediation: "CrewAccess layout may have changed. Re-generate PDF and retry."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: tripID,
                tripDate: effectiveTripDateText,
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }

        let label = crewAccessLabel(from: tripDate, tripID: tripID)
        let layoverByArrivingSequence = layoverMetadataByArrivingSequence(extractedText: extractedText, legRows: legRows)

        var tripLegs: [TripLeg] = []
        var jsonItems: [CrewAccessTripItemJSON] = []
        for row in legRows {
            let legSequence = row.sequence
            let depTimeZoneID = tzResolver.resolve(row.depAirport)
            let arrTimeZoneID = tzResolver.resolve(row.arrAirport)

            if depTimeZoneID == nil {
                warnings.append(ImportWarning(code: .unknownIata, message: "Unknown departure IATA in mapping: \(row.depAirport)"))
                warnings.append(ImportWarning(code: .unknownTz, message: "No timezone mapping for departure airport \(row.depAirport)."))
            }
            if arrTimeZoneID == nil {
                warnings.append(ImportWarning(code: .unknownIata, message: "Unknown arrival IATA in mapping: \(row.arrAirport)"))
                warnings.append(ImportWarning(code: .unknownTz, message: "No timezone mapping for arrival airport \(row.arrAirport)."))
            }

            guard let depUTC = deriveDepartureUTC(
                row.startUTC,
                tripStartDate: tripDate,
                tripDayOffset: row.sequence,
                weekdayToken: row.weekdayToken
            ) else {
                errors.append(ImportErrorItem(
                    code: .utcParseFailed,
                    message: "Failed to parse startUtc for leg \(row.sequence): \(row.startUTC)",
                    remediation: "Check CrewAccess UTC columns in the PDF."
                ))
                continue
            }

            guard let arrUTC = deriveArrivalUTC(startUTC: depUTC, endUTCHHMM: row.endUTC, block: row.block) else {
                errors.append(ImportErrorItem(
                    code: .utcParseFailed,
                    message: "Failed to parse endUtc for leg \(row.sequence): \(row.endUTC)",
                    remediation: "Check CrewAccess UTC columns in the PDF."
                ))
                continue
            }

            let depLocalDisplay = localDisplay(utc: depUTC, timeZoneID: depTimeZoneID)
            let arrLocalDisplay = localDisplay(utc: arrUTC, timeZoneID: arrTimeZoneID)
            let normalizedInputBlock = normalizedBlockValue(row.block)
            let calculatedBlock = calculateBlock(depUTC: depUTC, arrUTC: arrUTC)
            let effectiveBlock = normalizedInputBlock ?? calculatedBlock ?? ""
            let layover = layoverByArrivingSequence[row.sequence]
            let departureIsScheduled = pdfCreatedUTC.map { $0 < depUTC } ?? true
            let arrivalIsScheduled = pdfCreatedUTC.map { $0 < arrUTC } ?? true
            let depUTCString = Self.isoUTCFormatter.string(from: depUTC)
            let arrUTCString = Self.isoUTCFormatter.string(from: arrUTC)
            let stableLegID = UUID()

            let leg = TripLeg(
                id: stableLegID,
                payPeriod: label,
                pairing: tripID,
                leg: legSequence,
                flight: normalizeFlightNumber(row.flight, isDeadhead: row.deadhead),
                depAirport: row.depAirport,
                depLocal: depLocalDisplay,
                arrAirport: row.arrAirport,
                arrLocal: arrLocalDisplay,
                depUTC: depUTCString,
                arrUTC: arrUTCString,
                status: legStatus(for: row),
                block: effectiveBlock,
                layoverStation: layover?.station,
                layoverHotelName: layover?.hotelName,
                layoverDuration: layover.map { stripH($0.duration) },
                stdUTC: departureIsScheduled ? depUTCString : nil,
                staUTC: arrivalIsScheduled ? arrUTCString : nil,
                atdUTC: departureIsScheduled ? nil : depUTCString,
                ataUTC: arrivalIsScheduled ? nil : arrUTCString,
                originalSTDUTC: departureIsScheduled ? depUTCString : nil,
                originalSTAUTC: arrivalIsScheduled ? arrUTCString : nil,
                scheduledDepartureObservedAtUTC: departureIsScheduled ? pdfCreatedUTCString : nil,
                scheduledArrivalObservedAtUTC: arrivalIsScheduled ? pdfCreatedUTCString : nil,
                actualDepartureObservedAtUTC: departureIsScheduled ? nil : pdfCreatedUTCString,
                actualArrivalObservedAtUTC: arrivalIsScheduled ? nil : pdfCreatedUTCString,
                tripImportedAtUTC: importedAtUTCString,
                actualsImportedAtUTC: !departureIsScheduled && !arrivalIsScheduled
                    ? importedAtUTCString
                    : nil,
                aircraftType: row.aircraft
            )
            tripLegs.append(leg)

            jsonItems.append(CrewAccessTripItemJSON(
                sequence: legSequence,
                depAirport: row.depAirport,
                arrAirport: row.arrAirport,
                deadhead: row.deadhead,
                flight: normalizeFlightNumber(row.flight, isDeadhead: row.deadhead),
                startUtc: depUTCString,
                endUtc: arrUTCString,
                startLocalDisplay: depLocalDisplay,
                endLocalDisplay: arrLocalDisplay,
                originTz: depTimeZoneID,
                destinationTz: arrTimeZoneID,
                timeDerivation: "from_utc",
                aircraft: row.aircraft,
                block: effectiveBlock,
                stdUtc: departureIsScheduled ? depUTCString : nil,
                staUtc: arrivalIsScheduled ? arrUTCString : nil,
                atdUtc: departureIsScheduled ? nil : depUTCString,
                ataUtc: arrivalIsScheduled ? nil : arrUTCString,
                tailNumber: nil,
                stableLegId: stableLegID.uuidString,
                originalStdUtc: departureIsScheduled ? depUTCString : nil,
                originalStaUtc: arrivalIsScheduled ? arrUTCString : nil,
                scheduledDepartureObservedAtUtc: departureIsScheduled ? pdfCreatedUTCString : nil,
                scheduledArrivalObservedAtUtc: arrivalIsScheduled ? pdfCreatedUTCString : nil,
                actualDepartureObservedAtUtc: departureIsScheduled ? nil : pdfCreatedUTCString,
                actualArrivalObservedAtUtc: arrivalIsScheduled ? nil : pdfCreatedUTCString,
                tripImportedAtUtc: importedAtUTCString,
                actualsImportedAtUtc: !departureIsScheduled && !arrivalIsScheduled
                    ? importedAtUTCString
                    : nil
            ))
        }

        if tripLegs.isEmpty {
            errors.append(ImportErrorItem(
                code: .utcParseFailed,
                message: "All leg rows failed UTC normalization.",
                remediation: "Confirm CrewAccess PDF includes valid UTC start/end columns."
            ))
        }

        let schedule: PayPeriodSchedule? = errors.isEmpty ? PayPeriodSchedule(
            id: label,
            label: label,
            tripCount: Set(tripLegs.map(\.pairing)).count,
            legCount: tripLegs.count,
            openTimeCount: 0,
            updatedAt: Date(),
            legs: tripLegs.sorted { lhs, rhs in
                if (lhs.depUTC ?? "") == (rhs.depUTC ?? "") {
                    return lhs.leg < rhs.leg
                }
                return (lhs.depUTC ?? "") < (rhs.depUTC ?? "")
            },
            openTimeTrips: []
        ) : nil

        let jsonPayload: CrewAccessTripJSON? = errors.isEmpty ? CrewAccessTripJSON(
            schemaVersion: 2,
            source: PendingImportSource.crewAccessPDF.rawValue,
            sourceVersion: Self.parserVersion,
            mappingVersion: tzResolver.mappingVersion,
            generatedAt: importedAtUTCString,
            pdfCreatedUtc: pdfCreatedUTCString,
            tripId: tripID,
            tripInformationDate: effectiveTripDateText,
            creditTime: tripSummary.creditTime,
            tripDays: tripSummary.tripDays,
            tafb: tripSummary.tafb,
            dutyTotals: dutyTotals,
            hotelDetails: hotelDetails,
            crew: crewRows,
            items: jsonItems
        ) : nil

        return makeDraft(
            sourceFileName: sourceFileName,
            tripId: tripID,
            tripDate: effectiveTripDateText,
            parsedSchedule: schedule,
            jsonPayload: jsonPayload,
            warnings: dedupWarnings(warnings),
            errors: dedupErrors(errors),
            rawExtractStats: stats
        )
    }

    /// Matches the CrewAccess footer, e.g. `Created 09Aug2026 02:15 (UTC) by 00007793942`.
    /// Compiled once — this used to be rebuilt on every line of every page.
    private static let pdfCreatedUTCRegex = try? NSRegularExpression(
        pattern: #"Created\s+(\d{2}[A-Za-z]{3}\d{4})\s+(\d{2}:\d{2})\s+\(UTC\)"#
    )

    /// Extracts the PDF's own `Created (UTC)` instant, which is the observation time every
    /// Scheduled/Actual classification in this parser is measured against (INV-012).
    ///
    /// `internal static` so the classification input can be tested directly instead of only
    /// through a full PDF parse. Returns nil when the footer is absent — a missing Created time is
    /// treated as "unknown", never fabricated.
    static func extractPDFCreatedUTC(from lines: [String]) -> Date? {
        guard let regex = pdfCreatedUTCRegex else { return nil }
        for line in lines {
            guard let match = regex.firstMatch(
                    in: line,
                    range: NSRange(line.startIndex..., in: line)
                  ),
                  let dateRange = Range(match.range(at: 1), in: line),
                  let timeRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            let value = "\(line[dateRange]) \(line[timeRange])".uppercased()
            if let date = crewAccessCreatedFormatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private func stripH(_ s: String) -> String {
        s.hasSuffix("h") ? String(s.dropLast()) : s
    }

    private func normalizeFlightNumber(_ raw: String, isDeadhead _: Bool) -> String {
        // CrewAccess sometimes omits the 5X prefix for company flights. Preserve
        // explicit airline codes and add 5X only when the source is digits alone.
        FlightNumberNormalizer.displayValue(raw)
    }

    private func legStatus(for row: ParsedLegRow) -> String {
        if row.flight.caseInsensitiveCompare("GND") == .orderedSame {
            return "GND"
        }
        return row.deadhead ? "DH" : "-"
    }

    private func layoverMetadataByArrivingSequence(extractedText: String, legRows: [ParsedLegRow]) -> [Int: LayoverLeg] {
        guard !extractedText.isEmpty else { return [:] }
        let roster = PDFTripParser.parseText(extractedText)
        guard let firstEntry = roster.entries.first,
              case .trip(let trip) = firstEntry else {
            return [:]
        }

        var result: [Int: LayoverLeg] = [:]
        var pendingFlightIndex: Int?
        var flightIndex = 0
        for pdfLeg in trip.legs {
            switch pdfLeg {
            case .flight:
                flightIndex += 1
                pendingFlightIndex = flightIndex - 1
            case .layover(let layover):
                guard let index = pendingFlightIndex,
                      legRows.indices.contains(index) else { continue }
                result[legRows[index].sequence] = layover
                pendingFlightIndex = nil
            }
        }
        return result
    }

    private func makeDraft(
        sourceFileName: String?,
        tripId: String,
        tripDate: String,
        parsedSchedule: PayPeriodSchedule?,
        jsonPayload: CrewAccessTripJSON?,
        warnings: [ImportWarning],
        errors: [ImportErrorItem],
        rawExtractStats: RawExtractStats
    ) -> CrewAccessImportDraft {
        let draft = CrewAccessImportDraft(
            sourceFileName: sourceFileName,
            tripId: tripId,
            tripDate: tripDate,
            parsedSchedule: parsedSchedule,
            jsonPayload: jsonPayload,
            warnings: warnings,
            errors: errors,
            rawExtractStats: rawExtractStats
        )
        logger.info("[Import] analyzeTrip result tripId=\(draft.tripId, privacy: .private) tripDate=\(draft.tripDate, privacy: .public) legs=\(draft.parsedSchedule?.legs.count ?? 0, privacy: .public) errors=\(draft.errors.count, privacy: .public) warnings=\(draft.warnings.count, privacy: .public)")
        return draft
    }

    private func dedupWarnings(_ warnings: [ImportWarning]) -> [ImportWarning] {
        var seen = Set<String>()
        var out: [ImportWarning] = []
        for warning in warnings {
            let key = "\(warning.code.rawValue)|\(warning.message)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(warning)
        }
        return out
    }

    private func dedupErrors(_ errors: [ImportErrorItem]) -> [ImportErrorItem] {
        var seen = Set<String>()
        var out: [ImportErrorItem] = []
        for error in errors {
            let key = "\(error.code.rawValue)|\(error.message)|\(error.remediation)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(error)
        }
        return out
    }

    private func deriveDepartureUTC(
        _ hhmm: String,
        tripStartDate: Date,
        tripDayOffset: Int,
        weekdayToken: String
    ) -> Date? {
        guard let (hour, minute) = parseHHMM(hhmm) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        guard tripDayOffset > 0 else { return nil }
        guard let dayDate = calendar.date(byAdding: .day, value: tripDayOffset - 1, to: tripStartDate) else {
            return nil
        }
        var components = calendar.dateComponents([.year, .month, .day], from: dayDate)
        components.hour = hour
        components.minute = minute
        components.second = 0
        let dep = calendar.date(from: components)
        if let dep, !weekdayToken.isEmpty {
            let parsedWeekday = normalizeWeekdayToken(weekdayToken)
            let computedWeekday = utcWeekdayToken(for: dep)
            if parsedWeekday != computedWeekday {
                logger.info("[Parse] weekdayMismatch tripDay=\(tripDayOffset, privacy: .public) token=\(parsedWeekday, privacy: .public) computed=\(computedWeekday, privacy: .public)")
            }
        }
        return dep
    }

    private func deriveArrivalUTC(startUTC: Date, endUTCHHMM: String, block: String) -> Date? {
        if let minutes = parseBlockMinutes(block), minutes > 0 {
            return startUTC.addingTimeInterval(TimeInterval(minutes * 60))
        }

        guard let (hour, minute) = parseHHMM(endUTCHHMM) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day], from: startUTC)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var arrival = calendar.date(from: components) else { return nil }
        while arrival <= startUTC {
            arrival = calendar.date(byAdding: .day, value: 1, to: arrival) ?? arrival
        }
        return arrival
    }

    private func utcDisplay(utc: Date) -> String {
        Self.utcDisplayFormatter.string(from: utc)
    }

    private func localDisplay(utc: Date, timeZoneID: String?) -> String {
        guard let tzID = timeZoneID, let tz = TimeZone(identifier: tzID) else {
            return Self.utcDisplayFormatter.string(from: utc)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: utc)
    }

    private func crewAccessLabel(from tripDate: Date, tripID: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: tripDate) % 100
        let month = calendar.component(.month, from: tripDate)
        let normalizedTripID = tripID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        return String(format: "CA%02d-%02d-%@", year, month, normalizedTripID)
    }

    private func extractValue(from lines: [String], prefix: String) -> String? {
        lines.first(where: { $0.hasPrefix(prefix) })?
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lineContainsLikelyLeg(_ line: String) -> Bool {
        return line.range(of: #"\b[A-Z]{3}\s*[-–—]\s*[A-Z]{3}\b"#, options: .regularExpression) != nil
            && line.range(of: #"\b\d{2}:\d{2}\b"#, options: .regularExpression) != nil
    }

    private func parseCrewLine(_ line: String) -> CrewAccessCrewJSON? {
        let pattern = #"^([A-Za-z/]+)\s+(\d+)\s+(\d+)\s+(.+)$"#
        guard let groups = firstMatchGroups(in: line, pattern: pattern),
              groups.count >= 5,
              groups[1] != "Pos" else {
            return nil
        }
        return CrewAccessCrewJSON(
            position: groups[1],
            seniority: groups[2],
            crewID: groups[3],
            name: groups[4].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func matchLegRow(_ line: String, pattern: String) -> ParsedLegRow? {
        guard let groups = firstMatchGroups(in: line, pattern: pattern), groups.count >= 13 else {
            return nil
        }
        return ParsedLegRow(
            sequence: Int(groups[1]) ?? 0,
            weekdayToken: groups[2],
            deadhead: groups[3] == "DH",
            flight: groups[4],
            depAirport: groups[5],
            arrAirport: groups[6],
            startUTC: groups[7],
            startLT: groups[8],
            endUTC: groups[9],
            endLT: groups[10],
            block: groups[11],
            aircraft: groups[12],
            sourceLine: line
        )
    }

    private func normalizeWeekdayToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2)
            .capitalized
    }

    private func utcWeekdayToken(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        switch calendar.component(.weekday, from: date) {
        case 1: return "Su"
        case 2: return "Mo"
        case 3: return "Tu"
        case 4: return "We"
        case 5: return "Th"
        case 6: return "Fr"
        case 7: return "Sa"
        default: return ""
        }
    }

    private func firstMatchGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let r = match.range(at: index)
            guard r.location != NSNotFound else { return "" }
            return nsText.substring(with: r)
        }
    }

    private func parseHHMM(_ text: String) -> (Int, Int)? {
        let pieces = text.split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    private func parseBlockMinutes(_ block: String) -> Int? {
        let pieces = block.split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]),
              hour >= 0,
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private func normalizedBlockValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        guard let minutes = parseBlockMinutes(trimmed) else { return nil }
        let hh = minutes / 60
        let mm = minutes % 60
        return String(format: "%02d:%02d", hh, mm)
    }

    private func calculateBlock(depUTC: Date, arrUTC: Date) -> String? {
        var delta = arrUTC.timeIntervalSince(depUTC)
        while delta < 0 {
            delta += 24 * 3600
        }
        let minutes = Int(round(delta / 60))
        guard minutes >= 0, minutes <= 24 * 60 else { return nil }
        let hh = minutes / 60
        let mm = minutes % 60
        return String(format: "%02d:%02d", hh, mm)
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countRegexMatches(in text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private struct TripSummaryFields {
        let creditTime: String?
        let tripDays: String?
        let tafb: String?
    }

    private func extractTripSummary(from lines: [String]) -> TripSummaryFields {
        let joined = lines.joined(separator: " ")
        return TripSummaryFields(
            creditTime: firstRegexCapture(in: joined, pattern: #"\bCredit\s*Time\s*:\s*([0-9]{1,3}:[0-5][0-9])\b"#),
            tripDays: firstRegexCapture(in: joined, pattern: #"\bTrip\s*Days\s*:\s*([0-9]{1,2})\b"#),
            tafb: firstRegexCapture(in: joined, pattern: #"\bTAFB\s*:\s*([0-9]{1,3}:[0-5][0-9])\b"#)
        )
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let groups = firstMatchGroups(in: text, pattern: pattern), groups.count > 1 else {
            return nil
        }
        let value = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
