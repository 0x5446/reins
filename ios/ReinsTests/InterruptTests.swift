/// The two moments the machine stops and waits for a person.
///
/// Untested until an `ask_user_question` went unanswered on a phone while the
/// web UI showed a card with three options on it. The payloads here are the
/// ones that produced that — captured from the wire, not written from the
/// method names — because the failure was never in the rendering and could
/// only ever have been found by folding what a real dsh actually sends.

import XCTest
@testable import Reins

@MainActor
final class InterruptTests: XCTestCase {
    private let sessionId = "session-1f55260e-4ce5-45a5-8fff-78e508071670"

    /// dsh's `question/requested`, verbatim apart from shortened prose.
    private func questionFrame() -> JSONValue {
        .object([
            "type": .string("server-request"),
            "rpcId": .string("cf6f20c2-a77a-4d75-bf3b-9b872198460b"),
            "method": .string("question/requested"),
            "payload": .object([
                "type": .string("question/requested"),
                "sessionId": .string(sessionId),
                "questions": .array([
                    .object([
                        "id": .string("hitl-confirm"),
                        "question": .string("是否保持 Exa 作为唯一搜索提供方？"),
                        "header": .string("HITL 确认"),
                        "options": .array([
                            .object(["label": .string("保持 Exa（推荐）"), "description": .string("维持当前配置。")]),
                            .object(["label": .string("换回 DeepSeek official"), "description": .string("需先配置 key。")]),
                            .object(["label": .string("两个都留，临时切换"), "description": .string("记下切回步骤。")]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private func approvalFrame() -> JSONValue {
        .object([
            "type": .string("server-request"),
            "rpcId": .string("a1b2c3"),
            "method": .string("approval/requested"),
            "payload": .object([
                "type": .string("approval/requested"),
                "sessionId": .string(sessionId),
                "approvalId": .string("ap-1"),
                "toolName": .string("Edit"),
                "reason": .string("escalate sandbox to danger-full-access"),
            ]),
        ])
    }

    private func event(_ frame: JSONValue) -> TunnelSignal {
        .event(EventFrame(seq: 1, stream: .mux, frame: frame))
    }

    func testAQuestionFromTheMachineBecomesACardForThatSession() {
        let session = makeSession()
        session.receiveForTesting(event(questionFrame()))

        guard let asked = session.questions[sessionId] else {
            return XCTFail("no question card; the machine is waiting and the phone shows nothing")
        }
        XCTAssertEqual(asked.id, "cf6f20c2-a77a-4d75-bf3b-9b872198460b", "the rpcId is what an answer echoes")
        XCTAssertEqual(asked.items.count, 1)
        XCTAssertEqual(asked.items[0].header, "HITL 确认")
        XCTAssertEqual(asked.items[0].options.map(\.label), ["保持 Exa（推荐）", "换回 DeepSeek official", "两个都留，临时切换"])
        XCTAssertFalse(asked.items[0].isPlanReview)
    }

    func testAnsweringElsewhereClearsTheCard() {
        let session = makeSession()
        session.receiveForTesting(event(questionFrame()))
        XCTAssertNotNil(session.questions[sessionId])

        session.receiveForTesting(event(.object([
            "rpcId": .string("x"),
            "payload": .object(["type": .string("question/resolved"), "sessionId": .string(sessionId)]),
        ])))
        XCTAssertNil(session.questions[sessionId], "the web UI answered it; the phone must stop offering to")
    }

    func testAnApprovalFromTheMachineBecomesACard() {
        let session = makeSession()
        session.receiveForTesting(event(approvalFrame()))

        guard let asked = session.approvals[sessionId] else {
            return XCTFail("no approval card; the agent is blocked and the phone shows nothing")
        }
        XCTAssertEqual(asked.toolName, "Edit")
        XCTAssertEqual(asked.reason, "escalate sandbox to danger-full-access")
    }

    /// The list has to say which conversation is waiting, since the person may
    /// be in another one or have just opened the app.
    func testTheWaitingConversationIsMarkedInTheList() {
        let session = makeSession()
        session.receiveForTesting(event(questionFrame()))
        XCTAssertNotNil(session.questions[sessionId])
    }

    private func makeSession() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        let suite = UserDefaults(suiteName: "interrupt-tests-\(UUID().uuidString)")!
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "reins-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite
        )
    }
}
