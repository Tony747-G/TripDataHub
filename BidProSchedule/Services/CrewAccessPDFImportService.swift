import Foundation
import PDFKit

protocol CrewAccessPDFImportServiceProtocol {
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
}

struct ImportWarning: Identifiable {
    let id = UUID()
    let code: ImportWarningCode
    let message: String
}

struct CrewAccessTripJSON: Codable {
    let schemaVersion: Int
    let source: String
    let sourceVersion: String
    let mappingVersion: String
    let generatedAt: String
    let tripId: String
    let tripInformationDate: String
    let dutyTotals: [String]
    let hotelDetails: [String]
    let crew: [CrewAccessCrewJSON]
    let items: [CrewAccessTripItemJSON]
}

struct CrewAccessTripItemJSON: Codable {
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
}

struct CrewAccessCrewJSON: Codable {
    let position: String
    let seniority: String
    let crewID: String
    let name: String
}

private struct ParsedLegRow {
    let sequence: Int
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
    static let tzMappingVersion = "iata-tz-2026-02-21"

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

    private static let localDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private let minTextCharacterThreshold = 120

    private let airportTimeZones: [String: String] = [
        "ANC": "America/Anchorage",
        "SDF": "America/Kentucky/Louisville",
        "NRT": "Asia/Tokyo",
        "KIX": "Asia/Tokyo",
        "ICN": "Asia/Seoul",
        "PVG": "Asia/Shanghai",
        "HKG": "Asia/Hong_Kong",
        "TPE": "Asia/Taipei",
        "CGN": "Europe/Berlin",
        "CDG": "Europe/Paris",
        "FRA": "Europe/Berlin",
        "MUC": "Europe/Berlin",
        "DXB": "Asia/Dubai",
        "DOH": "Asia/Qatar",
        "LAX": "America/Los_Angeles",
        "ONT": "America/Los_Angeles",
        "MIA": "America/New_York",
        "JFK": "America/New_York",
        "ORD": "America/Chicago",
        "DFW": "America/Chicago",
        "MEM": "America/Chicago",
        "SEA": "America/Los_Angeles",
        "HNL": "Pacific/Honolulu",
        "GUM": "Pacific/Guam"
    ]

    func analyzeTrip(pdfData: Data, sourceFileName: String?) -> CrewAccessImportDraft {
        NSLog("[Import] analyzeTrip start file=%@ bytes=%d", sourceFileName ?? "unknown", pdfData.count)
        var warnings: [ImportWarning] = []
        var errors: [ImportErrorItem] = []

        func makeDraft(
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
            NSLog(
                "[Import] analyzeTrip result tripId=%@ tripDate=%@ legs=%d errors=%d warnings=%d",
                draft.tripId,
                draft.tripDate,
                draft.parsedSchedule?.legs.count ?? 0,
                draft.errors.count,
                draft.warnings.count
            )
            return draft
        }

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

        guard let tripDateText = extractValue(from: lines, prefix: "Date:"),
              let tripDate = Self.tripDateFormatter.date(from: tripDateText.uppercased()) else {
            errors.append(ImportErrorItem(
                code: .missingRequiredFields,
                message: "Trip Information Date was not found.",
                remediation: "Verify this is CrewAccess Trip Information PDF layout."
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

        guard let tripIDLine = extractValue(from: lines, prefix: "Trip Id:") else {
            errors.append(ImportErrorItem(
                code: .missingRequiredFields,
                message: "Trip Id was not found.",
                remediation: "Verify this is CrewAccess Trip Information PDF layout."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: "UNKNOWN",
                tripDate: tripDateText,
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }

        let tripID = tripIDLine.split(separator: " ").first.map(String.init) ?? "UNKNOWN"
        if tripID == "UNKNOWN" {
            errors.append(ImportErrorItem(
                code: .missingRequiredFields,
                message: "Trip Id was empty.",
                remediation: "Verify this is CrewAccess Trip Information PDF layout."
            ))
        }

        let legPattern = #"^(\d+)\s+[A-Za-z]{2}\s+(?:(DH)\s+)?([A-Za-z0-9]+)\s+([A-Z]{3})-([A-Z]{3})\s+(\d{2}:\d{2})\s+(\d{2}:\d{2})\s+(\d{2}:\d{2})\s+(\d{2}:\d{2})\s+([0-9:.-]+|-)\s+([A-Za-z0-9-]+).*$"#
        var legRows: [ParsedLegRow] = []
        var dutyTotals: [String] = []
        var hotelDetails: [String] = []
        var crewRows: [CrewAccessCrewJSON] = []

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
                warnings.append(ImportWarning(
                    code: .partialLegParseFailed,
                    message: "Partial leg parse failure: \(line)"
                ))
            }
        }

        if legRows.isEmpty {
            errors.append(ImportErrorItem(
                code: .schemaMismatch,
                message: "No leg rows were parsed from CrewAccess PDF.",
                remediation: "CrewAccess layout may have changed. Re-generate PDF and retry."
            ))
            return makeDraft(
                sourceFileName: sourceFileName,
                tripId: tripID,
                tripDate: tripDateText,
                parsedSchedule: nil,
                jsonPayload: nil,
                warnings: warnings,
                errors: errors,
                rawExtractStats: stats
            )
        }

        var tripLegs: [TripLeg] = []
        var jsonItems: [CrewAccessTripItemJSON] = []
        var previousDepUTC: Date?

        for row in legRows {
            if airportTimeZones[row.depAirport] == nil {
                warnings.append(ImportWarning(code: .unknownIata, message: "Unknown departure IATA in mapping: \(row.depAirport)"))
                warnings.append(ImportWarning(code: .unknownTz, message: "No timezone mapping for departure airport \(row.depAirport)."))
            }
            if airportTimeZones[row.arrAirport] == nil {
                warnings.append(ImportWarning(code: .unknownIata, message: "Unknown arrival IATA in mapping: \(row.arrAirport)"))
                warnings.append(ImportWarning(code: .unknownTz, message: "No timezone mapping for arrival airport \(row.arrAirport)."))
            }

            guard let depUTC = deriveDepartureUTC(row.startUTC, tripDate: tripDate, previousDeparture: previousDepUTC) else {
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

            previousDepUTC = depUTC
            let depLocal = localDisplay(utc: depUTC, airport: row.depAirport)
            let arrLocal = localDisplay(utc: arrUTC, airport: row.arrAirport)

            let leg = TripLeg(
                payPeriod: crewAccessLabel(from: tripDate),
                pairing: tripID,
                leg: row.sequence,
                flight: row.flight,
                depAirport: row.depAirport,
                depLocal: depLocal,
                arrAirport: row.arrAirport,
                arrLocal: arrLocal,
                depUTC: Self.isoUTCFormatter.string(from: depUTC),
                arrUTC: Self.isoUTCFormatter.string(from: arrUTC),
                status: row.deadhead ? "DH" : "-",
                block: row.block == "-" ? "" : row.block
            )
            tripLegs.append(leg)

            jsonItems.append(
                CrewAccessTripItemJSON(
                    sequence: row.sequence,
                    depAirport: row.depAirport,
                    arrAirport: row.arrAirport,
                    deadhead: row.deadhead,
                    flight: row.flight,
                    startUtc: Self.isoUTCFormatter.string(from: depUTC),
                    endUtc: Self.isoUTCFormatter.string(from: arrUTC),
                    startLocalDisplay: depLocal,
                    endLocalDisplay: arrLocal,
                    originTz: airportTimeZones[row.depAirport],
                    destinationTz: airportTimeZones[row.arrAirport],
                    timeDerivation: "from_utc",
                    aircraft: row.aircraft,
                    block: row.block
                )
            )
        }

        if tripLegs.isEmpty {
            errors.append(ImportErrorItem(
                code: .utcParseFailed,
                message: "All leg rows failed UTC normalization.",
                remediation: "Confirm CrewAccess PDF includes valid UTC start/end columns."
            ))
        }

        let schedule: PayPeriodSchedule? = errors.isEmpty ? PayPeriodSchedule(
            id: crewAccessLabel(from: tripDate),
            label: crewAccessLabel(from: tripDate),
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
            schemaVersion: 1,
            source: PendingImportSource.crewAccessPDF.rawValue,
            sourceVersion: Self.parserVersion,
            mappingVersion: Self.tzMappingVersion,
            generatedAt: Self.isoUTCFormatter.string(from: Date()),
            tripId: tripID,
            tripInformationDate: tripDateText,
            dutyTotals: dutyTotals,
            hotelDetails: hotelDetails,
            crew: crewRows,
            items: jsonItems
        ) : nil

        return makeDraft(
            sourceFileName: sourceFileName,
            tripId: tripID,
            tripDate: tripDateText,
            parsedSchedule: schedule,
            jsonPayload: jsonPayload,
            warnings: dedupWarnings(warnings),
            errors: dedupErrors(errors),
            rawExtractStats: stats
        )
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

    private func deriveDepartureUTC(_ hhmm: String, tripDate: Date, previousDeparture: Date?) -> Date? {
        guard let (hour, minute) = parseHHMM(hhmm) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = calendar.dateComponents([.year, .month, .day], from: tripDate)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var dep = calendar.date(from: components) else { return nil }

        if let previousDeparture {
            while dep <= previousDeparture {
                dep = calendar.date(byAdding: .day, value: 1, to: dep) ?? dep
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

    private func localDisplay(utc: Date, airport: String) -> String {
        if let tzID = airportTimeZones[airport],
           let tz = TimeZone(identifier: tzID) {
            Self.localDisplayFormatter.timeZone = tz
            return Self.localDisplayFormatter.string(from: utc)
        }
        Self.localDisplayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return Self.localDisplayFormatter.string(from: utc)
    }

    private func crewAccessLabel(from tripDate: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: tripDate) % 100
        let month = calendar.component(.month, from: tripDate)
        return String(format: "CA%02d-%02d", year, month)
    }

    private func extractValue(from lines: [String], prefix: String) -> String? {
        lines.first(where: { $0.hasPrefix(prefix) })?
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lineContainsLikelyLeg(_ line: String) -> Bool {
        return line.range(of: #"\b[A-Z]{3}-[A-Z]{3}\b"#, options: .regularExpression) != nil
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
        guard let groups = firstMatchGroups(in: line, pattern: pattern), groups.count >= 12 else {
            return nil
        }
        return ParsedLegRow(
            sequence: Int(groups[1]) ?? 0,
            deadhead: groups[2] == "DH",
            flight: groups[3],
            depAirport: groups[4],
            arrAirport: groups[5],
            startUTC: groups[6],
            startLT: groups[7],
            endUTC: groups[8],
            endLT: groups[9],
            block: groups[10],
            aircraft: groups[11],
            sourceLine: line
        )
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

    private func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
