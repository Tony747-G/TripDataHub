import Foundation

struct CalendarBidPeriod: Equatable {
    let id: String
    let startDateUTC: Date
    let endDateUTC: Date
    let days: [CalendarDay]
}

struct CalendarPayPeriod: Equatable, Sendable {
    let identifier: String?
    let ordinal: Int
    let startDateUTC: Date
    let endDateUTC: Date
}

struct CalendarDay: Equatable {
    let index: Int
    let weekIndex: Int
    let weekdayIndex: Int
    let payPeriodIndex: Int
    let dayStartUTC: Date
    let dayEndUTC: Date
    let displayDateKey: String
}

struct CalendarTrip: Equatable {
    let id: String
    let pairing: String
    let payPeriod: String
    let legs: [TripLeg]
    let startUTC: Date
    let endUTC: Date
}

struct CalendarSegment: Equatable {
    let tripID: String
    let weekIndex: Int
    let dayIndex: Int
    let segmentStartUTC: Date
    let startFraction: Double
    let endFraction: Double
    var lane: Int
    let hasLocalTimeRegression: Bool
    let regressedRange: ClosedRange<Double>?
}

enum CalendarEventLayer: String, Codable, Hashable {
    case operational
    case bid
    case personal
}

enum CrewBase: String, CaseIterable, Identifiable, Codable, Hashable {
    case sdf = "SDF"
    case sdfz = "SDFZ"
    case mia = "MIA"
    case ont = "ONT"
    case anc = "ANC"

    var id: String { rawValue }

    init(normalizing raw: String?) {
        switch DomicileSupport.normalize(raw) {
        case "SDF":
            self = .sdf
        case "SDFZ":
            self = .sdfz
        case "MIA":
            self = .mia
        case "ONT":
            self = .ont
        default:
            self = .anc
        }
    }

    var displayName: String { rawValue }

    var reportAirportCode: String {
        self == .sdfz ? "SDF" : rawValue
    }

    var timeZone: TimeZone {
        DomicileSupport.timeZone(for: rawValue)
    }
}

enum OperationalSettings {
    static let crewBaseKey = "crew_base"
    static let defaultCrewBase = CrewBase.anc

    static func selectedCrewBase(defaults: UserDefaults = .standard) -> CrewBase {
        CrewBase(rawValue: defaults.string(forKey: crewBaseKey) ?? "") ?? defaultCrewBase
    }

    static func setSelectedCrewBase(_ crewBase: CrewBase, defaults: UserDefaults = .standard) {
        defaults.set(crewBase.rawValue, forKey: crewBaseKey)
    }
}

enum ManualOperationalCode: String, CaseIterable, Identifiable, Codable, Hashable {
    case reserveA = "RSV-A"
    case reserveB = "RSV-B"
    case reserveC = "RSV-C"
    case reserveD = "RSV-D"
    case lco = "LCO"
    case hot = "HOT"
    case rcid = "RCID"
    case cq12 = "CQ12"
    case cq6 = "CQ6"

    var id: String { rawValue }
    var layer: CalendarEventLayer { .operational }

    var isReserve: Bool {
        switch self {
        case .reserveA, .reserveB, .reserveC, .reserveD:
            true
        case .lco, .hot, .rcid, .cq12, .cq6:
            false
        }
    }
}

struct LocalClockTime: Codable, Hashable, Comparable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw ManualEventError.invalidClockTime
        }
        self.hour = hour
        self.minute = minute
    }

    init(hhmm: String) throws {
        guard hhmm.count == 4,
              let hour = Int(hhmm.prefix(2)),
              let minute = Int(hhmm.suffix(2)) else {
            throw ManualEventError.invalidClockTime
        }
        try self.init(hour: hour, minute: minute)
    }

    var minutesSinceMidnight: Int {
        hour * 60 + minute
    }

    var displayHHMM: String {
        String(format: "%02d%02d", hour, minute)
    }

    static func < (lhs: LocalClockTime, rhs: LocalClockTime) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

struct TimeRangeRule: Codable, Hashable {
    let start: LocalClockTime
    let end: LocalClockTime

    init(start: LocalClockTime, end: LocalClockTime) {
        self.start = start
        self.end = end
    }

    init(startHHMM: String, endHHMM: String) throws {
        start = try LocalClockTime(hhmm: startHHMM)
        end = try LocalClockTime(hhmm: endHHMM)
    }

    var crossesMidnight: Bool {
        end.minutesSinceMidnight <= start.minutesSinceMidnight
    }

    func resolveUTC(
        localStartDate: DateComponents,
        localEndDate: DateComponents? = nil,
        timeZone: TimeZone
    ) throws -> (startUTC: Date, endUTC: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        guard let year = localStartDate.year,
              let month = localStartDate.month,
              let day = localStartDate.day else {
            throw ManualEventError.invalidLocalDate
        }

        let startComponents = DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: start.hour,
            minute: start.minute
        )
        let endDateComponents = localEndDate ?? localStartDate
        guard let endYear = endDateComponents.year,
              let endMonth = endDateComponents.month,
              let endDayValue = endDateComponents.day else {
            throw ManualEventError.invalidLocalDate
        }
        var endComponents = DateComponents(
            timeZone: timeZone,
            year: endYear,
            month: endMonth,
            day: endDayValue,
            hour: end.hour,
            minute: end.minute
        )

        guard let startDate = calendar.date(from: startComponents) else {
            throw ManualEventError.invalidLocalDate
        }
        if localEndDate == nil,
           crossesMidnight,
           let endDay = calendar.date(from: endComponents),
           let nextEndDay = calendar.date(byAdding: .day, value: 1, to: endDay) {
            endComponents = calendar.dateComponents(in: timeZone, from: nextEndDay)
        }
        guard let endDate = calendar.date(from: endComponents), endDate > startDate else {
            throw ManualEventError.invalidResolvedRange
        }

        return (startDate, endDate)
    }
}

struct CrewBaseRule: Hashable {
    let base: CrewBase

    static func rule(for base: CrewBase) -> CrewBaseRule {
        CrewBaseRule(base: base)
    }

    func defaultTimeRange(for code: ManualOperationalCode) -> TimeRangeRule? {
        switch code {
        case .lco:
            return Self.timeRange("0800", "1400")
        case .rcid:
            return Self.timeRange("0900", "1300")
        case .hot, .cq12, .cq6:
            return nil
        case .reserveA, .reserveB, .reserveC, .reserveD:
            return reserveTimeRange(for: code)
        }
    }

    private func reserveTimeRange(for code: ManualOperationalCode) -> TimeRangeRule? {
        switch (base, code) {
        case (.anc, .reserveA):
            return Self.timeRange("0730", "1929")
        case (.anc, .reserveB):
            return Self.timeRange("0300", "1459")
        case (.anc, .reserveC):
            return Self.timeRange("2015", "0814")
        case (.anc, .reserveD):
            return Self.timeRange("1545", "0344")
        case (.sdf, .reserveA), (.sdfz, .reserveA):
            return Self.timeRange("0000", "1159")
        case (.sdf, .reserveB), (.sdfz, .reserveB):
            return Self.timeRange("1200", "2359")
        case (.sdf, .reserveC), (.sdfz, .reserveC):
            return Self.timeRange("1600", "0359")
        case (.sdf, .reserveD), (.sdfz, .reserveD):
            return Self.timeRange("0400", "1559")
        case (.ont, .reserveA):
            return Self.timeRange("2300", "1059")
        case (.ont, .reserveB):
            return Self.timeRange("1200", "2359")
        case (.ont, .reserveC):
            return Self.timeRange("1559", "0358")
        case (.ont, .reserveD):
            return Self.timeRange("0400", "1559")
        case (.mia, .reserveC):
            return Self.timeRange("1600", "0359")
        case (.mia, .reserveD):
            return Self.timeRange("0500", "1659")
        default:
            return nil
        }
    }

    private static func timeRange(_ start: String, _ end: String) -> TimeRangeRule? {
        try? TimeRangeRule(startHHMM: start, endHHMM: end)
    }
}

enum ManualEventError: Error, Equatable {
    case invalidClockTime
    case invalidLocalDate
    case invalidResolvedRange
    case unsupportedDefaultTimeRange(base: CrewBase, code: ManualOperationalCode)
}

struct ManualOperationalEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let code: ManualOperationalCode
    let crewBase: CrewBase
    let startUTC: Date
    let endUTC: Date
    let notes: String?
    let createdAt: Date
    let updatedAt: Date

    var layer: CalendarEventLayer { .operational }

    init(
        id: UUID = UUID(),
        code: ManualOperationalCode,
        localStartDate: DateComponents,
        defaults: UserDefaults = .standard,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        try self.init(
            id: id,
            code: code,
            crewBase: OperationalSettings.selectedCrewBase(defaults: defaults),
            localStartDate: localStartDate,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    init(
        id: UUID = UUID(),
        code: ManualOperationalCode,
        crewBase: CrewBase,
        localStartDate: DateComponents,
        localEndDate: DateComponents? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        guard let range = CrewBaseRule.rule(for: crewBase).defaultTimeRange(for: code) else {
            throw ManualEventError.unsupportedDefaultTimeRange(base: crewBase, code: code)
        }
        let resolved = try range.resolveUTC(
            localStartDate: localStartDate,
            localEndDate: localEndDate,
            timeZone: crewBase.timeZone
        )
        try self.init(
            id: id,
            code: code,
            crewBase: crewBase,
            startUTC: resolved.startUTC,
            endUTC: resolved.endUTC,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt
        )
    }

    init(
        id: UUID = UUID(),
        code: ManualOperationalCode,
        crewBase: CrewBase,
        startUTC: Date,
        endUTC: Date,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        guard endUTC > startUTC else {
            throw ManualEventError.invalidResolvedRange
        }
        self.id = id
        self.code = code
        self.crewBase = crewBase
        self.startUTC = startUTC
        self.endUTC = endUTC
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static func dailyAutoFilledEvents(
        code: ManualOperationalCode,
        crewBase: CrewBase,
        localStartDate: DateComponents,
        localEndDate: DateComponents,
        notes: String? = nil,
        createdAt: Date = Date()
    ) throws -> [ManualOperationalEvent] {
        guard CrewBaseRule.rule(for: crewBase).defaultTimeRange(for: code) != nil else {
            throw ManualEventError.unsupportedDefaultTimeRange(base: crewBase, code: code)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = crewBase.timeZone

        guard let startDay = calendar.date(from: DateComponents(
            timeZone: crewBase.timeZone,
            year: localStartDate.year,
            month: localStartDate.month,
            day: localStartDate.day
        )),
              let endDay = calendar.date(from: DateComponents(
                timeZone: crewBase.timeZone,
                year: localEndDate.year,
                month: localEndDate.month,
                day: localEndDate.day
              )) else {
            throw ManualEventError.invalidLocalDate
        }
        guard startDay <= endDay else {
            throw ManualEventError.invalidResolvedRange
        }

        var events: [ManualOperationalEvent] = []
        var cursor = startDay
        while cursor <= endDay {
            let components = calendar.dateComponents([.year, .month, .day], from: cursor)
            events.append(try ManualOperationalEvent(
                code: code,
                crewBase: crewBase,
                localStartDate: components,
                notes: notes,
                createdAt: createdAt
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                throw ManualEventError.invalidLocalDate
            }
            cursor = next
        }
        return events
    }
}

func mergeManualOperationalEventsReplacingOverlaps(
    existing: [ManualOperationalEvent],
    replacements: [ManualOperationalEvent]
) -> [ManualOperationalEvent] {
    guard !replacements.isEmpty else {
        return existing.sorted { $0.startUTC < $1.startUTC }
    }

    // Overlap is intentionally scoped to the same code AND the same crewBase.
    // This prevents a base-change from silently removing events that were
    // created under a different base — e.g. an existing ANC RSV-C will NOT
    // be overwritten by a replacement SDF RSV-C even if their UTC intervals
    // overlap. Only events that share both code and creation base are replaced.
    let filtered = existing.filter { current in
        !replacements.contains { replacement in
            current.code == replacement.code
                && current.crewBase == replacement.crewBase
                && current.startUTC < replacement.endUTC
                && current.endUTC > replacement.startUTC
        }
    }

    return (filtered + replacements).sorted { lhs, rhs in
        if lhs.startUTC == rhs.startUTC { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.startUTC < rhs.startUTC
    }
}

enum ManualPersonalCode: String, CaseIterable, Identifiable, Codable, Hashable {
    case commute = "Commute"
    case medical = "Medical"
    case other = "Other"

    var id: String { rawValue }
    var layer: CalendarEventLayer { .personal }
}

struct ManualPersonalEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let code: ManualPersonalCode
    let startUTC: Date
    let endUTC: Date
    let notes: String?
    let createdAt: Date
    let updatedAt: Date

    var layer: CalendarEventLayer { .personal }

    init(
        id: UUID = UUID(),
        code: ManualPersonalCode,
        startUTC: Date,
        endUTC: Date,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) throws {
        guard endUTC > startUTC else {
            throw ManualEventError.invalidResolvedRange
        }
        self.id = id
        self.code = code
        self.startUTC = startUTC
        self.endUTC = endUTC
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

struct ManualEventTombstone: Codable, Hashable, Identifiable {
    let id: UUID
    let deletedAt: Date
}

struct ManualEventStoreSnapshot: Codable, Hashable {
    var operationalEvents: [ManualOperationalEvent]
    var personalEvents: [ManualPersonalEvent]
    var tombstones: [ManualEventTombstone]

    static let empty = ManualEventStoreSnapshot(operationalEvents: [], personalEvents: [], tombstones: [])

    init(
        operationalEvents: [ManualOperationalEvent],
        personalEvents: [ManualPersonalEvent],
        tombstones: [ManualEventTombstone] = []
    ) {
        self.operationalEvents = operationalEvents
        self.personalEvents = personalEvents
        self.tombstones = tombstones
    }

    private enum CodingKeys: String, CodingKey {
        case operationalEvents
        case personalEvents
        case tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationalEvents = try container.decode([ManualOperationalEvent].self, forKey: .operationalEvents)
        personalEvents = try container.decode([ManualPersonalEvent].self, forKey: .personalEvents)
        tombstones = try container.decodeIfPresent([ManualEventTombstone].self, forKey: .tombstones) ?? []
    }
}

func mergeManualEventSnapshots(
    local: ManualEventStoreSnapshot,
    remote: ManualEventStoreSnapshot
) -> ManualEventStoreSnapshot {
    var tombstonesByID: [UUID: ManualEventTombstone] = [:]
    for tombstone in local.tombstones + remote.tombstones {
        if let existing = tombstonesByID[tombstone.id],
           existing.deletedAt >= tombstone.deletedAt {
            continue
        }
        tombstonesByID[tombstone.id] = tombstone
    }

    let tombstones = tombstonesByID

    var operationalByID: [UUID: ManualOperationalEvent] = [:]
    for event in local.operationalEvents + remote.operationalEvents {
        if let tombstone = tombstones[event.id],
           tombstone.deletedAt >= event.updatedAt {
            continue
        }
        if let existing = operationalByID[event.id],
           existing.updatedAt >= event.updatedAt {
            continue
        }
        operationalByID[event.id] = event
    }

    var personalByID: [UUID: ManualPersonalEvent] = [:]
    for event in local.personalEvents + remote.personalEvents {
        if let tombstone = tombstones[event.id],
           tombstone.deletedAt >= event.updatedAt {
            continue
        }
        if let existing = personalByID[event.id],
           existing.updatedAt >= event.updatedAt {
            continue
        }
        personalByID[event.id] = event
    }

    return ManualEventStoreSnapshot(
        operationalEvents: operationalByID.values.sorted { $0.startUTC < $1.startUTC },
        personalEvents: personalByID.values.sorted { $0.startUTC < $1.startUTC },
        tombstones: tombstonesByID.values.sorted { $0.deletedAt < $1.deletedAt }
    )
}

protocol ManualEventStoring {
    func load() -> ManualEventStoreSnapshot
    func save(_ snapshot: ManualEventStoreSnapshot) throws
}

enum ManualEventStoreError: Error {
    case directoryUnavailable
}

final class ManualEventStore: ManualEventStoring {
    // UserDefaults key retained only for the one-time migration read path.
    private let defaults: UserDefaults
    private let legacyStorageKey = "manual_events_v1"

    // File-backed storage in Application Support (private to the app).
    private let fileURL: URL?

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let resolvedDirectory = directory ?? Self.defaultDirectory()
        self.fileURL = resolvedDirectory?.appendingPathComponent("manual_events_v1.json")
    }

    private static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    func load() -> ManualEventStoreSnapshot {
        // 1. Primary: read from file.
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ManualEventStoreSnapshot.self, from: data) {
            return decoded
        }

        // 2. One-time migration from UserDefaults (pre-file-storage builds).
        if let data = defaults.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode(ManualEventStoreSnapshot.self, from: data) {
            try? save(decoded)
            defaults.removeObject(forKey: legacyStorageKey)
            return decoded
        }

        return .empty
    }

    func save(_ snapshot: ManualEventStoreSnapshot) throws {
        guard let url = fileURL else {
            throw ManualEventStoreError.directoryUnavailable
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
