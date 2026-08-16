/// Grouping the conversation list, and remembering how it was left.
///
/// Two pieces, both deliberately outside SwiftUI. `SessionBoard` is where every
/// rule about *where a conversation goes* lives, and the interesting cases are
/// the ones a screenshot would never show: a workspace naming a session the
/// machine no longer has, a session no workspace claims, a machine whose dsh has
/// never heard of workspaces. `GroupFolds` is where "I closed that yesterday"
/// lives, and the case worth testing is the one where the default disagrees with
/// what the person said.

import XCTest
@testable import Reins

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func session(_ id: String, minutesAgo: Double = 0, cwd: String? = nil) -> SessionSummary {
    var summary = SessionSummary(.object([
        "sessionId": .string(id),
        "updatedAt": .number((epoch.timeIntervalSince1970 - minutesAgo * 60) * 1000),
    ]))!
    summary.cwd = cwd
    return summary
}

// MARK: - Parsing

final class WorkspaceParsingTests: XCTestCase {
    func testParsesListRow() {
        let workspace = Workspace(.object([
            "workspaceId": .string("w1"),
            "path": .string("/Users/x/code/invoice-service"),
            "title": .string("Invoice service"),
            "sessionIds": .array([.string("s1"), .string("s2")]),
            "createdAt": .number(1_700_000_000_000),
        ]))
        XCTAssertEqual(workspace?.id, "w1")
        XCTAssertEqual(workspace?.displayTitle, "Invoice service")
        XCTAssertEqual(workspace?.sessionIds, ["s1", "s2"])
    }

    /// Most workspaces on a real machine have no title, only a folder.
    func testUntitledWorkspaceIsNamedAfterItsFolder() {
        let workspace = Workspace(.object([
            "workspaceId": .string("w1"),
            "path": .string("/Users/x/code/invoice-service"),
        ]))
        XCTAssertEqual(workspace?.displayTitle, "invoice-service")
        XCTAssertEqual(workspace?.sessionIds, [])
    }

    func testRowWithoutIdIsRejected() {
        XCTAssertNil(Workspace(.object(["path": .string("/tmp")])))
    }

    /// Workspaces stamp ISO-8601, sessions stamp epoch milliseconds. Reading
    /// this row as a number is what the first version did, and it silently made
    /// every workspace date 1970.
    func testCreatedAtIsReadAsAnIsoString() {
        let workspace = Workspace(.object([
            "workspaceId": .string("w1"),
            "path": .string("/Users/x/code/thing"),
            "createdAt": .string("2026-07-25T09:41:07.123Z"),
        ]))
        XCTAssertEqual(workspace?.createdAt.timeIntervalSince1970 ?? 0, 1_784_972_467.123, accuracy: 0.01)
    }

    func testCreatedAtWithoutFractionalSecondsStillParses() {
        let workspace = Workspace(.object([
            "workspaceId": .string("w1"),
            "createdAt": .string("2026-07-25T09:41:07Z"),
        ]))
        XCTAssertEqual(workspace?.createdAt.timeIntervalSince1970 ?? 0, 1_784_972_467, accuracy: 0.01)
    }

    /// Kept because guessing the spelling wrong once already cost a field.
    func testCreatedAtStillAcceptsEpochMilliseconds() {
        let workspace = Workspace(.object([
            "workspaceId": .string("w1"),
            "createdAt": .number(1_700_000_000_000),
        ]))
        XCTAssertEqual(workspace?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testUnreadableCreatedAtFallsBackRatherThanRejectingTheRow() {
        let workspace = Workspace(.object([
            "workspaceId": .string("w1"),
            "createdAt": .string("last Tuesday"),
        ]))
        XCTAssertNotNil(workspace, "a date nobody can read is not a reason to lose the workspace")
        XCTAssertEqual(workspace?.createdAt, Date(timeIntervalSince1970: 0))
    }
}

// MARK: - Which workspace a folder is

/// The rule the folder browser now states out loud before a conversation
/// starts. Exact match, and the nested case is the one that matters: the machine
/// this was written against has both `~/workspace` and
/// `~/workspace/invoice-service` registered.
final class WorkspacePlacementTests: XCTestCase {
    private let registered = [
        Workspace(id: "w1", path: "/Users/dev/code", title: "workspace", sessionIds: []),
        Workspace(id: "w2", path: "/Users/dev/code/invoice-service", title: "Invoice service", sessionIds: []),
    ]

    func testAFolderThatIsAWorkspaceJoinsIt() {
        XCTAssertEqual(
            WorkspacePlacement.resolve(path: "/Users/dev/code/invoice-service", workspaces: registered, grouping: true),
            .joins(workspaceId: "w2", title: "Invoice service")
        )
    }

    /// Prefix matching would name `~/workspace` for every conversation in the
    /// nested folder, and every one of those names would be wrong.
    func testAFolderInsideAWorkspaceIsNotThatWorkspace() {
        XCTAssertEqual(
            WorkspacePlacement.resolve(path: "/Users/dev/code/something-else", workspaces: registered, grouping: true),
            .ungrouped
        )
    }

    func testATrailingSlashIsTheSameFolder() {
        XCTAssertEqual(
            WorkspacePlacement.resolve(path: "/Users/dev/code/", workspaces: registered, grouping: true),
            .joins(workspaceId: "w1", title: "workspace")
        )
    }

    func testAnUnclaimedFolderSaysSo() {
        XCTAssertEqual(
            WorkspacePlacement.resolve(path: "/tmp/scratch", workspaces: registered, grouping: true),
            .ungrouped
        )
    }

    /// The degradation. A dsh with no `workspace.list` never lets `grouping`
    /// become true, and then the screen must claim nothing at all — not
    /// "ungrouped", which is a claim, and which on that machine is meaningless.
    func testAMachineThatHasNotSaidItGroupsClaimsNothing() {
        XCTAssertEqual(
            WorkspacePlacement.resolve(path: "/Users/dev/code", workspaces: [], grouping: false),
            .unknown
        )
        XCTAssertEqual(
            WorkspacePlacement.resolve(path: "/Users/dev/code", workspaces: registered, grouping: false),
            .unknown,
            "a stale list from before the connection dropped is not permission to claim"
        )
    }

    /// "Wherever the Mac defaults to" cannot be resolved from here.
    func testNoFolderMeansNoAnswer() {
        XCTAssertEqual(WorkspacePlacement.resolve(path: nil, workspaces: registered, grouping: true), .unknown)
        XCTAssertEqual(WorkspacePlacement.resolve(path: "", workspaces: registered, grouping: true), .unknown)
    }

    func testAWorkspaceWithNoPathMatchesNothing() {
        let odd = [Workspace(id: "w1", path: nil, title: "Nowhere", sessionIds: [])]
        XCTAssertEqual(WorkspacePlacement.resolve(path: "/tmp", workspaces: odd, grouping: true), .ungrouped)
    }
}

// MARK: - What can be done about a stray conversation

final class SessionFilingTests: XCTestCase {
    private let registered = [
        Workspace(id: "w1", path: "/code/one", title: "One", sessionIds: ["held"]),
    ]

    func testAConversationTheMachineAlreadyFiledIsLeftAlone() {
        let summary = session("held", cwd: "/code/one")
        XCTAssertEqual(SessionFiling.resolve(summary, workspaces: registered, grouping: true), .settled)
    }

    /// The case this app spent a long time creating: started from the phone
    /// into a folder that already had a workspace, and never filed under it.
    func testAStrayConversationCanJoinTheWorkspaceForItsFolder() {
        let summary = session("stray", cwd: "/code/one")
        XCTAssertEqual(
            SessionFiling.resolve(summary, workspaces: registered, grouping: true),
            .join(workspaceId: "w1", title: "One")
        )
    }

    func testAStrayConversationInAnUnclaimedFolderOffersToClaimIt() {
        let summary = session("stray", cwd: "/code/two")
        XCTAssertEqual(
            SessionFiling.resolve(summary, workspaces: registered, grouping: true),
            .claim(path: "/code/two")
        )
    }

    /// Membership is a folder. Without one there is nothing to file it under,
    /// and no call would accept it.
    func testAConversationWithNoFolderOffersNothing() {
        XCTAssertEqual(SessionFiling.resolve(session("stray"), workspaces: registered, grouping: true), .settled)
    }

    func testAMachineThatDoesNotGroupOffersNothing() {
        let summary = session("stray", cwd: "/code/one")
        XCTAssertEqual(SessionFiling.resolve(summary, workspaces: registered, grouping: false), .settled)
    }

    /// Filed somewhere the folder does not explain — the machine's accounting is
    /// its own business, and offering to re-file it would be the app arguing
    /// with a decision it cannot see the reason for.
    func testAConversationHeldByADifferentWorkspaceIsLeftAlone() {
        let odd = [
            Workspace(id: "w1", path: "/code/one", title: "One", sessionIds: []),
            Workspace(id: "w2", path: "/code/two", title: "Two", sessionIds: ["s"]),
        ]
        XCTAssertEqual(SessionFiling.resolve(session("s", cwd: "/code/one"), workspaces: odd, grouping: true), .settled)
    }
}

// MARK: - Arranging

final class SessionBoardTests: XCTestCase {
    /// The shape of the machine this was written against: a couple of named
    /// workspaces, and most of the conversations in one of them.
    func testSessionsLandInTheWorkspaceThatClaimsThem() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("b", minutesAgo: 5), session("c", minutesAgo: 9)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["a"]),
                Workspace(id: "w2", path: "/code/two", sessionIds: ["b", "c"]),
            ]
        )
        XCTAssertTrue(board.grouped)
        XCTAssertEqual(board.groups.map(\.id), ["w1", "w2"])
        XCTAssertEqual(board.groups[1].sessions.map(\.id), ["b", "c"])
        XCTAssertTrue(board.waiting.isEmpty)
    }

    /// Nothing may be dropped. A conversation no workspace mentions is still a
    /// conversation, and the list is the only way to reach it.
    func testUnclaimedSessionsFallIntoTheLeftovers() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("stray", minutesAgo: 2)],
            workspaces: [Workspace(id: "w1", path: "/code/one", sessionIds: ["a"])]
        )
        XCTAssertEqual(board.groups.map(\.id), ["w1", SessionGroup.ungroupedId])
        XCTAssertEqual(board.groups[1].sessions.map(\.id), ["stray"])
        XCTAssertTrue(board.groups[1].isUngrouped)
    }

    /// The leftovers go last even when they hold the newest thing, because they
    /// are not a place anyone put anything.
    func testLeftoversSitLastEvenWhenTheyAreTheFreshest() {
        let board = SessionBoard(
            sessions: [session("stray", minutesAgo: 0), session("a", minutesAgo: 30)],
            workspaces: [Workspace(id: "w1", path: "/code/one", sessionIds: ["a"])]
        )
        XCTAssertEqual(board.groups.map(\.id), ["w1", SessionGroup.ungroupedId])
        // Ordering and opening are separate questions: the leftovers stay at the
        // bottom, but the newest conversation is still one that is on screen.
        XCTAssertEqual(board.openByDefault, SessionGroup.ungroupedId)
    }

    func testSectionsAreOrderedByTheirNewestConversation() {
        let board = SessionBoard(
            sessions: [session("old", minutesAgo: 600), session("new", minutesAgo: 2), session("middle", minutesAgo: 90)],
            workspaces: [
                Workspace(id: "stale", path: "/code/stale", sessionIds: ["old"]),
                Workspace(id: "warm", path: "/code/warm", sessionIds: ["middle"]),
                Workspace(id: "hot", path: "/code/hot", sessionIds: ["new"]),
            ]
        )
        XCTAssertEqual(board.groups.map(\.id), ["hot", "warm", "stale"])
        XCTAssertEqual(board.openByDefault, "hot")
    }

    /// A workspace can name a session `session.list` does not return — archived
    /// on the Mac, or a subagent the list hides. A header over nothing is worse
    /// than no header.
    func testGhostMembershipIsIgnoredAndLeavesNoEmptySection() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("b", minutesAgo: 2)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["a", "gone", "also-gone"]),
                Workspace(id: "empty", path: "/code/empty", sessionIds: ["vanished"]),
            ]
        )
        XCTAssertEqual(board.groups.map(\.id), ["w1", SessionGroup.ungroupedId])
        XCTAssertEqual(board.groups[0].sessions.map(\.id), ["a"])
        XCTAssertEqual(board.groups[1].sessions.map(\.id), ["b"])
    }

    /// Two workspaces naming the same session must not put it on screen twice.
    func testFirstClaimWins() {
        let board = SessionBoard(
            sessions: [session("shared", minutesAgo: 1), session("b", minutesAgo: 2)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["shared"]),
                Workspace(id: "w2", path: "/code/two", sessionIds: ["shared", "b"]),
            ]
        )
        XCTAssertEqual(board.groups.flatMap { $0.sessions.map(\.id) }, ["shared", "b"])
    }

    // MARK: - Whatever is stuck

    /// The rule the whole screen exists for: something waiting on a tap is never
    /// behind a fold.
    func testWaitingConversationsAreLiftedClearOfTheirGroup() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("stuck", minutesAgo: 40), session("c", minutesAgo: 5)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["a"]),
                Workspace(id: "w2", path: "/code/two", sessionIds: ["stuck", "c"]),
            ],
            waitingOn: ["stuck"]
        )
        XCTAssertEqual(board.waiting.map(\.id), ["stuck"])
        XCTAssertEqual(board.groups.flatMap { $0.sessions.map(\.id) }, ["a", "c"], "it appears once, at the top, not twice")
    }

    /// Lifting the only conversation out of a workspace takes the workspace with
    /// it. Accepted: the section comes back the moment the prompt is answered,
    /// and the alternative is a header standing over an empty fold.
    func testAGroupEmptiedByWaitingDisappears() {
        let board = SessionBoard(
            sessions: [session("only", minutesAgo: 1), session("b", minutesAgo: 2)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["only"]),
                Workspace(id: "w2", path: "/code/two", sessionIds: ["b"]),
            ],
            waitingOn: ["only"]
        )
        XCTAssertEqual(board.groups.map(\.id), ["w2"])
        XCTAssertEqual(board.waiting.map(\.id), ["only"])
    }

    func testWaitingIsOrderedNewestFirst() {
        let board = SessionBoard(
            sessions: [session("older", minutesAgo: 50), session("newer", minutesAgo: 2)],
            workspaces: [Workspace(id: "w1", path: "/code/one", sessionIds: ["older", "newer"])],
            waitingOn: ["older", "newer"]
        )
        XCTAssertEqual(board.waiting.map(\.id), ["newer", "older"])
    }

    // MARK: - Falling back to the flat list

    /// The degradation that has to work: a dsh with no `workspace.list`, or one
    /// that failed to answer, leaves the machine session holding no workspaces.
    /// Everything must still be reachable, and the screen must not draw sections.
    func testNoWorkspacesMeansOneUngroupedSectionAndNoGrouping() {
        let all = (0..<44).map { session("s\($0)", minutesAgo: Double($0)) }
        let board = SessionBoard(sessions: all, workspaces: [])

        XCTAssertFalse(board.grouped, "nothing to divide by, so the screen draws the list it always drew")
        XCTAssertEqual(board.groups.count, 1)
        XCTAssertEqual(board.groups[0].sessions.count, 44)
        XCTAssertNil(board.openByDefault, "there is no fold to have an opinion about")
    }

    /// One workspace holding everything is the same situation: a single header
    /// that can be collapsed to hide the entire app is not organisation.
    func testASingleWorkspaceHoldingEverythingIsNotGrouped() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("b", minutesAgo: 2)],
            workspaces: [Workspace(id: "w1", path: "/code/one", sessionIds: ["a", "b"])]
        )
        XCTAssertFalse(board.grouped)
        XCTAssertEqual(board.groups.map(\.id), ["w1"])
    }

    /// Workspaces that exist but hold nothing this machine can show are the same
    /// as no workspaces at all.
    func testWorkspacesThatResolveToNothingDegradeToFlat() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["ghost"]),
                Workspace(id: "w2", path: "/code/two", sessionIds: []),
            ]
        )
        XCTAssertFalse(board.grouped)
        XCTAssertEqual(board.groups.map(\.id), [SessionGroup.ungroupedId])
    }

    func testNoSessionsMeansNoSections() {
        let board = SessionBoard(sessions: [], workspaces: [Workspace(id: "w1", path: "/code/one", sessionIds: ["a"])])
        XCTAssertTrue(board.groups.isEmpty)
        XCTAssertFalse(board.grouped)
    }

    // MARK: - Whatever was filed away

    /// `session.list` keeps answering with archived conversations — the machine
    /// treats hiding them as this end's job — so this filter is the only thing
    /// standing between the archive button and a row that comes straight back.
    func testArchivedConversationsAreNotDrawn() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("filed", minutesAgo: 2)],
            workspaces: [Workspace(id: "w1", path: "/code/one", sessionIds: ["a", "filed"])],
            archived: ["filed"]
        )
        XCTAssertEqual(board.groups.flatMap { $0.sessions.map(\.id) }, ["a"])
    }

    /// Deliberate, and the one place this could be argued the other way: the
    /// machine's rule is that an archived conversation leaves every grouping
    /// surface, and lifting one back out because a tool is waiting would put a
    /// row on screen that somebody just made go away.
    func testArchivingBeatsWaiting() {
        let board = SessionBoard(
            sessions: [session("a", minutesAgo: 1), session("filed", minutesAgo: 2)],
            workspaces: [],
            waitingOn: ["filed"],
            archived: ["filed"]
        )
        XCTAssertTrue(board.waiting.isEmpty)
        XCTAssertEqual(board.groups.flatMap { $0.sessions.map(\.id) }, ["a"])
    }

    func testASectionEmptiedByArchivingDisappears() {
        let board = SessionBoard(
            sessions: [session("only", minutesAgo: 1), session("b", minutesAgo: 2)],
            workspaces: [
                Workspace(id: "w1", path: "/code/one", sessionIds: ["only"]),
                Workspace(id: "w2", path: "/code/two", sessionIds: ["b"]),
            ],
            archived: ["only"]
        )
        XCTAssertEqual(board.groups.map(\.id), ["w2"])
        XCTAssertFalse(board.grouped)
    }
}

// MARK: - Remembering the folds

@MainActor
final class GroupFoldsTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A throwaway suite per test, so nothing leaks between them or into the
        // simulator's real preferences.
        suiteName = "reins.folds.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAnUntouchedSectionTakesTheSuggestion() {
        let folds = GroupFolds(machineId: "m1", defaults: suite)
        XCTAssertTrue(folds.isOpen("w1", unlessRemembered: true))
        XCTAssertFalse(folds.isOpen("w2", unlessRemembered: false))
    }

    func testAChoiceSurvivesRelaunch() {
        GroupFolds(machineId: "m1", defaults: suite).set("w1", open: false)

        let afterRelaunch = GroupFolds(machineId: "m1", defaults: suite)
        XCTAssertFalse(afterRelaunch.isOpen("w1", unlessRemembered: true), "the suggestion must not overrule what someone did")
    }

    /// The case two-state storage would get wrong: a section opened by hand that
    /// the default would close, because something else became more recent.
    func testAnOpenedSectionStaysOpenWhenTheDefaultMovesAway() {
        let folds = GroupFolds(machineId: "m1", defaults: suite)
        folds.set("w2", open: true)
        XCTAssertTrue(folds.isOpen("w2", unlessRemembered: false))

        let afterRelaunch = GroupFolds(machineId: "m1", defaults: suite)
        XCTAssertTrue(afterRelaunch.isOpen("w2", unlessRemembered: false))
    }

    /// Workspace ids belong to one machine. Two Macs paired with the same phone
    /// share nothing but the phone.
    func testMachinesDoNotShareFolds() {
        GroupFolds(machineId: "m1", defaults: suite).set("w1", open: false)
        let other = GroupFolds(machineId: "m2", defaults: suite)
        XCTAssertTrue(other.isOpen("w1", unlessRemembered: true))
    }

    func testTheLeftoversAreRememberedLikeAnyOtherSection() {
        let folds = GroupFolds(machineId: "m1", defaults: suite)
        folds.set(SessionGroup.ungroupedId, open: false)
        XCTAssertFalse(GroupFolds(machineId: "m1", defaults: suite).isOpen(SessionGroup.ungroupedId, unlessRemembered: true))
    }
}
