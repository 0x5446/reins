/// The twenty seconds the launch video is of.
///
/// One thing happens: the agent is stopped, waiting on a person, and the
/// person says yes from a phone. That is the whole product, and it is the only
/// part of it that cannot be photographed — a still shows the card, but not
/// that the Mac was blocked before the tap and working after it.
///
/// Driven rather than performed. A recording made by hand is a take, and a
/// take has to be re-made every time the interface moves; this one is a script
/// against the real app talking to a real harness, so it can be re-run.
///
///   ios/demo.sh
///
/// The beats are deliberately slow. A viewer needs to read the command the
/// agent is asking to run before the answer means anything, and the cut in the
/// edit is what makes it quick — not the recording.

import XCTest

final class Demo: XCTestCase {
    /// Long enough for a viewer to take the card in, before anything moves.
    private let pause: UInt32 = 4
    /// Long enough afterwards that the work visibly continues rather than ends.
    private let after: UInt32 = 12

    /// Where the recording is written, so the beats can be written beside it.
    private let out = "/Users/alpha/.walkcode/workspace/rowel/marketing/video/raw"
    private var beats: [String: Double] = [:]

    /// Mark the moment something happened, in epoch seconds.
    ///
    /// The edit needs to know when the card appeared and when it was answered,
    /// and guessing from the footage means re-timing every caption by hand
    /// after every take. The driver is the only thing that knows, so it says.
    private func beat(_ name: String) {
        beats[name] = Date().timeIntervalSince1970
    }

    override func tearDown() {
        let json = try? JSONSerialization.data(
            withJSONObject: beats, options: [.prettyPrinted, .sortedKeys])
        try? json?.write(to: URL(fileURLWithPath: out).appendingPathComponent("beats.json"))
        super.tearDown()
    }

    func testApproveFromThePhone() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rowel.lock.enabled.v1", "NO",
        ]
        if let link = ProcessInfo.processInfo.environment["ROWEL_PAIR_LINK"], !link.isEmpty {
            app.launchEnvironment["ROWEL_UITEST_PAIR_LINK"] = link
        }
        app.launch()
        beat("launched")

        // The list, with the conversation already flagged as needing someone.
        let card = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Ship the currency fix'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 90),
                      "no conversation to approve — run ios/demo.sh, which sets one up")
        sleep(2)
        card.tap()
        beat("opened")

        // The ask itself. Failing here rather than recording a video of a
        // screen with no question on it: the point of the shot is the question.
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 60),
                      "nothing is waiting for approval in this conversation")
        beat("asked")
        sleep(pause)

        allow.tap()
        beat("allowed")
        sleep(after)
        beat("ended")
    }
}
