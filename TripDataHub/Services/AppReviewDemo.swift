import Foundation

/// Single gate for all App Store Review demo-account behavior.
///
/// The two reviewer accounts unlock mock verification, seeded schedules, and a
/// mock friend link. Every production code path that branches on a demo account
/// must go through this enum — never compare GEMS ID literals inline — so the
/// entire demo surface is auditable in one place.
enum AppReviewDemo {
    enum Role {
        case pilotOne
        case pilotTwo
    }

    static let pilotOneGEMSID = "0000001"
    static let pilotTwoGEMSID = "0000002"
    private static let demoDateOfBirth = "01/01/1990"

    /// Demo role for a raw or normalized GEMS ID, nil for real users.
    static func role(for gemsID: String) -> Role? {
        switch GEMSIDNormalizer.normalize(gemsID) {
        case pilotOneGEMSID: return .pilotOne
        case pilotTwoGEMSID: return .pilotTwo
        default: return nil
        }
    }

    static func isDemoGEMSID(_ gemsID: String) -> Bool {
        role(for: gemsID) != nil
    }

    /// True only for the exact demo credential pair handed to App Review.
    static func isDemoCredential(gemsID: String, normalizedDOB: String) -> Bool {
        normalizedDOB == demoDateOfBirth && isDemoGEMSID(gemsID)
    }
}
