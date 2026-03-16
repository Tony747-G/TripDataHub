import Foundation

protocol ScheduleCacheServiceProtocol {
    func load() -> ScheduleCacheSnapshotV2?
    func save(_ snapshot: ScheduleCacheSnapshotV2) throws
    func clear()
}

struct ScheduleCacheSnapshot: Codable {
    let schedules: [PayPeriodSchedule]
    let lastSyncAt: Date?
}

struct ScheduleCacheSnapshotV2: Codable {
    let crewAccessSchedules: [PayPeriodSchedule]
    let bidproSchedules: [PayPeriodSchedule]
    let lastSyncAt: Date?
    let migratedAt: Date?
}

final class ScheduleCacheService: ScheduleCacheServiceProtocol {
    private let defaults: UserDefaults
    private let storageKeyV1 = "tripboard.schedule.cache.v1"
    private let storageKeyV2 = "tripboard.schedule.cache.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ScheduleCacheSnapshotV2? {
        if let dataV2 = defaults.data(forKey: storageKeyV2),
           let decodedV2 = try? JSONDecoder().decode(ScheduleCacheSnapshotV2.self, from: dataV2) {
            return decodedV2
        }

        guard let dataV1 = defaults.data(forKey: storageKeyV1),
              let decodedV1 = try? JSONDecoder().decode(ScheduleCacheSnapshot.self, from: dataV1) else {
            return nil
        }

        let split = Self.splitLegacySchedules(decodedV1.schedules)
        let migratedSnapshot = ScheduleCacheSnapshotV2(
            crewAccessSchedules: split.crew,
            bidproSchedules: split.bidpro,
            lastSyncAt: decodedV1.lastSyncAt,
            migratedAt: Date()
        )
        try? save(migratedSnapshot)
        return migratedSnapshot
    }

    func save(_ snapshot: ScheduleCacheSnapshotV2) throws {
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: storageKeyV2)
    }

    func clear() {
        defaults.removeObject(forKey: storageKeyV2)
        defaults.removeObject(forKey: storageKeyV1)
    }

    private static func splitLegacySchedules(_ cached: [PayPeriodSchedule]) -> (crew: [PayPeriodSchedule], bidpro: [PayPeriodSchedule]) {
        var crew: [PayPeriodSchedule] = []
        var bidpro: [PayPeriodSchedule] = []

        for schedule in cached {
            if isLikelyCrewAccessSchedule(schedule) {
                crew.append(schedule)
            } else {
                bidpro.append(schedule)
            }
        }

        return (crew: crew, bidpro: bidpro)
    }

    private static func isLikelyCrewAccessSchedule(_ schedule: PayPeriodSchedule) -> Bool {
        if isCrewAccessScheduleLabel(schedule.id) || isCrewAccessScheduleLabel(schedule.label) {
            return true
        }

        if schedule.legs.contains(where: { $0.pairing.contains("/") }) {
            return true
        }

        return false
    }

    private static func isCrewAccessScheduleLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 7 else { return false }
        let chars = Array(trimmed)
        guard chars[0] == "C", chars[1] == "A", chars[4] == "-" else { return false }
        return chars[2].isNumber && chars[3].isNumber && chars[5].isNumber && chars[6].isNumber
    }
}
