import XCTest
@testable import Mangrove

/// The merge engine is what stands between a collaborator's saved edits and a
/// silent overwrite, so it is tested independently of the network.
final class LineMergeTests: XCTestCase {

    func testOnlyOneSideChangedTakesThatSide() {
        let base = "a\nb\nc\n"
        let theirs = "a\nB\nc\n"
        XCTAssertEqual(LineMerge.merge(mine: base, base: base, theirs: theirs), .clean(theirs))

        let mine = "A\nb\nc\n"
        XCTAssertEqual(LineMerge.merge(mine: mine, base: base, theirs: base), .clean(mine))
    }

    func testChangesToDifferentRegionsCombine() {
        let base = """
        \\section{Intro}
        Text here.

        \\section{Method}
        Old method.

        \\section{Results}
        Results.
        """
        let mine = base.replacingOccurrences(of: "Text here.", with: "Text here, expanded locally.")
        let theirs = base.replacingOccurrences(of: "Results.", with: "Results, updated remotely.")

        guard case let .clean(merged) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("changes to separate regions must merge cleanly")
        }
        XCTAssertTrue(merged.contains("expanded locally"))
        XCTAssertTrue(merged.contains("updated remotely"))
        XCTAssertFalse(merged.contains("<<"))
    }

    func testSameRegionChangedDifferentlyConflicts() {
        let base = "one\ntwo\nthree\n"
        let mine = "one\nTWO MINE\nthree\n"
        let theirs = "one\nTWO THEIRS\nthree\n"

        guard case let .conflicted(text, conflicts) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("overlapping edits must conflict")
        }
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].mine, "TWO MINE\n")
        XCTAssertEqual(conflicts[0].theirs, "TWO THEIRS\n")
        XCTAssertEqual(conflicts[0].base, "two\n")
        // The default text keeps the local side, so nothing is lost if dismissed.
        XCTAssertEqual(text, mine)
    }

    func testIdenticalChangesApplyOnce() {
        let base = "a\nb\n"
        let changed = "a\nB\n"
        XCTAssertEqual(LineMerge.merge(mine: changed, base: base, theirs: changed), .clean(changed))
    }

    func testInsertionsAtDifferentPlacesBothSurvive() {
        let base = "a\nb\nc\n"
        let mine = "a\nmine\na2\nb\nc\n"
        let theirs = "a\nb\nc\ntheirs\n"

        guard case let .clean(merged) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("separate insertions must merge")
        }
        XCTAssertTrue(merged.contains("mine\na2"))
        XCTAssertTrue(merged.hasSuffix("theirs\n"))
    }

    func testDeletionAndEditSeparatedByCommonLineCombine() {
        let base = "keep\ndelete me\nmiddle\nchange me\n"
        let mine = "keep\nmiddle\nchange me\n"
        let theirs = "keep\ndelete me\nmiddle\nchanged\n"

        guard case let .clean(merged) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("a deletion and a separate edit must merge")
        }
        XCTAssertEqual(merged, "keep\nmiddle\nchanged\n")
    }

    /// Adjacent edits have no common line to synchronise on, which is exactly
    /// how `diff3` and `git merge-file` behave: ask rather than guess.
    func testAdjacentEditsConflict() {
        let base = "keep\ndelete me\nchange me\n"
        let mine = "keep\nchange me\n"
        let theirs = "keep\ndelete me\nchanged\n"
        guard case .conflicted = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("adjacent changes must not be merged silently")
        }
    }

    func testMissingFinalNewlineIsPreserved() {
        let base = "a\nb\nc\nd\n"
        let mine = "a\nb\nc\nd"
        let theirs = "A\nb\nc\nd\n"
        guard case let .clean(merged) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("expected a clean merge")
        }
        XCTAssertEqual(merged, "A\nb\nc\nd")
    }

    func testResolutionPicksPerHunk() {
        let base = "a\nb\nc\nd\n"
        let mine = "a\nMINE\nc\nMINE2\n"
        let theirs = "a\nTHEIRS\nc\nTHEIRS2\n"

        guard case let .conflicted(_, conflicts) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("expected two conflicts")
        }
        XCTAssertEqual(conflicts.count, 2)

        let resolved = LineMerge.resolve(
            mine: mine, base: base, theirs: theirs, choosingTheirs: [true, false]
        )
        XCTAssertEqual(resolved, "a\nTHEIRS\nc\nMINE2\n")
    }

    func testEmptyBaseMergingTwoAdditionsConflicts() {
        guard case .conflicted = LineMerge.merge(mine: "mine\n", base: "", theirs: "theirs\n") else {
            return XCTFail("two independently created files with different text must conflict")
        }
    }

    func testUnchangedLargeFileIsFastAndStable() {
        let text = (0..<1500).map { "line \($0)\n" }.joined()
        XCTAssertEqual(LineMerge.merge(mine: text, base: text, theirs: text), .clean(text))
    }
}

final class SyncPlannerTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testUnchangedFileNeedsNothing() {
        XCTAssertEqual(
            SyncPlanner.action(local: data("x"), base: data("x"), remote: data("x"), isText: true),
            .unchanged
        )
    }

    func testOnlyLocalChangedUploads() {
        XCTAssertEqual(
            SyncPlanner.action(local: data("mine"), base: data("base"), remote: data("base"), isText: true),
            .uploadLocal
        )
    }

    func testOnlyRemoteChangedAdopts() {
        XCTAssertEqual(
            SyncPlanner.action(local: data("base"), base: data("base"), remote: data("theirs"), isText: true),
            .adoptRemote
        )
    }

    func testNewLocalFileUploads() {
        XCTAssertEqual(
            SyncPlanner.action(local: data("new"), base: nil, remote: nil, isText: true),
            .uploadLocal
        )
    }

    func testNewRemoteFileIsAdopted() {
        XCTAssertEqual(
            SyncPlanner.action(local: nil, base: nil, remote: data("new"), isText: true),
            .adoptRemote
        )
    }

    func testBothChangedTextMerges() {
        XCTAssertEqual(
            SyncPlanner.action(local: data("mine\n"), base: data("base\n"), remote: data("theirs\n"), isText: true),
            .merge(mine: "mine\n", base: "base\n", theirs: "theirs\n")
        )
    }

    func testBothChangedBinaryConflicts() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        XCTAssertEqual(
            SyncPlanner.action(local: png, base: Data([0x00]), remote: Data([0x01]), isText: false),
            .conflict
        )
    }

    func testUndecodableTextConflictsInsteadOfCrashing() {
        let broken = Data([0xFF, 0xFE, 0x00])
        XCTAssertEqual(
            SyncPlanner.action(local: broken, base: data("b"), remote: data("t"), isText: true),
            .conflict
        )
    }
}

final class ConnectivityTests: XCTestCase {

    func testNetworkFailuresAreOffline() {
        XCTAssertTrue(Connectivity.isOffline(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Connectivity.isOffline(URLError(.cannotConnectToHost)))
        XCTAssertTrue(Connectivity.isOffline(URLError(.timedOut)))
        XCTAssertTrue(Connectivity.isOffline(MangroveError.offline))
    }

    func testServerRejectionIsNotOffline() {
        XCTAssertFalse(Connectivity.isOffline(MangroveError.http(status: 500, body: "")))
        XCTAssertFalse(Connectivity.isOffline(MangroveError.notAuthenticated))
    }

    func testWrappedNetworkFailureIsStillOffline() {
        let wrapped = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
        )
        XCTAssertTrue(Connectivity.isOffline(wrapped))
    }
}

final class WorkspaceStateTests: XCTestCase {
    private var projectId = ""
    private var workspace: ProjectWorkspace!

    override func setUpWithError() throws {
        projectId = "state-\(UUID().uuidString)"
        workspace = ProjectWorkspace(projectId: projectId)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
        try? FileManager.default.removeItem(at: workspace.baseRoot)
        let state = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mangrove/State/\(projectId).json")
        try? FileManager.default.removeItem(at: state)
    }

    func testPendingEditsSurviveRelaunch() throws {
        try workspace.writeText("main.tex", text: "draft")
        XCTAssertEqual(workspace.modifiedPaths, ["main.tex"])

        let reopened = ProjectWorkspace(projectId: projectId)
        XCTAssertEqual(reopened.modifiedPaths, ["main.tex"], "unsaved work must survive a restart")

        reopened.markClean("main.tex")
        XCTAssertTrue(ProjectWorkspace(projectId: projectId).modifiedPaths.isEmpty)
    }

    func testQueuedCompileAndOpenFileSurviveRelaunch() {
        workspace.pendingCompile = true
        workspace.rootDocument = "paper.tex"
        workspace.lastOpenPath = "sections/intro.tex"
        workspace.recordRemoteDigest("abc123")

        let reopened = ProjectWorkspace(projectId: projectId)
        XCTAssertTrue(reopened.pendingCompile)
        XCTAssertEqual(reopened.rootDocument, "paper.tex")
        XCTAssertEqual(reopened.lastOpenPath, "sections/intro.tex")
        XCTAssertEqual(reopened.lastRemoteDigest, "abc123")

        reopened.pendingCompile = false
        XCTAssertFalse(ProjectWorkspace(projectId: projectId).pendingCompile)
    }

    func testMergeBasesAreStoredWithoutTouchingTheWorkingCopy() throws {
        try workspace.writeText("main.tex", text: "mine")
        workspace.saveBase("main.tex", data: Data("remote".utf8))

        XCTAssertEqual(workspace.baseData("main.tex"), Data("remote".utf8))
        XCTAssertEqual(try workspace.readText("main.tex"), "mine")
        XCTAssertEqual(workspace.modifiedPaths, ["main.tex"])

        workspace.saveBase("main.tex", data: nil)
        XCTAssertNil(workspace.baseData("main.tex"))
    }

    func testWritingRemoteContentClearsThePendingFlag() throws {
        try workspace.writeText("main.tex", text: "mine")
        try workspace.writeRemote("main.tex", data: Data("theirs".utf8))
        XCTAssertEqual(try workspace.readText("main.tex"), "theirs")
        XCTAssertEqual(workspace.modifiedPaths, [])
    }
}
