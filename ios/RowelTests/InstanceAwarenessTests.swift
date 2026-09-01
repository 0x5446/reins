/// Telling two Bridle identities on one Mac apart, and staying honest about
/// which layer of an unreachable machine actually died.
///
/// Every rule here traces to one week of running a real identity and a demo
/// identity side by side: two pairings named `alphadeMacBook-Pro`, an offline
/// banner that could not say which one it meant, a rename that a re-pair
/// silently undid, and a relay close code that carried the only structured
/// verdict — destroyed before the screen saw it.

import XCTest
@testable import Rowel

private func bundle(device: String, key: String, name: String, direct: [String] = []) -> PairingBundle {
    PairingBundle(v: 1, relay: "wss://relay.test", direct: direct, device: device, key: key, token: "", name: name)
}

private func machine(_ id: String, key: String, name: String) -> PairedMachine {
    PairedMachine(bundle: bundle(device: id, key: key, name: name))
}

// MARK: - Collision labels

final class MachineLabelTests: XCTestCase {
    // Real base64url keys so fingerprints derive; the *names* drive collision.
    private let keyA = Data(repeating: 1, count: 32).base64urlString
    private let keyB = Data(repeating: 2, count: 32).base64urlString

    func testOneMachineOfANameCarriesNoSuffix() {
        let one = machine("a", key: keyA, name: "MacBook")
        let other = machine("b", key: keyB, name: "Different")
        XCTAssertNil(MachineLabel.resolve(one, among: [one, other]).suffix,
                     "a suffix with nothing to disambiguate is noise on every single-Mac install")
    }

    func testCollidingNamesGetDistinctSuffixes() {
        let one = machine("a", key: keyA, name: "MacBook")
        let two = machine("b", key: keyB, name: "MacBook")
        let first = MachineLabel.resolve(one, among: [one, two])
        let second = MachineLabel.resolve(two, among: [one, two])
        XCTAssertNotNil(first.suffix)
        XCTAssertNotEqual(first.suffix, second.suffix, "two suffixes that match separate nothing")
        XCTAssertEqual(first.suffix?.count, 4, "the short form comes first; growth is for real collisions")
    }

    func testSuffixGrowsPastAFingerprintPrefixCollision() {
        // Crafted fingerprints, because mining real keys for a four-character
        // collision would make this test a lottery.
        XCTAssertEqual(MachineLabel.disambiguate("AAAABBBBCCCC", against: ["AAAAXXXXYYYY"]), "AAAABBBB",
                       "a four-character suffix both machines share tells nobody apart")
        XCTAssertEqual(MachineLabel.disambiguate("AAAABBBBCCCC", against: ["AAAABBBBYYYY"]), "AAAABBBBCCCC")
        XCTAssertEqual(MachineLabel.disambiguate("AAAABBBBCCCC", against: ["ZZZZ"]), "AAAA")
    }

    func testProseFormJoinsNameAndSuffix() {
        XCTAssertEqual(MachineLabel(name: "MacBook", suffix: "F943").prose, "MacBook · F943")
        XCTAssertEqual(MachineLabel(name: "MacBook", suffix: nil).prose, "MacBook")
    }
}

// MARK: - Re-pairing

final class RepairingTests: XCTestCase {
    func testAbsorbingKeepsThePhonesNameAndTheWireFactsMove() {
        var original = machine("dev1", key: Data(repeating: 3, count: 32).base64urlString, name: "alphadeMacBook-Pro")
        original.name = "工作机"  // the rename someone made to tell two apart

        let fresh = bundle(device: "dev1", key: original.key, name: "alphadeMacBook-Pro",
                           direct: ["ws://10.0.0.9:61000"])
        let merged = original.absorbing(fresh)

        XCTAssertEqual(merged.name, "工作机", "a re-pair silently undid the rename that existed to tell two same-named machines apart")
        XCTAssertEqual(merged.reportedName, "alphadeMacBook-Pro", "the Mac's own name must stay reachable for 'Use the Mac's name'")
        XCTAssertEqual(merged.direct, ["ws://10.0.0.9:61000"], "the wire facts are the whole point of re-pairing")
        XCTAssertEqual(merged.addedAt, original.addedAt, "re-pairing is not a new pairing")
    }

    func testAbsorbingAnUnnamedBundleKeepsTheOldReportedName() {
        var original = machine("dev1", key: Data(repeating: 4, count: 32).base64urlString, name: "Mac")
        original.reportedName = "Mac"
        original.name = "自己的名字"
        let merged = original.absorbing(bundle(device: "dev1", key: original.key, name: ""))
        XCTAssertEqual(merged.reportedName, "Mac", "an empty bundle name is a Bridle with nothing to say, not a deletion order")
    }
}

// MARK: - The ready frame's harness field

final class HarnessInfoTests: XCTestCase {
    func testReadyDecodesHarnessWhenPresent() throws {
        let json = """
        {"t":"ready","version":1,"bridle":"0.1.1","machine":"Mac","dshReachable":true,
         "harness":{"url":"http://127.0.0.1:3081","home":"/Users/a/rowel-demo/rowel-home"},"seq":7}
        """.data(using: .utf8)!
        guard case .ready(let ready) = try ServerFrame.decode(json) else {
            return XCTFail("not a ready frame")
        }
        XCTAssertEqual(ready.harness?.url, "http://127.0.0.1:3081")
        XCTAssertEqual(ready.harness?.home, "/Users/a/rowel-demo/rowel-home")
        XCTAssertEqual(ready.harness?.port, "3081")
    }

    func testReadyWithoutHarnessIsAnOlderBridleNotAnError() throws {
        let json = """
        {"t":"ready","version":1,"bridle":"0.1.0","machine":"Mac","dshReachable":true,"seq":7}
        """.data(using: .utf8)!
        guard case .ready(let ready) = try ServerFrame.decode(json) else {
            return XCTFail("not a ready frame")
        }
        XCTAssertNil(ready.harness, "an older Bridle must cost the app a label, nothing more")
    }

    func testPortParsing() {
        XCTAssertEqual(HarnessInfo(url: "http://127.0.0.1:3080", home: "").port, "3080")
        XCTAssertNil(HarnessInfo(url: "http://harness.local", home: "").port)
        XCTAssertNil(HarnessInfo(url: "", home: "").port)
    }
}

// MARK: - Dial diagnosis

final class DialDiagnosisTests: XCTestCase {
    func testTheRelaysOwnRefusalIsTheOnlyVerdictThatNarrows() {
        let saysOffline = DialDiagnosis(outcomes: [
            PathOutcome(carrier: .lan, label: "Wi-Fi", closeCode: nil, reason: "timed out"),
            PathOutcome(carrier: .relay, label: "Relay", closeCode: 4404, reason: "that machine is offline"),
        ])
        XCTAssertTrue(saysOffline.relaySaysOffline)

        // The relay being unreachable proves nothing about the machine — that
        // was the whole lesson of the empty-state text this feeds.
        let relayDark = DialDiagnosis(outcomes: [
            PathOutcome(carrier: .relay, label: "Relay", closeCode: nil, reason: "could not connect"),
        ])
        XCTAssertFalse(relayDark.relaySaysOffline)

        // A LAN listener refusing with some code is not the relay's verdict.
        let lanCode = DialDiagnosis(outcomes: [
            PathOutcome(carrier: .lan, label: "Wi-Fi", closeCode: 4404, reason: "odd"),
        ])
        XCTAssertFalse(lanCode.relaySaysOffline)
    }
}
