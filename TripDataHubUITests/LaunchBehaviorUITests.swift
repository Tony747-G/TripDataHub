import UIKit
import XCTest

final class LaunchBehaviorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_timelineLaunchShowsOperationalCountdownBeforeDateHeaderBetweenTrips() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_TIMELINE_SEED"]
        app.launch()

        // The launch fixture is deliberately relative to the test clock, so the day ID must not
        // be hard-coded. This finds the first rendered Timeline day header by its stable prefix.
        let dateHeader = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline.dayHeader.")
        ).firstMatch
        XCTAssertTrue(dateHeader.waitForExistence(timeout: 10))

        let operationalCountdown = app.staticTexts.matching(
            identifier: "timeline.operationalCountdownCard"
        ).firstMatch
        XCTAssertTrue(operationalCountdown.waitForExistence(timeout: 5))
        XCTAssertTrue(operationalCountdown.isHittable)

        let reportPrefix = app.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "timeline.operationalCountdownCard",
                "Report in"
            )
        ).firstMatch
        XCTAssertTrue(reportPrefix.waitForExistence(timeout: 5))
        XCTAssertLessThan(operationalCountdown.frame.minY, dateHeader.frame.minY)
    }

    func test_settingsLoggedOutStateShowsTripBoardLoginAction() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_LOGGED_OUT_VERIFIED"]
        app.launch()

        openSettings(in: app)

        let loginButton = scrollToTripBoardAction(in: app)
        XCTAssertTrue(loginButton.waitForExistence(timeout: 5))
        XCTAssertEqual(loginButton.label, "TripBoard Log-in")
    }

    func test_settingsHidesInternalDemoAndDiagnosticsControls() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_LOGGED_OUT_VERIFIED"]
        app.launch()

        openSettings(in: app)

        XCTAssertFalse(app.switches["settings.openTimeDemoMode"].exists)
        XCTAssertFalse(app.staticTexts["Sync Diagnostics"].exists)

        let tripBoardButton = scrollToTripBoardAction(in: app)
        XCTAssertTrue(tripBoardButton.waitForExistence(timeout: 5))
        XCTAssertEqual(tripBoardButton.label, "TripBoard Log-in")
    }

    func test_phoneNavigationUsesExpandableMenuWithoutTabBar() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_TIMELINE_SEED"]
        app.launch()

        XCTAssertEqual(app.tabBars.count, 0)

        let menuButton = app.buttons["Open Menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.tap()

        XCTAssertTrue(app.buttons["Timeline"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Browser"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Add Event"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPhone expandable navigation menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)

    }

    /// Calendar is a required iPad workspace surface. It is deliberately hidden from the iPhone
    /// floating menu while that phone UI is redesigned, so this test is skipped on iPhone and must
    /// be run against an iPadOS Simulator in CI/release verification.
    func test_iPadCalendarShowsCurrentBidPeriod() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The Calendar UI is verified on iPadOS only."
        )

        let app = XCUIApplication()
        app.launchArguments += ["UITEST_TIMELINE_SEED"]
        app.launch()

        // Match any bid-period header rather than a hardcoded id: the calendar opens on today's
        // BP, so a literal such as BP26-04 becomes stale at the next bid-period transition.
        let bidPeriodHeader = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", #"BP\d{2}-\d{2}"#))
            .firstMatch
        XCTAssertTrue(bidPeriodHeader.waitForExistence(timeout: 10))

        let calendarScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        calendarScreenshot.name = "iPad calendar layout"
        calendarScreenshot.lifetime = .keepAlways
        add(calendarScreenshot)
    }

    private func openSettings(in app: XCUIApplication) {
        let menuButton = app.buttons["Open Menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.tap()

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 2))
        settingsButton.tap()
    }

    private func scrollToTripBoardAction(in app: XCUIApplication) -> XCUIElement {
        let action = app.buttons["settings.tripboardAction"]
        var remainingScrolls = 6
        while (!action.exists || !action.isHittable) && remainingScrolls > 0 {
            app.swipeUp()
            remainingScrolls -= 1
        }
        return action
    }

}
