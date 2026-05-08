import XCTest

final class LaunchBehaviorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_timelineLaunchShowsNextReportCardBeforeDateHeaderBetweenTrips() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_TIMELINE_SEED"]
        app.launch()

        let timelineTab = app.tabBars.buttons["Timeline"]
        XCTAssertTrue(timelineTab.waitForExistence(timeout: 5))
        timelineTab.tap()

        // Use matching(identifier:) rather than subscript to ensure lookup by accessibility identifier.
        let dateHeader = app.staticTexts.matching(identifier: "timeline.dayHeader.2026-06-09").firstMatch
        XCTAssertTrue(dateHeader.waitForExistence(timeout: 10))

        let nextReportCard = app.staticTexts.matching(identifier: "timeline.nextReportCard").firstMatch
        XCTAssertTrue(nextReportCard.waitForExistence(timeout: 5))
        XCTAssertTrue(nextReportCard.isHittable)
        XCTAssertLessThan(nextReportCard.frame.minY, dateHeader.frame.minY)
    }

    func test_settingsLoggedOutStateShowsLoginActionAndPresentsLoginSheet() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_LOGGED_OUT_VERIFIED"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let loginButton = app.buttons["settings.tripboardAction"]
        XCTAssertTrue(loginButton.waitForExistence(timeout: 5))
        XCTAssertEqual(loginButton.label, "TripBoard Log-in")

        loginButton.tap()

        // Check for the Close button in TripBoardLoginView's toolbar — more reliable
        // than querying the navigation bar title in a sheet context.
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
    }

}
