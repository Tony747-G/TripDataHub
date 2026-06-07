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

    static let reviewModeMessage = "Demo Mode: GEMS verification is disabled for App Store review."
    static let tripBoardUnavailableMessage = "TripBoard Fetch is unavailable in Demo Mode. Please use manual PDF import."
    static let noTripBoardDataMessage = "No fetched data yet. Please use CrewAccess PDF import."
}
