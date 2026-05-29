import Foundation

enum ProfileStorageKeys {
    static let avatarImageData = "profile_avatar_image_data_v1"
    static let displayName = "profile_display_name_v1"
    static let gemsID = "profile_gems_id_v1"
    static let fleet = "profile_fleet_v1"
    static let base = "profile_base_v1"
    static let position = "profile_position_v1"
    static let lastSeenAt = "profile_last_seen_at_v1"
    /// TimeInterval since 1970. Updated whenever the user edits a profile field.
    /// Used for last-write-wins conflict resolution in CloudKit sync.
    static let updatedAt = "profile_updated_at_v1"
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
