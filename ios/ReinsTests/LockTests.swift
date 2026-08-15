/// The app lock.
///
/// The cases that matter are the ones a person cannot produce on a simulator: a
/// clock that moves, biometry that refuses, a passcode that disappears while the
/// app was away. `AppLock` takes both the clock and the authenticator, so all of
/// them are ordinary tests rather than a device someone has to hold.

import XCTest
@testable import Reins

/// An authenticator that answers however the test needs it to.
private final class StubAuthenticator: Authenticator, @unchecked Sendable {
    var available = true
    var answer: AuthFailure?
    private(set) var attempts = 0
    private(set) var reasons: [String] = []

    func isAvailable() -> Bool { available }

    func authenticate(reason: String) async -> AuthFailure? {
        attempts += 1
        reasons.append(reason)
        return answer
    }
}

/// A clock the test winds by hand.
private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    func read() -> Date { now }
}

@MainActor
final class AppLockTests: XCTestCase {
    private var suite: UserDefaults!
    private var stub: StubAuthenticator!
    private var clock: Clock!

    override func setUp() {
        super.setUp()
        // A named suite per test, so nothing leaks between them or into the
        // simulator's real preferences.
        let name = "reins.lock.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)
        stub = StubAuthenticator()
        clock = Clock()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.description)
        super.tearDown()
    }

    private func lock(delay: LockDelay = .oneMinute, enabled: Bool? = nil) -> AppLock {
        if let enabled { suite.set(enabled, forKey: "reins.lock.enabled.v1") }
        suite.set(delay.rawValue, forKey: "reins.lock.delay.v1")
        let made = AppLock(authenticator: stub, defaults: suite, now: clock.read)
        return made
    }

    // MARK: - Defaults

    func testOnByDefaultWhenTheDeviceCanAuthenticate() {
        let subject = lock()
        XCTAssertTrue(subject.isEnabled, "the person who most needs this would never go looking for it")
        XCTAssertTrue(subject.isLocked, "a cold launch is an arrival from outside")
    }

    func testOffWhenTheDeviceCannotAuthenticate() {
        stub.available = false
        let subject = lock(enabled: true)
        XCTAssertFalse(subject.isEnabled, "enabling it here would be a lock screen with no key")
        XCTAssertFalse(subject.isLocked)
    }

    func testARememberedChoiceToDisableIsKept() {
        let subject = lock(enabled: false)
        XCTAssertFalse(subject.isEnabled)
        XCTAssertFalse(subject.isLocked)
    }

    // MARK: - The idle timeout

    func testStayingAwayLongerThanTheDelayLocks() async {
        let subject = lock(delay: .oneMinute)
        await unlockSuccessfully(subject)

        subject.willResignActive()
        clock.advance(61)
        subject.didBecomeActive()

        XCTAssertTrue(subject.isLocked)
        XCTAssertTrue(subject.isCovered)
    }

    func testComingStraightBackDoesNotLock() async {
        let subject = lock(delay: .oneMinute)
        await unlockSuccessfully(subject)

        subject.willResignActive()
        clock.advance(5)
        subject.didBecomeActive()

        XCTAssertFalse(subject.isLocked, "checking a message must not cost a Face ID")
        XCTAssertFalse(subject.isCovered)
    }

    func testImmediatelyLocksOnAnyDeparture() async {
        let subject = lock(delay: .immediately)
        await unlockSuccessfully(subject)

        subject.willResignActive()
        subject.didBecomeActive()

        XCTAssertTrue(subject.isLocked)
    }

    func testTheClockMovingBackwardsLocks() async {
        let subject = lock(delay: .oneHour)
        await unlockSuccessfully(subject)

        subject.willResignActive()
        // Winding the clock back is how someone would outrun an hour-long
        // timeout without knowing the passcode.
        clock.advance(-7200)
        subject.didBecomeActive()

        XCTAssertTrue(subject.isLocked)
    }

    func testTheClockStartsAtTheFirstDepartureNotTheLast() async {
        let subject = lock(delay: .oneMinute)
        await unlockSuccessfully(subject)

        // iOS sends `.inactive` and then `.background`. If the second reset the
        // clock, the seconds already spent away would be handed back.
        subject.willResignActive()
        clock.advance(40)
        subject.willResignActive()
        clock.advance(40)
        subject.didBecomeActive()

        XCTAssertTrue(subject.isLocked)
    }

    func testDisabledNeverLocks() {
        let subject = lock(delay: .immediately, enabled: false)
        subject.willResignActive()
        subject.didBecomeActive()
        XCTAssertFalse(subject.isLocked)
        XCTAssertFalse(subject.isCovered)
    }

    // MARK: - The cover

    func testLeavingCoversImmediatelyEvenWithinTheDelay() async {
        let subject = lock(delay: .oneHour)
        await unlockSuccessfully(subject)

        subject.willResignActive()

        // The app switcher photographs the window while the scene is merely
        // inactive. A cover that waits for the timeout is a cover that appears
        // after the picture.
        XCTAssertTrue(subject.isCovered)
        XCTAssertFalse(subject.isLocked, "covered is not the same as owing authentication")
    }

    func testCoveredWhileLockedEvenAfterComingBack() async {
        let subject = lock()
        subject.willResignActive()
        subject.didBecomeActive()
        XCTAssertTrue(subject.isCovered)
    }

    // MARK: - Unlocking

    func testASuccessfulAttemptOpensIt() async {
        let subject = lock()
        await subject.unlock()

        XCTAssertFalse(subject.isLocked)
        XCTAssertFalse(subject.isCovered)
        XCTAssertEqual(stub.attempts, 1)
    }

    func testARefusedAttemptKeepsItShut() async {
        let subject = lock()
        stub.answer = .refused
        await subject.unlock()

        XCTAssertTrue(subject.isLocked)
        XCTAssertTrue(subject.lastAttemptRefused, "the screen should say so rather than look broken")
    }

    func testRetryingAfterARefusalIsAllowed() async {
        let subject = lock()
        stub.answer = .refused
        await subject.unlock()
        stub.answer = nil
        await subject.unlock()

        XCTAssertFalse(subject.isLocked)
        XCTAssertFalse(subject.lastAttemptRefused)
        XCTAssertEqual(stub.attempts, 2)
    }

    func testLosingThePasscodeOpensItAndTurnsItOff() async {
        let subject = lock()
        stub.answer = .unavailable
        await subject.unlock()

        // Not a way in — removing a passcode requires knowing it. The failure
        // being avoided is the owner locked out of their own paired machines
        // with nothing left to authenticate against.
        XCTAssertFalse(subject.isLocked)
        XCTAssertFalse(subject.isEnabled)
    }

    func testSwitchingTheLockOffOpensItNow() async {
        let subject = lock()
        XCTAssertTrue(subject.isLocked)

        subject.isEnabled = false

        XCTAssertFalse(subject.isLocked, "otherwise someone is stuck behind a lock they just switched off")
        XCTAssertFalse(subject.isCovered)
    }

    func testTheChoiceSurvivesARelaunch() {
        let first = lock()
        first.isEnabled = false
        first.delay = .fifteenMinutes

        let second = AppLock(authenticator: stub, defaults: suite, now: clock.read)
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(second.delay, .fifteenMinutes)
    }

    // MARK: - Guarding an action

    func testAnIrreversibleActionAsksAgain() async {
        let subject = lock()
        await unlockSuccessfully(subject)

        let proceed = await subject.confirm("Forget this Mac.")

        XCTAssertTrue(proceed)
        XCTAssertEqual(stub.attempts, 2, "unlocking earlier must not stand in for this")
        XCTAssertEqual(stub.reasons.last, "Forget this Mac.")
    }

    func testARefusedConfirmationStopsTheAction() async {
        let subject = lock()
        await unlockSuccessfully(subject)
        stub.answer = .refused

        let proceed = await subject.confirm("Forget this Mac.")
        XCTAssertFalse(proceed)
    }

    func testNoLockMeansNoExtraPrompt() async {
        let subject = lock(enabled: false)
        let proceed = await subject.confirm("Forget this Mac.")

        XCTAssertTrue(proceed)
        XCTAssertEqual(stub.attempts, 0, "a lock nobody turned on must not add prompts")
    }

    // MARK: - Helpers

    private func unlockSuccessfully(_ subject: AppLock) async {
        stub.answer = nil
        await subject.unlock()
        XCTAssertFalse(subject.isLocked)
    }
}
