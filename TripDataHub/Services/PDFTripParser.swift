// PDFTripParser.swift
// TripDataHub
//
// PDFKitを使ってTrip Information PDFを直接パース
// OCR不要で正確なデータが取得できる
// 対応フォーマット: UPS CrewAccess Trip_Information_AXXXXX.pdf
//
// ※ TripDataHub 版では TripLeg の名前衝突を避けるため
//    内部の enum TripLeg → PdfLeg にリネーム済み（RosterParsingModels.swift 参照）

import PDFKit
import Foundation

struct PDFTripParser {

    // MARK: - Public entry point

    /// PDFデータからRosterを生成（1ファイル = 1トリップ）
    static func parse(from data: Data) -> Roster? {
        guard let document = PDFDocument(data: data) else { return nil }

        var fullText = ""
        for i in 0..<document.pageCount {
            fullText += (document.page(at: i)?.string ?? "") + "\n"
        }

        guard !fullText.isEmpty else { return nil }

        return parseText(fullText)
    }

    // MARK: - Main parser

    /// Internal entry point. Exposed so callers that have already extracted PDF text
    /// (e.g. CrewAccessPDFImportService) can reuse it without paying for a second
    /// PDFDocument(data:) load.
    static func parseText(_ text: String) -> Roster {
        var roster = Roster()

        let rawLines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Crew行がPDF抽出で複数行に分断されている場合を結合する
        // 例: "Crew: 1F/O Base: ANC Duty Time: 30:12\nBlock Time:\n33:19\nTrip Days:\n11 TAFB: 87:32"
        var lines: [String] = []
        var rawIdx = 0
        while rawIdx < rawLines.count {
            let rawLine = rawLines[rawIdx]
            if rawLine.hasPrefix("Crew:") && !rawLine.contains("TAFB:") {
                var combined = rawLine
                var j = rawIdx + 1
                while j < rawLines.count && !combined.contains("TAFB:") && (j - rawIdx) < 15 {
                    combined += " " + rawLines[j]
                    j += 1
                }
                lines.append(combined)
                rawIdx = j
            } else if rawLine.contains("Hotel:") && !rawLine.contains("Hotel Transport:") && !rawLine.contains("Duty start") {
                // Hotel行が複数行に分断されている場合を結合 (例: HNL "808-955-\ndetails\nBOOKED\n4811 Hotel Transport:")
                var combined = rawLine
                var j = rawIdx + 1
                while j < rawLines.count && !combined.contains("Hotel Transport:") && (j - rawIdx) < 8 {
                    combined += " " + rawLines[j]
                    j += 1
                }
                lines.append(combined)
                rawIdx = j
            } else {
                lines.append(rawLine)
                rawIdx += 1
            }
        }

        var tripNumber    = ""
        var localStartDate = ""
        var utcStartDate  = ""
        var blockTotal    = ""
        var dutyTime      = ""
        var creditTime    = ""
        var tafb          = ""
        var durationDays  = 0
        var position      = "F/O"
        var reportTimeLT  = ""
        var reportTimeUTC = ""
        var fleet         = "747"
        var legs: [PdfLeg] = []   // ← PdfLeg (TripLeg との名前衝突を回避)

        var pendingDutyStartUTC = ""
        var pendingDutyStartLT  = ""
        var lastRestTime        = ""
        var firstDutyStart      = true

        for line in lines {

            // ── Trip header ───────────────────────────────────────
            if line.hasPrefix("Trip Id:"),
               let g = extractGroups(from: line,
                   pattern: #"Trip Id:\s+([A-Z]?\d{4,6}[A-Z]*)"#) {
                tripNumber = g[0]
                if let g2 = extractGroups(from: line,
                    pattern: #"Trip Id:\s+[A-Z]?\d{4,6}[A-Z]*\s+(\d{1,2}[A-Za-z]{3}\d{4})"#) {
                    utcStartDate = formatDate(g2[0])
                }
                if localStartDate.isEmpty { localStartDate = utcStartDate }
            }

            // ── Crew summary line ─────────────────────────────────
            if line.hasPrefix("Crew:") && line.contains("Block Time:") {
                if let g = extractGroups(from: line,
                    pattern: #"Block Time:\s+(\d+:\d{2})"#)  { blockTotal  = g[0] + "h" }
                if let g = extractGroups(from: line,
                    pattern: #"Duty Time:\s+(\d+:\d{2})"#)   { dutyTime    = g[0] }
                if let g = extractGroups(from: line,
                    pattern: #"Credit Time:\s+(\d+:\d{2})"#) { creditTime  = g[0] }
                if let g = extractGroups(from: line,
                    pattern: #"TAFB:\s+(\d+:\d{2})"#)        { tafb        = g[0] }
                if let g = extractGroups(from: line,
                    pattern: #"Trip Days:\s+(\d+)"#)          { durationDays = Int(g[0]) ?? 0 }
                if let g = extractGroups(from: line,
                    pattern: #"Crew:\s+\d*([A-Z/O2]+)"#)     { position    = g[0] }
            }

            // ── Duty start ────────────────────────────────────────
            // Hotel行末尾に埋め込まれている場合もあるため contains を使用
            if line.contains("Duty start"),
               let dsRange = line.range(of: "Duty start") {
                let dutyPart = String(line[dsRange.upperBound...])
                let times = allMatches(in: dutyPart, pattern: #"(\d{1,2}:\d{2})"#)
                if times.count >= 2 {
                    pendingDutyStartUTC = times[0]
                    pendingDutyStartLT  = times[1]
                    if firstDutyStart {
                        reportTimeUTC = times[0]
                        reportTimeLT  = times[1]
                        firstDutyStart = false
                    }
                }
            }

            // ── Duty end ─────────────────────────────────────────
            if line.hasPrefix("Duty end") {
                let times = allMatches(in: line, pattern: #"(\d{1,2}:\d{2})"#)
                if times.count >= 2, !legs.isEmpty {
                    let endUTC = times[0]
                    let endLT  = times[1]
                    if case .flight(var fl) = legs.last {
                        fl.dutyEndUTC = endUTC
                        fl.dutyEndLT  = endLT
                        legs[legs.count - 1] = .flight(fl)
                    }
                }
            }

            // ── Standalone Rest line ──────────────────────────────
            if line.hasPrefix("Rest:") {
                if let g = extractGroups(from: line,
                    pattern: #"Rest:\s+(\d+:\d{2})"#) {
                    lastRestTime = g[0]
                }
            }

            // ── Duty totals ───────────────────────────────────────
            if line.hasPrefix("Duty totals") {
                if let g = extractGroups(from: line,
                    pattern: #"Rest:\s+(\d+:\d{2})"#) {
                    lastRestTime = g[0]
                }
            }

            // ── Flight leg ────────────────────────────────────────
            if let g = extractGroups(from: line,
                pattern: #"^(\d+)\s*(?:Mo|Tu|We|Th|Fr|Sa|Su)\s+(DH\s+)?([A-Z]{0,2}\d{2,4})\s+([A-Z]{3})-([A-Z]{3})\s+(\d{1,2}:\d{2})\s+(\d{1,2}:\d{2})\s+(\d{1,2}:\d{2})\s+(\d{1,2}:\d{2})\s+(-|\d{1,2}:\d{2})\s+(-|\d{3})(?:\s+(\d{1,2}:\d{2}))?"#) {

                let dayNum    = Int(g[0]) ?? 1
                let isDH      = !g[1].trimmingCharacters(in: .whitespaces).isEmpty
                let rawFlight = g[2]
                // Preserve the original digits (including leading zeros) so numeric
                // and 5X-prefixed flights normalize to the same "XX…" form.
                let flightNum = FlightNumberNormalizer.displayValue(rawFlight)
                let dep       = g[3], arr = g[4]
                let depUTC    = g[5], depLT = g[6]
                let arrUTC    = g[7], arrLT = g[8]
                let block     = g[9] == "-" ? "—" : g[9] + "h"
                let aircraft  = g[10] == "-" ? "" : g[10]
                let cnx       = g.count > 11 ? g[11] : ""

                if !aircraft.isEmpty && (fleet.isEmpty || fleet == "747") { fleet = aircraft }

                let legUTCDate = addDays(dayNum - 1, to: utcStartDate)

                let fl = FlightLeg(
                    flightNumber: flightNum,
                    departureStation: dep, arrivalStation: arr,
                    utcDate: legUTCDate,
                    departureTimeLT: depLT, arrivalTimeLT: arrLT,
                    departureTimeUTC: depUTC, arrivalTimeUTC: arrUTC,
                    dutyStartUTC: pendingDutyStartUTC,
                    dutyStartLT:  pendingDutyStartLT,
                    dutyEndUTC: "", dutyEndLT: "",
                    scheduledDep: depLT, scheduledArr: arrLT,
                    position: position, isDeadhead: isDH,
                    aircraft: aircraft, tailNumber: "",
                    catered: false, blockTime: block,
                    cnxTime: cnx,
                    reportTimeLT: "", releaseTimeLT: ""
                )
                legs.append(.flight(fl))

                pendingDutyStartUTC = ""
                pendingDutyStartLT  = ""
            }

            // ── Hotel ─────────────────────────────────────────────
            if line.contains("Hotel:") {
                let cleanedLine = line
                    .replacingOccurrences(of: " details", with: " ")
                    .replacingOccurrences(of: " BOOKED",  with: " ")
                    .replacingOccurrences(of: "BOOKED ",  with: " ")
                    .replacingOccurrences(of: "Status:",  with: " ")
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                let hotelName = (
                    extractGroups(from: cleanedLine,
                        pattern: #"Hotel:\s+(.+?)(?:\s+Hotel Transport:|\s+\+\d|\s+\d{3,}|$)"#)?[0]
                        ?? ""
                ).trimmingCharacters(in: .whitespaces)
                 .replacingOccurrences(of: " UPS Only", with: "")
                 .replacingOccurrences(of: "UPS Only ", with: "")
                 .trimmingCharacters(in: .whitespaces)

                let hotelPhone: String = {
                    if let g = extractGroups(from: cleanedLine,
                        pattern: #"Hotel:[^+]+(\+\d[\d\s\-]+?)(?=\s+Hotel Transport:|\s+[A-Z][a-z]|\s*$)"#) {
                        return g[0].trimmingCharacters(in: .whitespaces)
                    }
                    if let g = extractGroups(from: cleanedLine,
                        pattern: #"011[-\s]?(\d{1,4}[-\s]?\d[\d\-\s]+?)(?:\s+Hotel Transport:|$)"#) {
                        return "+\(g[0].trimmingCharacters(in: .whitespaces))"
                    }
                    if let g = extractGroups(from: cleanedLine,
                        pattern: #"Hotel:[^\d]+([2-9]\d{2}-\d{3}-)\s*(\d{4})"#) {
                        return "\(g[0])\(g[1])"
                    }
                    return ""
                }()

                let station = legs.compactMap { l -> String? in
                    if case .flight(let f) = l { return f.arrivalStation }
                    return nil
                }.last ?? ""

                if !hotelName.isEmpty {
                    legs.append(.layover(LayoverLeg(
                        station: station,
                        hotelName: hotelName,
                        hotelPhone: hotelPhone,
                        checkInLT: "", checkOutLT: "",
                        duration: lastRestTime
                    )))
                    lastRestTime = ""
                }
            }

            // ── Crew member ───────────────────────────────────────
            if let g = extractGroups(from: line,
                pattern: #"^(CPT|F/O\d?|R/O)\s+(\d{3,4})\s+(\d{8,12})\s+(.+)$"#) {
                roster.crewName   = g[3]
                roster.employeeID = g[2]
                roster.seniority  = g[1]
                roster.base       = "ANC"
            }
        }

        // ── Build trip ───────────────────────────────────────────
        guard !tripNumber.isEmpty else { return roster }

        let layoverStations = legs.compactMap { l -> String? in
            if case .layover(let lay) = l, !lay.station.isEmpty { return lay.station }
            return nil
        }

        // startDate: 最初のフライトレグのUTC出発日時からANCローカル出発日を算出
        let resolvedStartDate: String = {
            let utcFmt = DateFormatter()
            utcFmt.dateFormat = "dd MMM yyyy"
            utcFmt.locale = Locale(identifier: "en_US_POSIX")
            utcFmt.timeZone = TimeZone(identifier: "UTC")

            if let firstFlight = legs.compactMap({ l -> FlightLeg? in
                if case .flight(let f) = l { return f }; return nil
            }).first,
               !firstFlight.utcDate.isEmpty,
               let midnight = utcFmt.date(from: firstFlight.utcDate) {
                let parts = firstFlight.departureTimeUTC.split(separator: ":")
                if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                    let depUTC = midnight.addingTimeInterval(TimeInterval((h * 60 + m) * 60))
                    let ancFmt = DateFormatter()
                    ancFmt.dateFormat = "dd MMM yyyy"
                    ancFmt.locale = Locale(identifier: "en_US_POSIX")
                    ancFmt.timeZone = TimeZone(identifier: "America/Anchorage")!
                    return ancFmt.string(from: depUTC)
                }
            }
            return utcStartDate.isEmpty ? localStartDate : utcStartDate
        }()

        let endDate = addDays(durationDays - 1, to: resolvedStartDate)

        let trip = Trip(
            tripNumber: tripNumber,
            startDate: resolvedStartDate,
            endDate: endDate,
            utcStartDate: utcStartDate,
            durationDays: durationDays,
            position: position, station: "ANC",
            fleet: fleet,
            layoverStations: layoverStations,
            blockTotal: blockTotal,
            dutyTime: dutyTime,
            creditTime: creditTime,
            tafb: tafb,
            reportTimeLT: reportTimeLT,
            reportTimeUTC: reportTimeUTC,
            releaseTimeLT: "", legalAt: "",
            legs: legs
        )
        roster.entries.append(.trip(trip))

        return roster
    }

    // MARK: - Date helpers

    private static func formatDate(_ raw: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "ddMMMyyyy"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if let d = fmt.date(from: raw) {
            let out = DateFormatter()
            out.dateFormat = "dd MMM yyyy"
            out.locale = Locale(identifier: "en_US_POSIX")
            return out.string(from: d)
        }
        return raw
    }

    private static func addDays(_ days: Int, to dateStr: String) -> String {
        guard days >= 0, !dateStr.isEmpty else { return dateStr }
        let fmt = DateFormatter()
        fmt.dateFormat = "dd MMM yyyy"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let base = fmt.date(from: dateStr),
              let result = Calendar.current.date(byAdding: .day, value: days, to: base)
        else { return dateStr }
        return fmt.string(from: result)
    }

    // MARK: - Regex helpers

    private static func extractGroups(from string: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range) else { return nil }
        var groups: [String] = []
        for i in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: string) { groups.append(String(string[r])) }
            else { groups.append("") }
        }
        return groups.isEmpty ? nil : groups
    }

    private static func allMatches(in string: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: string) else { return nil }
            return String(string[r])
        }
    }
}
