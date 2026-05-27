import Foundation

/// Local-first snapshot of the user's own profile.
/// Synced across iPhone and iPad via CloudKit private database.
/// last-write-wins on `updatedAt`; `lastSeenAt` rides along but does not drive conflict resolution.
struct ProfileSnapshot: Codable, Equatable {
    var gemsID: String
    var displayName: String
    var fleet: String
    var base: String
    var position: String
    var avatarImageData: Data?
    var updatedAt: Date
    var lastSeenAt: Date?
}

// MARK: - UserDefaults persistence

extension ProfileSnapshot {

    /// Loads the current profile from UserDefaults.
    /// Returns a zero-dated snapshot when no profile has ever been saved.
    static func loadFromLocalStorage(defaults: UserDefaults = .standard) -> ProfileSnapshot {
        // Base is keyed under OperationalSettings (shared with schedule features).
        // Position is stored as PilotQualification raw value; mapped to ProfilePosition here.
        let qualRaw = defaults.string(forKey: "pilot_qualification")
            ?? PilotQualification.captain.rawValue
        let position = (PilotQualification(rawValue: qualRaw) == .firstOfficer)
            ? ProfilePosition.fo.rawValue
            : ProfilePosition.ca.rawValue

        return ProfileSnapshot(
            gemsID: defaults.string(forKey: ProfileStorageKeys.gemsID) ?? "",
            displayName: defaults.string(forKey: ProfileStorageKeys.displayName) ?? "",
            fleet: defaults.string(forKey: ProfileStorageKeys.fleet) ?? ProfileFleet.fleet757.rawValue,
            base: defaults.string(forKey: OperationalSettings.crewBaseKey)
                ?? OperationalSettings.defaultCrewBase.rawValue,
            position: position,
            avatarImageData: defaults.data(forKey: ProfileStorageKeys.avatarImageData),
            updatedAt: Date(timeIntervalSince1970: defaults.double(forKey: ProfileStorageKeys.updatedAt)),
            lastSeenAt: {
                let raw = defaults.double(forKey: ProfileStorageKeys.lastSeenAt)
                return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
            }()
        )
    }

    /// Persists the snapshot to UserDefaults.
    func saveToLocalStorage(defaults: UserDefaults = .standard) {
        defaults.set(gemsID, forKey: ProfileStorageKeys.gemsID)
        defaults.set(displayName, forKey: ProfileStorageKeys.displayName)
        defaults.set(fleet, forKey: ProfileStorageKeys.fleet)
        defaults.set(base, forKey: OperationalSettings.crewBaseKey)

        // Map ProfilePosition back to PilotQualification for existing consumers.
        let qualRaw = position == ProfilePosition.fo.rawValue
            ? PilotQualification.firstOfficer.rawValue
            : PilotQualification.captain.rawValue
        defaults.set(qualRaw, forKey: "pilot_qualification")

        if let data = avatarImageData {
            defaults.set(data, forKey: ProfileStorageKeys.avatarImageData)
        } else {
            defaults.removeObject(forKey: ProfileStorageKeys.avatarImageData)
        }
        defaults.set(updatedAt.timeIntervalSince1970, forKey: ProfileStorageKeys.updatedAt)
        if let lastSeen = lastSeenAt {
            defaults.set(lastSeen.timeIntervalSince1970, forKey: ProfileStorageKeys.lastSeenAt)
        }
    }

    /// True when the user has set at least one profile field (updatedAt > epoch).
    var hasContent: Bool {
        updatedAt.timeIntervalSince1970 > 0
    }
}
