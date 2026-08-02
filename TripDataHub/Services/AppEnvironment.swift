import Foundation

enum AppEnvironment {
    static let isAppStoreReviewMode: Bool = {
#if APPSTORE_REVIEW
        return true
#else
        return false
#endif
    }()

    static let isTripBoardFetchVisible: Bool = {
        return !isAppStoreReviewMode
    }()

    static let isFriendSharingVisible: Bool = {
        !isAppStoreReviewMode
    }()

    static let isOpenTimeVisible: Bool = {
        return !isAppStoreReviewMode
    }()

    // Sample OpenTime data remains available to UI tests and development launch overrides, but
    // should not be selectable from the production Settings surface.
    static let isOpenTimeDemoModeControlVisible = false

    // Keep recording diagnostics for managed-device investigations, without exposing the raw log
    // in the normal Settings surface.
    static let isSyncDiagnosticsVisible = false

    // Temporarily hide only the iPhone Calendar entry point while its UI is redesigned.
    // The calendar implementation and the iPad calendar remain available in the codebase.
    static let isIPhoneCalendarVisible = false

    static let reviewModeMessage = "Demo Mode: GEMS verification is disabled for App Store review."
    static let tripBoardUnavailableMessage = "TripBoard Fetch is unavailable in Demo Mode. Please use manual PDF import."
    static let noTripBoardDataMessage = "No fetched data yet. Please use CrewAccess PDF import."
}
