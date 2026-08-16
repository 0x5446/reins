/// The writes, and what they leave behind when the Mac says no.
///
/// Every workspace mutation here shows its result before the machine has agreed
/// to it, because a header that waits out a round trip reads as a tap that
/// missed. That trade is only safe if the undo is real, and an undo that has
/// never been run is an undo nobody has checked — so these tests are mostly
/// about failure: the name goes back, the section comes back, the conversation
/// goes back where it was, and the person is told in words.
///
/// The transport is stubbed rather than the harness, so the payloads asserted
/// here are the ones a real Bridle would receive. Their shapes come from dsh's
/// own request schemas, which is why the assertions name exact keys.

import XCTest
@testable import Reins

/// A transport that answers from a script and refuses on command.
private actor StubTransport: HarnessTransport {
    private struct Refusal {
        var error: CallError
        /// How many calls to let through before refusing the rest.
        var after: Int
    }

    private var answers: [String: JSONValue] = [:]
    private var refusals: [String: Refusal] = [:]
    private var sent: [(method: String, payload: JSONValue)] = []

    func answer(_ method: String, _ value: JSONValue) {
        answers[method] = value
    }

    /// - Parameter after: calls to allow first, for the paths that make two.
    func fail(_ method: String, code: String = "internal", message: String, after: Int = 0) {
        refusals[method] = Refusal(error: CallError(code: code, message: message), after: after)
    }

    func payloads(_ method: String) -> [JSONValue] {
        sent.filter { $0.method == method }.map(\.payload)
    }

    func count(_ method: String) -> Int {
        sent.filter { $0.method == method }.count
    }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        let already = sent.filter { $0.method == method }.count
        sent.append((method, payload))
        if let refusal = refusals[method], already >= refusal.after { throw refusal.error }
        return answers[method] ?? .emptyObject
    }

    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue {
        .emptyObject
    }
}

// MARK: - Fixtures

private func workspaceRow(_ id: String, path: String, title: String, sessions: [String] = []) -> JSONValue {
    .object([
        "workspaceId": .string(id),
        "path": .string(path),
        "title": .string(title),
        "sessionIds": .array(sessions.map(JSONValue.string)),
        "createdAt": .string("2026-07-25T09:41:07.000Z"),
        "updatedAt": .string("2026-07-25T09:41:07.000Z"),
    ])
}

private func sessionRow(_ id: String, cwd: String?, updatedAt: Double = 1_700_000_000_000) -> JSONValue {
    .object(dropping: [
        "sessionId": .string(id),
        "updatedAt": .number(updatedAt),
        "running": .bool(false),
        "blank": .bool(false),
        "cwd": cwd.map(JSONValue.string),
    ])
}

@MainActor
final class WorkspaceWriteTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var stub: StubTransport!

    override func setUp() {
        super.setUp()
        suiteName = "reins.workspace.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        stub = StubTransport()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func machine() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid",
            device: "device-1",
            key: "",
            token: "",
            name: "Test Mac"
        )
        // Never started, so nothing dials anything: the tunnel this builds sits
        // idle and every call goes to the stub instead.
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "reins-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: stub
        )
    }

    /// One workspace holding one conversation, plus a stray in a folder no
    /// workspace claims. The smallest shape with something to lose.
    private func loaded() async -> MachineSession {
        await stub.answer("workspace.list", .object([
            "items": .array([workspaceRow("w1", path: "/code/one", title: "One", sessions: ["s1"])]),
            "archivedSessionIds": .array([]),
        ]))
        await stub.answer("session.list", .object([
            "items": .array([
                sessionRow("s1", cwd: "/code/one"),
                sessionRow("stray", cwd: "/code/two", updatedAt: 1_699_999_000_000),
            ]),
        ]))
        let session = machine()
        await session.refreshSessions()
        return session
    }

    // MARK: - Reading

    func testListingWorkspacesIsWhatMakesTheMachineCountAsGrouping() async {
        let session = await loaded()
        XCTAssertTrue(session.canGroup)
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(session.placement(for: "/code/one"), .joins(workspaceId: "w1", title: "One"))
    }

    func testTheArchiveSetArrivesWithTheWorkspaces() async {
        await stub.answer("workspace.list", .object([
            "items": .array([]),
            "archivedSessionIds": .array([.string("gone")]),
        ]))
        let session = machine()
        await session.refreshWorkspaces()
        XCTAssertEqual(session.archivedSessionIds, ["gone"])
    }

    /// The degradation that has to work. A dsh with no `workspace.list` answers
    /// HTTP 404, which the Bridle reports as `internal` — indistinguishable from
    /// a real fault, which is exactly why nothing may be concluded from it.
    func testAMachineWithoutWorkspacesStillListsItsConversationsAndSaysNothing() async {
        await stub.fail("workspace.list", message: "dsh answered HTTP 404: not found")
        await stub.answer("session.list", .object([
            "items": .array([sessionRow("s1", cwd: "/code/one")]),
        ]))
        let session = machine()
        await session.refreshSessions()

        XCTAssertEqual(session.sessions.map(\.id), ["s1"], "the list is the screen; it must fill in regardless")
        XCTAssertTrue(session.workspaces.isEmpty)
        XCTAssertFalse(session.canGroup)
        XCTAssertNil(session.problem, "a machine that cannot group is not a machine with a problem")
        XCTAssertEqual(session.placement(for: "/code/one"), .unknown)
        XCTAssertEqual(session.filing(for: session.sessions[0]), .settled)
    }

    /// A dropped call must not flatten a machine that does group. The last known
    /// list stands.
    func testALaterFailureKeepsWhatWasAlreadyKnown() async {
        let session = await loaded()
        await stub.fail("workspace.list", code: "disconnected", message: "The connection dropped.")
        await session.refreshWorkspaces()

        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        XCTAssertTrue(session.canGroup)
    }

    // MARK: - Making one

    func testClaimingAFolderSendsThePathAndAddsTheWorkspace() async {
        let session = await loaded()
        await stub.answer("workspace.create", .object([
            "workspace": workspaceRow("w2", path: "/code/two", title: "two"),
            "created": .bool(true),
        ]))

        let failure = await session.createWorkspace(path: "/code/two")
        let sent = await stub.payloads("workspace.create")

        XCTAssertNil(failure)
        XCTAssertEqual(sent, [.object(["path": .string("/code/two")])])
        XCTAssertEqual(session.workspaces.map(\.id), ["w2", "w1"])
        XCTAssertEqual(session.placement(for: "/code/two"), .joins(workspaceId: "w2", title: "two"))
    }

    /// The machine resolves a folder it already owns instead of erroring, and
    /// the second answer must not put a duplicate section on screen.
    func testClaimingAFolderThatIsAlreadyAWorkspaceChangesNothing() async {
        let session = await loaded()
        await stub.answer("workspace.create", .object([
            "workspace": workspaceRow("w1", path: "/code/one", title: "One", sessions: ["s1"]),
            "created": .bool(false),
        ]))

        let failure = await session.createWorkspace(path: "/code/one")
        XCTAssertNil(failure)
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
    }

    /// Nothing is shown before the machine agrees, because there is nothing
    /// honest to show: only the machine knows the id, and a section drawn
    /// hopefully would be a section standing over nothing.
    func testAFolderTheMachineRefusesAddsNoSection() async {
        let session = await loaded()
        await stub.fail(
            "workspace.create",
            code: "workspace-invalid-path",
            message: "cannot create a workspace at \"/code/nope\": path is not a directory"
        )

        let failure = await session.createWorkspace(path: "/code/nope")
        XCTAssertEqual(failure, "cannot create a workspace at \"/code/nope\": path is not a directory")
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        // Returned rather than banner-ed: this is done inside the folder sheet,
        // and the banner lives on the screen behind it.
        XCTAssertNil(session.problem)
    }

    // MARK: - Renaming

    func testRenamingSendsTheIdAndTheTitle() async {
        let session = await loaded()
        await stub.answer("workspace.rename", .object([
            "workspace": workspaceRow("w1", path: "/code/one", title: "Renamed", sessions: ["s1"]),
        ]))

        let renamed = await session.renameWorkspace("w1", title: "  Renamed  ")
        let sent = await stub.payloads("workspace.rename")

        XCTAssertTrue(renamed)
        // Trimmed here as well as on the machine, so what is drawn locally and
        // what is stored cannot disagree by a space.
        XCTAssertEqual(sent, [.object([
            "workspaceId": .string("w1"),
            "title": .string("Renamed"),
        ])])
        XCTAssertEqual(session.workspaces[0].displayTitle, "Renamed")
    }

    func testARefusedRenamePutsTheOldNameBackAndSaysWhy() async {
        let session = await loaded()
        await stub.fail(
            "workspace.rename",
            code: "workspace-name-conflict",
            message: "workspace name 'Two' is already in use"
        )

        let renamed = await session.renameWorkspace("w1", title: "Two")
        XCTAssertFalse(renamed)
        XCTAssertEqual(session.workspaces[0].displayTitle, "One")
        XCTAssertEqual(session.problem, "workspace name 'Two' is already in use")
    }

    /// Caught here rather than sent, so the empty case costs no round trip and
    /// says something better than a schema message would.
    func testABlankNameIsRefusedWithoutAskingTheMachine() async {
        let session = await loaded()
        let renamed = await session.renameWorkspace("w1", title: "   ")
        let attempts = await stub.count("workspace.rename")

        XCTAssertFalse(renamed)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(session.workspaces[0].displayTitle, "One")
        XCTAssertEqual(session.problem, "A workspace needs a name.")
    }

    // MARK: - Removing

    func testRemovingAWorkspaceSendsItsIdAndDropsTheSection() async {
        let session = await loaded()
        let removed = await session.deleteWorkspace("w1")
        let sent = await stub.payloads("workspace.delete")

        XCTAssertTrue(removed)
        XCTAssertEqual(sent, [.object(["workspaceId": .string("w1")])])
        XCTAssertTrue(session.workspaces.isEmpty)
    }

    /// The conversations are the point of the confirmation copy: removing a
    /// workspace removes the grouping and nothing else, so every row has to
    /// still be reachable afterwards.
    func testRemovingAWorkspaceKeepsItsConversations() async {
        let session = await loaded()
        _ = await session.deleteWorkspace("w1")

        let board = SessionBoard(sessions: session.sessions, workspaces: session.workspaces)
        XCTAssertEqual(Set(board.groups.flatMap { $0.sessions.map(\.id) }), ["s1", "stray"])
        XCTAssertEqual(board.groups.map(\.id), [SessionGroup.ungroupedId])
    }

    func testARefusedRemovalPutsTheSectionBack() async {
        let session = await loaded()
        await stub.fail("workspace.delete", code: "workspace-not-found", message: "workspace \"w1\" not found")

        let removed = await session.deleteWorkspace("w1")
        XCTAssertFalse(removed)
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(session.workspaces[0].sessionIds, ["s1"], "the membership has to come back with it")
        XCTAssertEqual(session.problem, "workspace \"w1\" not found")
    }

    // MARK: - Filing a stray conversation

    /// There is no `workspace.attachSession` on the wire. `session.create` is
    /// idempotent for an id that already exists, and given a `workspaceId` it
    /// attaches — that is the whole of the mechanism, and this pins the payload.
    func testFilingAConversationGoesOutAsAnIdempotentCreate() async {
        let session = await loaded()
        let filed = await session.fileSession("stray", into: "w1")
        let sent = await stub.payloads("session.create")

        XCTAssertTrue(filed)
        XCTAssertEqual(sent, [.object([
            "sessionId": .string("stray"),
            "workspaceId": .string("w1"),
        ])])
        XCTAssertEqual(session.workspaces[0].sessionIds, ["stray", "s1"])
    }

    func testARefusedFilingLeavesTheConversationWhereItWas() async {
        let session = await loaded()
        await stub.fail(
            "session.create",
            code: "session-conflict",
            message: "session \"stray\" already exists with cwd \"/code/two\""
        )

        let filed = await session.fileSession("stray", into: "w1")
        XCTAssertFalse(filed)
        XCTAssertEqual(session.workspaces[0].sessionIds, ["s1"])
        XCTAssertEqual(session.problem, "session \"stray\" already exists with cwd \"/code/two\"")
    }

    // MARK: - Starting a conversation in a workspace

    /// The folder goes out as `cwd`, never as `workspaceId`, and the grouping is
    /// a second call. A dsh new enough for `workspace.list` but not for
    /// `session.create {workspaceId}` would drop the unknown key and start the
    /// conversation in its own default directory — the wrong folder is a worse
    /// failure than the wrong section.
    func testStartingInAWorkspaceFolderSendsTheFolderThenJoins() async {
        let session = await loaded()
        await stub.answer("session.create", .object(["sessionId": .string("fresh")]))

        let id = await session.createSession(cwd: "/code/one")
        let sent = await stub.payloads("session.create")

        XCTAssertEqual(id, "fresh")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first, .object(["cwd": .string("/code/one")]))
        XCTAssertEqual(sent.last, .object([
            "sessionId": .string("fresh"),
            "workspaceId": .string("w1"),
        ]))
        XCTAssertNil(session.problem)
    }

    func testStartingInAnUnclaimedFolderMakesOnlyOneCall() async {
        let session = await loaded()
        await stub.answer("session.create", .object(["sessionId": .string("fresh")]))

        _ = await session.createSession(cwd: "/code/two")
        let attempts = await stub.count("session.create")

        XCTAssertEqual(attempts, 1)
        XCTAssertNil(session.problem)
    }

    /// The conversation is real and open in the right folder, so this is not a
    /// failure to start anything — but the folder sheet had just named the
    /// section it would appear under, and being quietly wrong about that is
    /// worse than saying so.
    func testAConversationThatStartsButCannotJoinSaysSo() async {
        let session = await loaded()
        await stub.answer("session.create", .object(["sessionId": .string("fresh")]))
        await stub.fail("session.create", code: "workspace-attach-failed", message: "could not attach", after: 1)

        let id = await session.createSession(cwd: "/code/one")
        XCTAssertEqual(id, "fresh", "the conversation exists and is in the right folder")
        XCTAssertEqual(session.problem, "Started, but it didn’t join One. It’s under Ungrouped.")
        XCTAssertTrue(session.sessions.contains { $0.id == "fresh" }, "and it is reachable from the list")
    }

    // MARK: - Archiving

    /// `session.list` keeps answering with archived conversations, so marking
    /// rather than removing is what makes the archive survive a refresh. It did
    /// not, before: the row came back the next time the list was pulled.
    func testArchivingHidesTheConversationAndSurvivesARefresh() async {
        let session = await loaded()
        await session.archive(sessionId: "s1")
        let sent = await stub.payloads("workspace.archiveSession")

        XCTAssertEqual(session.archivedSessionIds, ["s1"])
        XCTAssertEqual(sent, [.object(["sessionId": .string("s1")])])

        // What the machine answers from here on. `session.list` keeps the row —
        // that is the point — and only the archive set says it should be gone.
        await stub.answer("workspace.list", .object([
            "items": .array([workspaceRow("w1", path: "/code/one", title: "One", sessions: ["s1"])]),
            "archivedSessionIds": .array([.string("s1")]),
        ]))
        await session.refreshSessions()
        XCTAssertTrue(session.sessions.contains { $0.id == "s1" }, "the machine still reports it")
        let board = SessionBoard(
            sessions: session.sessions,
            workspaces: session.workspaces,
            archived: session.archivedSessionIds
        )
        XCTAssertFalse(board.groups.flatMap { $0.sessions.map(\.id) }.contains("s1"))
    }

    func testARefusedArchiveBringsTheConversationBack() async {
        let session = await loaded()
        await stub.fail("workspace.archiveSession", code: "session-not-found", message: "session \"s1\" not found")

        await session.archive(sessionId: "s1")
        XCTAssertTrue(session.archivedSessionIds.isEmpty)
        XCTAssertEqual(session.problem, "session \"s1\" not found")
    }
}
