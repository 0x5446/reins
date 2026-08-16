/// What the tunnel does when the network misbehaves.
///
/// Not the happy path — that one announces itself. These are the cases that
/// were shipped broken and found by using the app: a dial that took sixteen
/// seconds because it was serial, a socket that died without telling anyone and
/// left the app confidently showing a stale conversation, a Wi-Fi network the
/// connection should have moved onto and did not.
///
/// Every timing here is compressed. `TunnelTimings` exists for that reason: the
/// shipping silence limit is forty seconds and a suite that waits forty seconds
/// to make one assertion is a suite that stops being run.

import XCTest
@testable import Reins

final class TunnelTests: XCTestCase {
    private var identity: StaticKeyPair!

    override func setUp() {
        super.setUp()
        identity = .generate()
    }

    // MARK: - Racing

    /// The regression that started all of this. A phone off Wi-Fi used to spend
    /// eight seconds per unreachable local address *before* the relay was
    /// dialled at all, which on cellular is the only address that can work.
    func testAnUnreachableLocalAddressDoesNotDelayTheRelay() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("192.168.1.9:61000", to: .blackHole)
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.handshake = 30       // The black hole must not be what ends this.
        timings.relayHeadStart = 0.01
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        let started = Date()
        await tunnel.start()
        try await waitForOnline(tunnel)
        let took = Date().timeIntervalSince(started)

        let carrier = await tunnel.status
        XCTAssertEqual(carrier, .online(carrier: .relay, machine: "a-mac", harnessUp: true))
        XCTAssertLessThan(took, 2, "the relay waited for the local address to time out")
        await tunnel.stop()
    }

    /// And the property that ordering used to buy, which the head start has to
    /// keep: at home the relay is not dialled at all.
    func testALocalAddressWinsAndTheRelayIsNeverDialled() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("192.168.1.9:61000", to: .machine(mac))
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.relayHeadStart = 0.5
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)

        let status = await tunnel.status
        XCTAssertEqual(status, .online(carrier: .lan, machine: "a-mac", harnessUp: true))
        XCTAssertEqual(board.dialledAddresses, ["192.168.1.9:61000"], "the relay was dialled anyway")
        await tunnel.stop()
    }

    // MARK: - Liveness

    /// The bug behind "I sent a message and nothing happened". The socket stops
    /// delivering, nobody is told, and the app goes on saying it is connected.
    func testASilentCarrierIsDroppedAndReplaced() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.silenceLimit = 0.3
        timings.livenessCheck = 0.05
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        let first = await mac.handshakes
        XCTAssertEqual(first, 1)

        // Dead in the way that matters: still open, still writable, delivering
        // nothing. Before the watchdog this state lasted until TCP gave up.
        board.carrier(for: "relay.test:0")?.goQuiet()

        try await waitFor("a second handshake") { await mac.handshakes >= 2 }
        let status = await tunnel.status
        XCTAssertEqual(status, .online(carrier: .relay, machine: "a-mac", harnessUp: true))
        await tunnel.stop()
    }

    /// Reconnecting has to pick up where it stopped, or the watchdog would trade
    /// a stale conversation for a hole in one.
    func testTheReplacementResumesFromTheLastEventSeen() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))

        var timings = TunnelTimings()
        timings.silenceLimit = 0.3
        timings.livenessCheck = 0.05
        let tunnel = make(bundle: mac.bundle(direct: nil), board: board, timings: timings)

        let events = await collectSignals(tunnel)
        await tunnel.start()
        try await waitForOnline(tunnel)

        // The machine pushes on its own end of the pipe; the app end is the
        // one to silence, since that is the side a delivery lands on.
        guard let machineSide = await mac.served.last,
              let appSide = board.carrier(for: "relay.test:0") else { return XCTFail("no carrier") }
        await mac.emit(seq: 41, to: machineSide)
        try await waitFor("the event to be folded") { await events.count >= 1 }

        appSide.goQuiet()
        try await waitFor("a second handshake") { await mac.handshakes >= 2 }
        try await waitFor("a resume") { await mac.resumedFrom.count >= 2 }

        let resumes = await mac.resumedFrom
        XCTAssertEqual(resumes.last, 41, "the reconnect asked for the wrong point in the log")
        await tunnel.stop()
    }

    // MARK: - Upgrading

    /// Walking in the door should take the connection off the relay, and must
    /// not interrupt it to do so.
    func testWiFiAppearingMovesTheConnectionOffTheRelay() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .blackHole)

        var timings = TunnelTimings()
        timings.handshake = 0.2
        timings.relayHeadStart = 0
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        var status = await tunnel.status
        XCTAssertEqual(status, .online(carrier: .relay, machine: "a-mac", harnessUp: true))

        // The Mac becomes reachable locally, which is what joining the network
        // means from the app's side.
        board.route("192.168.1.9:61000", to: .machine(mac))
        await tunnel.networkChangedForTesting(onWiFi: true)

        try await waitFor("the switch to the local address") {
            if case .online(.lan, _, _) = await tunnel.status { return true }
            return false
        }
        status = await tunnel.status
        // Carried across the swap rather than reset — nothing about dsh changed.
        XCTAssertEqual(status, .online(carrier: .lan, machine: "a-mac", harnessUp: true))
        await tunnel.stop()
    }

    /// The upgrade must not fire on cellular, where it can only ever cost two
    /// timeouts with the radio awake for both.
    func testNoUpgradeIsAttemptedWithoutWiFi() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .blackHole)

        var timings = TunnelTimings()
        timings.handshake = 0.2
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)
        await tunnel.start()
        try await waitForOnline(tunnel)

        board.route("192.168.1.9:61000", to: .machine(mac))
        let before = board.dialledAddresses.count
        await tunnel.poke()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(board.dialledAddresses.count, before, "it dialled the local address with no Wi-Fi")
        let status = await tunnel.status
        XCTAssertEqual(status, .online(carrier: .relay, machine: "a-mac", harnessUp: true))
        await tunnel.stop()
    }

    /// A local address that connects and immediately dies must not be tried
    /// again straight away, or the app spends its life switching.
    func testAnAddressThatFlapsIsLeftAloneForAWhile() async throws {
        let mac = FakeBridle()
        let board = TestSwitchboard()
        board.route("relay.test:0", to: .machine(mac))
        board.route("192.168.1.9:61000", to: .machine(mac))

        var timings = TunnelTimings()
        timings.relayHeadStart = 0.5
        timings.flapWindow = 5
        timings.flapPenalty = 60
        let tunnel = make(bundle: mac.bundle(direct: ["ws://192.168.1.9:61000"]), board: board, timings: timings)

        await tunnel.start()
        try await waitForOnline(tunnel)
        var status = await tunnel.status
        XCTAssertEqual(status, .online(carrier: .lan, machine: "a-mac", harnessUp: true))

        // Dies well inside the flap window.
        board.carrier(for: "192.168.1.9:61000")?.close("wifi dropped")

        try await waitFor("a fall back to the relay") {
            if case .online(.relay, _, _) = await tunnel.status { return true }
            return false
        }
        status = await tunnel.status
        XCTAssertEqual(status, .online(carrier: .relay, machine: "a-mac", harnessUp: true))

        // And it stays off it: an upgrade offered now is declined.
        let before = board.dialledAddresses.filter { $0 == "192.168.1.9:61000" }.count
        await tunnel.networkChangedForTesting(onWiFi: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = board.dialledAddresses.filter { $0 == "192.168.1.9:61000" }.count
        XCTAssertEqual(after, before, "the penalised address was dialled again")
        await tunnel.stop()
    }

    // MARK: - Helpers

    private func make(
        bundle: PairingBundle,
        board: TestSwitchboard? = nil,
        timings: TunnelTimings
    ) -> Tunnel {
        let board = board ?? {
            let fresh = TestSwitchboard()
            return fresh
        }()
        return Tunnel(
            bundle: bundle,
            identity: identity,
            deviceName: "iPhone",
            clientVersion: "test",
            pairingToken: nil,
            open: board.opener,
            watchNetwork: false,
            timings: timings
        )
    }

    private func waitForOnline(_ tunnel: Tunnel) async throws {
        try await waitFor("the tunnel to come online") {
            if case .online = await tunnel.status { return true }
            return false
        }
    }

    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func collectSignals(_ tunnel: Tunnel) async -> Counter {
        let counter = Counter()
        let stream = await tunnel.signals()
        Task {
            for await signal in stream {
                if case .event = signal { await counter.bump() }
            }
        }
        return counter
    }
}

/// Somewhere for the signal task to put what it saw.
actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}
