/// Sit in a conversation while the agent works, so a screen recording taken
/// from outside has something to record.
///
/// The prompt is sent from the machine side while this runs; all this does is
/// keep the right screen in front of the camera for long enough to catch a
/// whole turn — thinking, tool cards, and the answer arriving a word at a time.

import XCTest

final class Recording: XCTestCase {
    func testWatch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        app.launch()
        let card = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Find the slow path in checkout'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 90), "no conversation to watch")
        card.tap()
        sleep(80)
    }
}
