// RosterParsingModels.swift
// TripDataHub
//
// PDFTripParser が使用する内部パースモデル
// TripDataHub の TripLeg (struct) と名前が衝突するため
// enum TripLeg → PdfLeg にリネームしている

import Foundation

// MARK: - Roster（1トリップ分のパース結果）
struct Roster {
    var crewName: String = ""
    var employeeID: String = ""
    var base: String = "ANC"
    var seniority: String = ""
    var periodStart: String = ""
    var periodEnd: String = ""
    var entries: [RosterEntry] = []
    var generatedAt: Date = Date()
}

// MARK: - RosterEntry
enum RosterEntry {
    case trip(Trip)
    case standby(StandbyEntry)
}

// MARK: - Trip
struct Trip: Identifiable {
    let id = UUID()
    var tripNumber: String
    var startDate: String           // ANCローカル出発日 "26 Apr 2026"
    var endDate: String
    var utcStartDate: String        // UTC開始日 "27 Apr 2026"
    var durationDays: Int
    var position: String            // "F/O"
    var station: String             // "ANC"
    var fleet: String               // "747"
    var layoverStations: [String]
    var blockTotal: String
    var dutyTime: String
    var creditTime: String
    var tafb: String
    var reportTimeLT: String
    var reportTimeUTC: String
    var releaseTimeLT: String
    var legalAt: String
    var legs: [PdfLeg] = []
}

// MARK: - PdfLeg（フライトレグ or ホテル）
// ※ TripDataHub の struct TripLeg との名前衝突を避けるため PdfLeg に変更
enum PdfLeg {
    case flight(FlightLeg)
    case layover(LayoverLeg)
}

// MARK: - FlightLeg
struct FlightLeg: Identifiable {
    let id = UUID()
    var flightNumber: String
    var departureStation: String
    var arrivalStation: String
    var utcDate: String             // "27 Apr 2026"
    var departureTimeLT: String
    var arrivalTimeLT: String
    var departureTimeUTC: String
    var arrivalTimeUTC: String
    var dutyStartUTC: String
    var dutyStartLT: String
    var dutyEndUTC: String
    var dutyEndLT: String
    var scheduledDep: String
    var scheduledArr: String
    var position: String
    var isDeadhead: Bool
    var aircraft: String
    var tailNumber: String
    var catered: Bool
    var blockTime: String
    var cnxTime: String
    var reportTimeLT: String
    var releaseTimeLT: String
    var crew: [CrewMember] = []
}

// MARK: - LayoverLeg
struct LayoverLeg: Identifiable {
    let id = UUID()
    var station: String
    var hotelName: String
    var hotelPhone: String
    var checkInLT: String
    var checkOutLT: String
    var duration: String
}

// MARK: - CrewMember
struct CrewMember: Identifiable {
    let id = UUID()
    var name: String
    var employeeID: String
    var position: String
    var seniority: String
    var base: String
    var isSelf: Bool = false
}

// MARK: - StandbyEntry
// ※ TripDataHub に Standby 型がないため StandbyEntry に変更
struct StandbyEntry: Identifiable {
    let id = UUID()
    var type: String
    var startLT: String
    var endLT: String
    var duration: String
    var station: String
}
