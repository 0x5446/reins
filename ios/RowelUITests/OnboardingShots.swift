/// The two screens someone sees before there is anything to pair with.
///
/// Separate from `Screenshots` because that one waits for a machine to answer
/// before it photographs anything, and the whole point of these two is that no
/// machine is paired yet. Run against a simulator with the app freshly
/// installed:
///
///   xcodebuild test -scheme RowelUI -only-testing:RowelUITests/OnboardingShots

import XCTest

final class OnboardingShots: XCTestCase {
    /// Where the shots are written, on the host.
    ///
    /// From the environment, not a constant. The simulator sees the host file
    /// system, so this has to be an absolute path — and an absolute path
    /// written into the source is one machine's path: it carries whoever owns
    /// that machine into a public repository, and on anybody else's it silently
    /// writes somewhere that does not exist. Missing is a failure, not a
    /// default; a default would put the shots where nobody looks.
    private var out: String {
        guard let path = ProcessInfo.processInfo.environment["ROWEL_SHOTS_OUT"],
              !path.isEmpty else {
            XCTFail("ROWEL_SHOTS_OUT is not set — run this through the script that sets it")
            return NSTemporaryDirectory()
        }
        return path
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    }

    func testWelcomeAndPairingSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        app.launch()

        let connect = app.buttons["Connect a Mac"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30),
                      "not the first-run screen — is a machine already paired?")
        sleep(2)
        save(app, "welcome")

        connect.tap()
        XCTAssertTrue(app.staticTexts["On your Mac"].waitForExistence(timeout: 15))
        sleep(2)
        save(app, "pairing-sheet")
    }
}
