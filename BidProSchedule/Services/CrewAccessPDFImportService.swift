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
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
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

    private let minTextCharacterThreshold = 120
    private let tzResolver: IATATimeZoneResolving

    init(tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared) {
        self.tzResolver = tzResolver
    }

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

        NSLog("[Parse] rawText chars=%d lines=%d", stats.characterCount, stats.lineCount)
        let dateTokenCount = countRegexMatches(in: extractedText, pattern: #"\b\d{2}[A-Z]{3}\b"#)
        let airportTokenCount = countRegexMatches(in: extractedText, pattern: #"\b[A-Z]{3}\b"#)
        let flightTokenCount = countRegexMatches(in: extractedText, pattern: #"\b\d{3,4}\b"#)
        NSLog(
            "[Parse] candidates dateTokens=%d airportTokens=%d flightTokens=%d",
            dateTokenCount,
            airportTokenCount,
            flightTokenCount
        )
        let legAnchorPattern = #"^\d+\s*[A-Za-z]{2}\s*(?:(?:DH)\s+)?[A-Za-z0-9]+\s+[A-Z]{3}\s*[-–—]\s*[A-Z]{3}\b"#
        let anchorLines = lines.filter { $0.range(of: legAnchorPattern, options: .regularExpression) != nil }
        let anchorSample = anchorLines.prefix(3).joined(separator: " || ")
        NSLog("[Parse] anchorMatches=%d sample=%@", anchorLines.count, anchorSample)

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
        NSLog("[Parse] parsedSequences=%@", parsedSequences.map(String.init).joined(separator: ","))
        let unmatchedSample = likelyLegButUnmatchedLines.prefix(3).joined(separator: " || ")
        NSLog(
            "[Parse] likelyLegButUnmatched=%d sample=%@",
            likelyLegButUnmatchedLines.count,
            unmatchedSample
        )
        let warningCounts = Dictionary(grouping: warnings, by: \.code).mapValues(\.count)
        NSLog(
            "[Parse] warningBreakdown partialLegParseFailed=%d unknownIata=%d unknownTz=%d lowConfidence=%d dstBoundaryCrossing=%d",
            warningCounts[.partialLegParseFailed] ?? 0,
            warningCounts[.unknownIata] ?? 0,
            warningCounts[.unknownTz] ?? 0,
            warningCounts[.lowConfidence] ?? 0,
            warningCounts[.dstBoundaryCrossing] ?? 0
        )

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

        var tripLegs: [TripLeg] = []
        var jsonItems: [CrewAccessTripItemJSON] = []
        for row in legRows {
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

            let depUTCDisplay = utcDisplay(utc: depUTC)
            let arrUTCDisplay = utcDisplay(utc: arrUTC)
            let normalizedInputBlock = normalizedBlockValue(row.block)
            let calculatedBlock = calculateBlock(depUTC: depUTC, arrUTC: arrUTC)
            let effectiveBlock = normalizedInputBlock ?? calculatedBlock ?? ""

            let leg = TripLeg(
                payPeriod: crewAccessLabel(from: tripDate, tripID: tripID),
                pairing: tripID,
                leg: row.sequence,
                flight: row.flight,
                depAirport: row.depAirport,
                depLocal: depUTCDisplay,
                arrAirport: row.arrAirport,
                arrLocal: arrUTCDisplay,
                depUTC: Self.isoUTCFormatter.string(from: depUTC),
                arrUTC: Self.isoUTCFormatter.string(from: arrUTC),
                status: row.deadhead ? "DH" : "-",
                block: effectiveBlock
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
                    startLocalDisplay: depUTCDisplay,
                    endLocalDisplay: arrUTCDisplay,
                    originTz: depTimeZoneID,
                    destinationTz: arrTimeZoneID,
                    timeDerivation: "from_utc",
                    aircraft: row.aircraft,
                    block: effectiveBlock
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
            id: crewAccessLabel(from: tripDate, tripID: tripID),
            label: crewAccessLabel(from: tripDate, tripID: tripID),
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
            mappingVersion: tzResolver.mappingVersion,
            generatedAt: Self.isoUTCFormatter.string(from: Date()),
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
            if parsedWeekday != utcWeekdayToken(for: dep) {
                NSLog(
                    "[Parse] weekdayMismatch tripDay=%d token=%@ computed=%@",
                    tripDayOffset,
                    parsedWeekday,
                    utcWeekdayToken(for: dep)
                )
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
        return "\(hh):\(String(format: "%02d", mm))"
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
        return "\(hh):\(String(format: "%02d", mm))"
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
