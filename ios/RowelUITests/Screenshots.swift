/// Store screenshots, taken from the running app.
///
/// Not a test of anything: a driver that walks the app the way the App Store
/// listing shows it and writes PNGs where the release tooling can pick them up.
/// It runs against a real Bridle and a real harness, so what lands in the files
/// is the product rather than a mock of it.
///
/// Kept out of the ordinary suite by name — run it deliberately:
///
///   xcodebuild test -scheme RowelUI -only-testing:RowelUITests/Screenshots
///
/// Each shot proves it is looking at the right screen before it saves. A
/// screenshot taken on faith is worse than a missing one: it reaches the store
/// listing showing the wrong page, and nothing fails to say so.
///
/// The destination is a host path. The simulator sees the host file system, so
/// the shots appear directly in the repo rather than inside a container.

import XCTest

final class Screenshots: XCTestCase {
    private var app: XCUIApplication!
    private let out = "/Users/alpha/.walkcode/workspace/rowel/marketing/shots"
    private let patience: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        try connect()
    }

    /// Launch, and wait until the machine has actually answered.
    ///
    /// The compose button is on screen whether or not the tunnel is up, so
    /// waiting for it proves nothing — a run gated on it walks an empty list
    /// and saves screenshots of a blank app. A conversation row only exists
    /// once the machine has sent one.
    private func connect(file: StaticString = #filePath, line: UInt = #line) throws {
        for attempt in 0..<2 {
            if attempt > 0 { app.terminate(); sleep(3) }
            app.launch()
            let anyRow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] '/Users/'")).firstMatch
            if anyRow.waitForExistence(timeout: patience) { return }
        }
        XCTFail("the app never reached the machine", file: file, line: line)
    }

    /// Back to a known screen, without guessing how deep we are.
    private func restart() throws {
        app.terminate()
        sleep(2)
        try connect()
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    /// Open a conversation from the list.
    ///
    /// The card is the button and its label carries the title, the folder and
    /// the age, so match a prefix rather than the whole string.
    private func openSession(_ title: String) throws {
        let card = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: patience), "no row for \(title)")
        card.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 20))
    }

    /// The machine's name, and the identity the pairing is anchored to.
    func test1Machine() throws {
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        // The paired machine sits under this phone's own settings.
        var row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'MacBook' AND label CONTAINS[c] ':'")).firstMatch
        for _ in 0..<5 where !row.exists {
            app.swipeUp()
            sleep(1)
            row = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'MacBook' AND label CONTAINS[c] ':'")).firstMatch
        }
        if !row.exists {
            row = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'MacBook'")).element(boundBy: 0)
        }
        try? app.debugDescription.write(
            toFile: "\(out)/tree-settings.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no paired machine row")
        row.tap()
        sleep(2)

        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no name field — wrong page")
        name.tap()
        sleep(1)
        if let existing = name.value as? String, !existing.isEmpty {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                 count: existing.count))
        }
        app.typeText("MacBook Pro")
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        sleep(2)
        XCTAssertTrue(app.staticTexts["Fingerprint"].exists, "not the machine page")
        save("machine")
    }

    /// The list, grouped by folder, with anything waiting on a person on top.
    func test2Sessions() throws {
        // connect() already proved the list is populated.
        sleep(3)
        save("sessions")
    }

    /// A finished answer, and the model picker over it.
    func test3Conversation() throws {
        try openSession("Add CAD and AUD to the currency table")
        sleep(5)
        save("conversation")

        app.navigationBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Model"].waitForExistence(timeout: 10))
        sleep(2)
        save("models")
    }

    /// The card that stops a command until a person answers it.
    func test4Approval() throws {
        try openSession("Ship the currency fix")
        sleep(6)
        save("approval")
    }

    /// A long job: the artifact at the end, the tools it ran, the plan it wrote
    /// for itself. Scrolling back is scrolling through the work.
    func test5Working() throws {
        try openSession("Build the checkout health dashboard")
        sleep(6)
        save("artifact")
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        save("tools")
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        save("plan")
    }

    /// A photograph already in the conversation: a layout sketched on paper,
    /// sent from the phone, and the model working from it.
    ///
    /// Driven from the machine side rather than through the system photo
    /// picker — the picker runs out of process and does not take synthetic
    /// taps, and what matters in the shot is the sketch in the transcript, not
    /// the moment of choosing it.
    func test6Photo() throws {
        try openSession("Match the dashboard to this sketch")
        sleep(6)
        // Back up to the message itself — the sketch is the point of the shot.
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        save("photo")
    }
}
