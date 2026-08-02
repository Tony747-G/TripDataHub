import UIKit
import XCTest

final class LaunchBehaviorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_timelineLaunchShowsNextReportCardBeforeDateHeaderBetweenTrips() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_TIMELINE_SEED"]
        app.launch()

        // Use matching(identifier:) rather than subscript to ensure lookup by accessibility identifier.
        let dateHeader = app.staticTexts.matching(identifier: "timeline.dayHeader.2026-06-09").firstMatch
        XCTAssertTrue(dateHeader.waitForExistence(timeout: 10))

        let nextReportCard = app.staticTexts.matching(identifier: "timeline.nextReportCard").firstMatch
        XCTAssertTrue(nextReportCard.waitForExistence(timeout: 5))
        XCTAssertTrue(nextReportCard.isHittable)
        XCTAssertLessThan(nextReportCard.frame.minY, dateHeader.frame.minY)
    }

    func test_settingsLoggedOutStateShowsTripBoardLoginAction() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_LOGGED_OUT_VERIFIED"]
        app.launch()

        openSettings(in: app)

        let loginButton = app.buttons["settings.tripboardAction"]
        XCTAssertTrue(loginButton.waitForExistence(timeout: 5))
        XCTAssertEqual(loginButton.label, "TripBoard Log-in")
    }

    func test_settingsOpenTimeDemoModeShowsDemoLoadAction() {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_LOGGED_OUT_VERIFIED"]
        app.launchArguments += ["UITEST_OPENTIME_DEMO"]
        app.launch()

        openSettings(in: app)

        let demoSwitch = app.switches["settings.openTimeDemoMode"]
        XCTAssertTrue(demoSwitch.waitForExistence(timeout: 5))

        let demoLoadButton = app.buttons["settings.tripboardAction"]
        XCTAssertTrue(demoLoadButton.waitForExistence(timeout: 5))
        XCTAssertEqual(demoLoadButton.label, "Load Demo OpenTime")
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

}
