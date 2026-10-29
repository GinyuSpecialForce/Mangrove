import XCTest
@testable import Mangrove

/// These cover the two parts of the client that cannot be exercised through the
/// UI without real Overleaf credentials: turning Overleaf's `Set-Cookie` traffic
/// into a coherent session, and turning the project archive into a working copy.
final class SessionTests: XCTestCase {

    func testCookieHeaderIsBuiltFromMatchingCookies() {
        let session = StoredSession(
            baseURL: "https://www.overleaf.com",
            cookies: [
                CookieRecord(name: "overleaf_session2", value: "abc", domain: ".overleaf.com"),
                CookieRecord(name: "_csrf", value: "def", domain: "www.overleaf.com"),
                CookieRecord(name: "unrelated", value: "ghi", domain: "example.com")
            ],
            savedAt: Date()
        )
        let header = session.cookieHeader()
        XCTAssertTrue(header.contains("overleaf_session2=abc"))
        XCTAssertTrue(header.contains("_csrf=def"))
        XCTAssertFalse(header.contains("unrelated"), "cookies for other hosts must not be sent")
    }

    func testExpiredCookiesAreNotSent() {
        let session = StoredSession(
            baseURL: "https://www.overleaf.com",
            cookies: [
                CookieRecord(
                    name: "overleaf_session2",
                    value: "old",
                    domain: ".overleaf.com",
                    expiresAt: Date().addingTimeInterval(-3600)
                )
            ],
            savedAt: Date()
        )
        XCTAssertTrue(session.cookieHeader().isEmpty)
    }

    func testRawCookieHeaderImport() throws {
        let raw = "overleaf_session2=s%3Aabc%3Adef; _csrf=token123; GCLB=xyz"
        let session = try StoredSession.fromRawCookieHeader(raw, baseURL: "https://www.overleaf.com")
        XCTAssertEqual(session.cookies.count, 3)
        XCTAssertEqual(session.host, "www.overleaf.com")
        // The percent-encoded value must survive untouched.
        XCTAssertEqual(session.cookies.first?.value, "s%3Aabc%3Adef")
    }

    func testRawCookieHeaderWithoutSessionIsRejected() {
        XCTAssertThrowsError(
            try StoredSession.fromRawCookieHeader("GCLB=xyz; foo=bar", baseURL: "https://www.overleaf.com")
        )
    }

    /// Exercises the real request path against overleaf.com: fetching a CSRF
    /// token must return a token *and* capture the session cookie Overleaf
    /// refreshes in the same response — that cookie carries the CSRF secret, so
    /// dropping it makes every later write fail with 403.
    func testCsrfTokenFetchCapturesRefreshedSessionCookie() async throws {
        let anonymous = StoredSession(baseURL: "https://www.overleaf.com", cookies: [], savedAt: Date())
        let client = OverleafClient(session: anonymous)

        let updated = expectation(description: "session update reported")
        client.onSessionUpdate = { _ in updated.fulfill() }

        let token = try await client.csrfToken()
        XCTAssertFalse(token.isEmpty, "expected a CSRF token")

        wait(for: [updated], timeout: 5)
        XCTAssertTrue(
            client.session.cookies.contains { $0.name.contains("session") },
            "the session cookie returned with the token must be kept"
        )
    }

    /// Overleaf answers failed requests with an HTML error page; the banner must
    /// show its title, never the markup.
    func testHTMLErrorBodiesAreReducedToTheirTitle() {
        let html = """
        <!DOCTYPE html><html lang="en"><head><title>Page Not Found - Overleaf, Online LaTeX Editor</title></head>
        <body><h1>Page Not Found</h1></body></html>
        """
        XCTAssertEqual(
            OverleafClient.describe(body: Data(html.utf8)),
            "Page Not Found - Overleaf, Online LaTeX Editor"
        )
        XCTAssertEqual(OverleafClient.describe(body: Data("plain problem".utf8)), "plain problem")
        XCTAssertEqual(OverleafClient.describe(body: Data()), "")
        XCTAssertEqual(OverleafClient.describe(body: Data("<html><body>no title</body></html>".utf8)), "")
    }

    func testUnauthenticatedSessionIsReportedAsInvalid() async throws {
        let anonymous = StoredSession(baseURL: "https://www.overleaf.com", cookies: [], savedAt: Date())
        let client = OverleafClient(session: anonymous)
        let valid = await client.verifySession()
        XCTAssertFalse(valid, "an empty cookie set must not verify as signed in")
    }
}

final class WorkspaceTests: XCTestCase {
    private var projectId = ""
    private var workspace: ProjectWorkspace!

    override func setUpWithError() throws {
        projectId = "test-\(UUID().uuidString)"
        workspace = ProjectWorkspace(projectId: projectId)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
        try? FileManager.default.removeItem(at: workspace.baseRoot)
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(
            at: support.appendingPathComponent("Mangrove/State/\(projectId).json")
        )
    }

    /// Overleaf hands back a real zip, so unpack and walk the tree exactly as the
    /// app does when a project is opened.
    func testProjectArchiveBecomesAWorkingCopy() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangrove-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("sections"), withIntermediateDirectories: true
        )
        try "\\documentclass{article}".write(
            to: staging.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8
        )
        try "\\section{Intro}".write(
            to: staging.appendingPathComponent("sections/intro.tex"), atomically: true, encoding: .utf8
        )
        try "\\bibliographystyle{plain}".write(
            to: staging.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-r", zipURL.path, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "could not create the fixture archive")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        try workspace.replaceContents(withZip: try Data(contentsOf: zipURL))

        let tree = workspace.fileTree()
        let paths = flatten(tree).map(\.path)
        XCTAssertTrue(paths.contains("main.tex"), "got \(paths)")
        XCTAssertTrue(paths.contains("sections/intro.tex"), "got \(paths)")
        XCTAssertTrue(paths.contains("refs.bib"), "got \(paths)")

        // Directories must actually be directories in the tree.
        XCTAssertEqual(tree.first { $0.name == "sections" }?.isDirectory, true)

        XCTAssertEqual(try workspace.readText("main.tex"), "\\documentclass{article}")
        XCTAssertEqual(try workspace.readText("sections/intro.tex"), "\\section{Intro}")

        // Folders sort first (as in Finder), and among files LaTeX sources come
        // before supporting assets so the main document is easy to find.
        XCTAssertEqual(tree.first?.name, "sections")
        XCTAssertEqual(tree.first { !$0.isDirectory }?.name, "main.tex")
        XCTAssertEqual(tree.map(\.name), ["sections", "main.tex", "refs.bib"])

        // Editing marks the file as pending, saving clears it.
        try workspace.writeText("main.tex", text: "changed")
        XCTAssertEqual(workspace.modifiedPaths, ["main.tex"])
        workspace.markClean("main.tex")
        XCTAssertFalse(workspace.hasLocalChanges)
        XCTAssertEqual(try workspace.readText("main.tex"), "changed")
    }

    func testMovingAFolderCarriesPendingEditsAndBases() throws {
        try workspace.writeText("main.tex", text: "first")
        workspace.saveBase("main.tex", data: Data("base".utf8))
        try workspace.moveItem(from: "main.tex", to: "chapters/main.tex")

        XCTAssertEqual(try workspace.readText("chapters/main.tex"), "first")
        XCTAssertEqual(workspace.modifiedPaths, ["chapters/main.tex"])
        XCTAssertEqual(workspace.baseData("chapters/main.tex"), Data("base".utf8))
        XCTAssertNil(workspace.baseData("main.tex"))

        try workspace.createDirectory("figures")
        XCTAssertTrue(workspace.fileExists("figures"))

        try workspace.removeItem(at: "chapters")
        XCTAssertFalse(workspace.fileExists("chapters"))
        XCTAssertTrue(workspace.modifiedPaths.isEmpty)
        XCTAssertNil(workspace.baseData("chapters/main.tex"))
    }

    func testTreeGroupsNestedFolders() {
        let files = [
            FileNode(path: "main.tex", name: "main.tex", isDirectory: false, children: []),
            FileNode(path: "a/b/deep.tex", name: "deep.tex", isDirectory: false, children: []),
            FileNode(path: "a/top.tex", name: "top.tex", isDirectory: false, children: [])
        ]
        let tree = WorkspaceTreeBuilder.build(from: files)
        let folder = tree.first { $0.name == "a" }
        XCTAssertEqual(folder?.isDirectory, true)
        XCTAssertEqual(folder?.children.map(\.name).sorted(), ["b", "top.tex"])
        XCTAssertEqual(folder?.children.first { $0.name == "b" }?.children.first?.path, "a/b/deep.tex")
    }

    /// The PDF fallback URL has to be reconstructed from an output URL.
    func testBuildIdIsReadFromOutputURLs() {
        let url = "/project/abc123/build/6710f0d1c2e4b80001a2b3c4/output/output.pdf?clsiserverid=x"
        XCTAssertEqual(CompileResult.buildId(from: url), "6710f0d1c2e4b80001a2b3c4")
        XCTAssertNil(CompileResult.buildId(from: "/project/abc123/output/output.pdf"))
    }

    private func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { node in [node] + flatten(node.children) }
    }
}

@MainActor
final class SignInDestinationTests: XCTestCase {

    /// The sign-in web view must land on the login form; overleaf.com's root is
    /// the marketing sign-up page.
    func testSignInURLPointsAtTheLoginPage() {
        let state = AppState()
        XCTAssertEqual(state.signInURL.absoluteString, "https://www.overleaf.com/login")
    }

    /// The session's base URL stays the instance root so relative API paths
    /// resolve correctly after the /login navigation is stripped away.
    func testSessionBaseURLStaysAtTheInstanceRoot() {
        let state = AppState()
        XCTAssertEqual(state.instanceURL.absoluteString, "https://www.overleaf.com")
        let resolved = URL(string: "/user/projects", relativeTo: state.instanceURL)?.absoluteURL
        XCTAssertEqual(resolved?.absoluteString, "https://www.overleaf.com/user/projects")
    }
}
