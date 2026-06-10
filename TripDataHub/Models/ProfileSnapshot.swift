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
    var faaMedicalExpiryDate: String? = nil
    var passportExpiryDate: String? = nil
    var chinaVisaExpiryDate: String? = nil
    var updatedAt: Date
    var lastSeenAt: Date?
}

// MARK: - UserDefaults persistence

extension ProfileSnapshot {

    func mergingLegacyReadinessDates(from local: ProfileSnapshot) -> (snapshot: ProfileSnapshot, didMerge: Bool) {
        guard GEMSIDNormalizer.normalize(gemsID) == GEMSIDNormalizer.normalize(local.gemsID) else {
            return (self, false)
        }

        var merged = self
        var didMerge = false
        if faaMedicalExpiryDate == nil,
           let value = local.faaMedicalExpiryDate,
           !value.isEmpty {
            merged.faaMedicalExpiryDate = value
            didMerge = true
        }
        if passportExpiryDate == nil,
           let value = local.passportExpiryDate,
           !value.isEmpty {
            merged.passportExpiryDate = value
            didMerge = true
        }
        if chinaVisaExpiryDate == nil,
           let value = local.chinaVisaExpiryDate,
           !value.isEmpty {
            merged.chinaVisaExpiryDate = value
            didMerge = true
        }
        return (merged, didMerge)
    }

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
            faaMedicalExpiryDate: normalizedOptionalDate(
                defaults.string(forKey: ProfileStorageKeys.faaMedicalExpiryDate)
            ),
            passportExpiryDate: normalizedOptionalDate(
                defaults.string(forKey: ProfileStorageKeys.passportExpiryDate)
            ),
            chinaVisaExpiryDate: normalizedOptionalDate(
                defaults.string(forKey: ProfileStorageKeys.chinaVisaExpiryDate)
            ),
            updatedAt: Date(timeIntervalSince1970: defaults.double(forKey: ProfileStorageKeys.updatedAt)),
            lastSeenAt: {
                let raw = defaults.double(forKey: ProfileStorageKeys.lastSeenAt)
                return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
            }()
        )
    }

    /// Persists the snapshot to UserDefaults.
    func saveToLocalStorage(defaults: UserDefaults = .standard) {
        if isTombstone {
            defaults.set("", forKey: ProfileStorageKeys.gemsID)
            defaults.set("", forKey: ProfileStorageKeys.displayName)
            defaults.removeObject(forKey: ProfileStorageKeys.avatarImageData)
            defaults.removeObject(forKey: ProfileStorageKeys.faaMedicalExpiryDate)
            defaults.removeObject(forKey: ProfileStorageKeys.passportExpiryDate)
            defaults.removeObject(forKey: ProfileStorageKeys.chinaVisaExpiryDate)
            defaults.set(updatedAt.timeIntervalSince1970, forKey: ProfileStorageKeys.updatedAt)
            defaults.removeObject(forKey: ProfileStorageKeys.lastSeenAt)
            return
        }

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
        persistOptionalDate(faaMedicalExpiryDate, forKey: ProfileStorageKeys.faaMedicalExpiryDate, defaults: defaults)
        persistOptionalDate(passportExpiryDate, forKey: ProfileStorageKeys.passportExpiryDate, defaults: defaults)
        persistOptionalDate(chinaVisaExpiryDate, forKey: ProfileStorageKeys.chinaVisaExpiryDate, defaults: defaults)
        defaults.set(updatedAt.timeIntervalSince1970, forKey: ProfileStorageKeys.updatedAt)
        if let lastSeen = lastSeenAt {
            defaults.set(lastSeen.timeIntervalSince1970, forKey: ProfileStorageKeys.lastSeenAt)
        } else {
            defaults.removeObject(forKey: ProfileStorageKeys.lastSeenAt)
        }
    }

    /// True when the user has set at least one profile field (updatedAt > epoch).
    var hasContent: Bool {
        updatedAt.timeIntervalSince1970 > 0
    }

    private var isTombstone: Bool {
        gemsID.isEmpty
            && displayName.isEmpty
            && fleet.isEmpty
            && base.isEmpty
            && position.isEmpty
            && avatarImageData == nil
            && (faaMedicalExpiryDate ?? "").isEmpty
            && (passportExpiryDate ?? "").isEmpty
            && (chinaVisaExpiryDate ?? "").isEmpty
            && updatedAt.timeIntervalSince1970 > 0
    }

    private static func normalizedOptionalDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func persistOptionalDate(_ value: String?, forKey key: String, defaults: UserDefaults) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
