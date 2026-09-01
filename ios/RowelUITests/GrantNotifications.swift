/// Answer the notification permission alert once, so a simulator can be driven
/// for screenshots afterwards.
///
/// The alert belongs to Springboard, not to the app, and a synthetic click
/// posted at its coordinates does not reach it — only the test framework can.
/// Nothing about the app is exercised here; this is a setup step that happens
/// to need a test runner.

import XCTest

final class GrantNotifications: XCTestCase {
    func testGrantNotifications() {
        let app = XCUIApplication()
        app.launchArguments = ["-rowel.lock.enabled.v1", "NO"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 20) {
            allow.tap()
        }
        // Either it was already answered or we just answered it; both are fine.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
