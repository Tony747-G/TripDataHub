import Foundation

enum ProfileStorageKeys {
    static let avatarImageData = "profile_avatar_image_data_v1"
    static let displayName = "profile_display_name_v1"
    static let gemsID = "profile_gems_id_v1"
    static let fleet = "profile_fleet_v1"
    static let base = "profile_base_v1"
    static let position = "profile_position_v1"
    static let lastSeenAt = "profile_last_seen_at_v1"
    static let faaMedicalExpiryDate = "faa_medical_expiry_date"
    static let passportExpiryDate = "passport_expiry_date"
    static let chinaVisaExpiryDate = "china_visa_expiry_date"
    /// TimeInterval since 1970. Updated whenever the user edits a profile field.
    /// Used for last-write-wins conflict resolution in CloudKit sync.
    static let updatedAt = "profile_updated_at_v1"
}

struct ProfileIdentityInput: Equatable {
    var displayName: String
    var gemsID: String

    func repairingClearlySwappedFields() -> ProfileIdentityInput {
        let normalizedName = GEMSIDNormalizer.normalize(displayName)
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        guard Self.isCanonicalGEMSID(normalizedName),
              !Self.isCanonicalGEMSID(normalizedGEMSID),
              !gemsID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return self
        }

        return ProfileIdentityInput(
            displayName: gemsID.trimmingCharacters(in: .whitespacesAndNewlines),
            gemsID: normalizedName
        )
    }

    private static func isCanonicalGEMSID(_ value: String) -> Bool {
        value.count == GEMSIDNormalizer.canonicalLength
            && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

enum ProfileFleet: String, CaseIterable, Identifiable {
    case fleet757 = "757"
    case fleet747 = "747"
    case fleetA30 = "A30"

    var id: String { rawValue }
}

enum ProfileBase: String, CaseIterable, Identifiable {
    case sdf = "SDF"
    case sdfz = "SDFZ"
    case mia = "MIA"
    case ont = "ONT"
    case anc = "ANC"

    var id: String { rawValue }
}

enum ProfilePosition: String, CaseIterable, Identifiable {
    case ca = "CA"
    case fo = "FO"

    var id: String { rawValue }
}
