import XCTest
@testable import Mangrove

final class OutlineTests: XCTestCase {

    func testParsesLevelsInSourceOrder() {
        let text = """
        \\begin{document}
        \\section{Opening}
        First paragraph here.
        \\subsection{Details}
        More detail.
        \\section*{Closing}
        Last words.
        \\end{document}
        """
        let items = DocumentOutline.parse(text: text)
        XCTAssertEqual(items.map(\.level), [.section, .subsection, .section])
        XCTAssertEqual(items.map(\.title), ["Opening", "Details", "Closing"])
        XCTAssertEqual(items.map(\.line), [2, 4, 6])
    }

    func testIgnoresCommentedHeadings() {
        let text = """
        % \\section{Not real}
        \\section{Real}
        Body.
        """
        let items = DocumentOutline.parse(text: text)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Real")
    }

    func testHandlesNestedBracesInTitle() {
        let text = "\\section{The \\emph{big} idea}\nBody"
        let items = DocumentOutline.parse(text: text)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "The big idea")
    }

    func testWordCountStopsAtSameLevelAndEndDocument() {
        let text = """
        \\section{One}
        alpha beta
        \\section{Two}
        gamma
        \\end{document}
        """
        let items = DocumentOutline.parse(text: text)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].wordCount, 2)
        XCTAssertEqual(items[1].wordCount, 1)
    }
}

final class CompletionTests: XCTestCase {

    func testBibliographyKeysSkipMetadata() {
        let bib = """
        @article{smith2020,
          title = {A paper}
        }
        @book{doe_1999:thing,
          title = {A book}
        }
        @string{jan = "January"}
        @comment{ @article{ghost, title={No}} }
        """
        let keys = CompletionIndex.bibliographyKeys(in: bib)
        XCTAssertTrue(keys.contains("smith2020"))
        XCTAssertTrue(keys.contains("doe_1999:thing"))
        XCTAssertFalse(keys.contains("jan"))
        XCTAssertFalse(keys.contains("ghost"))
    }

    func testLabelsAreUniqueAndOrdered() {
        let text = "\\label{sec:intro}\n\\label{fig:one}\n\\label{sec:intro}"
        XCTAssertEqual(CompletionIndex.labels(in: text), ["sec:intro", "fig:one"])
    }

    func testCitationContextAfterComma() {
        let request = CompletionIndex.request(before: "See \\cite{smith2020, do")
        XCTAssertEqual(request?.kind, .citation)
        XCTAssertEqual(request?.partial, "do")
    }

    func testReferenceContext() {
        let request = CompletionIndex.request(before: "As shown in \\autoref{fig:")
        XCTAssertEqual(request?.kind, .reference)
        XCTAssertEqual(request?.partial, "fig:")
    }

    func testOrdinaryBraceIsNotARequest() {
        XCTAssertNil(CompletionIndex.request(before: "\\begin{doc"))
        XCTAssertNil(CompletionIndex.request(before: "text {"))
    }
}

final class ProjectSearchTests: XCTestCase {

    private let files = [
        SearchableFile(path: "main.tex", text: "Alpha beta\nGamma alpha\n"),
        SearchableFile(path: "notes.txt", text: "nothing here\n"),
    ]

    func testFindsAllMatchesWithLineNumbers() {
        let hits = ProjectSearch.hits(
            query: "alpha", files: files, options: ProjectSearchOptions()
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.line), [1, 2])
        XCTAssertEqual(hits.map(\.path), ["main.tex", "main.tex"])
    }

    func testCaseSensitiveAndWholeWord() {
        var options = ProjectSearchOptions()
        options.caseSensitive = true
        let sensitive = ProjectSearch.hits(query: "ALPHA", files: files, options: options)
        XCTAssertEqual(sensitive.count, 0)

        options = ProjectSearchOptions()
        options.wholeWord = true
        let whole = ProjectSearch.hits(query: "Alph", files: files, options: options)
        XCTAssertEqual(whole.count, 0)
    }

    func testReplacesEveryMatch() {
        let replaced = ProjectSearch.replacing(
            in: files[0].text, query: "alpha", with: "omega",
            options: ProjectSearchOptions()
        )
        XCTAssertEqual(replaced, "omega beta\nGamma omega\n")
    }

    func testReplacementEscapesDollarSigns() {
        let replaced = ProjectSearch.replacing(
            in: "cost", query: "cost", with: "$5", options: ProjectSearchOptions()
        )
        XCTAssertEqual(replaced, "$5")
    }
}

final class HistoryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangroveHistoryTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRecordsNewRevisionsOnly() {
        let history = ProjectHistory(root: root)
        XCTAssertNotNil(history.record(path: "main.tex", text: "one", savedAt: Date()))
        XCTAssertNil(history.record(path: "main.tex", text: "one", savedAt: Date()))
        XCTAssertNotNil(history.record(path: "main.tex", text: "two", savedAt: Date()))
        XCTAssertEqual(history.snapshots(for: "main.tex").count, 2)
    }

    func testContentsAndPruning() {
        let history = ProjectHistory(root: root, maxPerFile: 2)
        for text in ["one", "two", "three"] {
            history.record(path: "main.tex", text: text, savedAt: Date())
        }
        let stored = history.snapshots(for: "main.tex")
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.compactMap { history.contents(of: $0) }.sorted(), ["three", "two"])
    }

    func testDiffReportsAddedRemovedAndSameLines() {
        let rows = LineDiff.rows(old: "a\nb\nc", new: "a\nB\nc\nd")
        XCTAssertNotNil(rows)
        XCTAssertEqual(rows?.filter { $0.kind == .same }.count, 2)
        XCTAssertEqual(rows?.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(rows?.filter { $0.kind == .added }.count, 2)
    }

    func testDiffRefusesPathologicalInput() {
        let old = Array(repeating: "a", count: 900).joined(separator: "\n")
        let new = Array(repeating: "b", count: 900).joined(separator: "\n")
        XCTAssertNil(LineDiff.rows(old: old, new: new))
    }
}

final class SyncTeXParsingTests: XCTestCase {

    func testParseEdit() {
        let output = """
        This is SyncTeX command line utility, version 1.5
        SyncTeX result begin
        Output:/tmp/main.pdf
        Input:/tmp/main.tex
        Line:42
        Column:7
        Offset:0
        Context:
        SyncTeX result end
        """
        let location = SyncTeX.parseEdit(output)
        XCTAssertEqual(location?.file, "/tmp/main.tex")
        XCTAssertEqual(location?.line, 42)
        XCTAssertEqual(location?.column, 7)
    }

    func testParseView() {
        let output = """
        SyncTeX result begin
        Output:/tmp/main.pdf
        Page:3
        x:120.500000
        y:88.250000
        SyncTeX result end
        """
        let target = SyncTeX.parseView(output)
        XCTAssertEqual(target?.page, 3)
        XCTAssertEqual(target?.x, 120.5)
        XCTAssertEqual(target?.y, 88.25)
    }

    func testMalformedOutputIsRejected() {
        XCTAssertNil(SyncTeX.parseEdit("nothing useful"))
        XCTAssertNil(SyncTeX.parseView("Page:0\nx:1\ny:2"))
    }
}

final class ProjectEntityTreeTests: XCTestCase {

    private let payload: [String: Any] = [
        "project": [
            "_id": "project1",
            "rootFolder": [[
                "_id": "root",
                "name": "rootFolder",
                "docs": [["_id": "doc-main", "name": "main.tex"]],
                "fileRefs": [["_id": "file-fig", "name": "figure.png"]],
                "folders": [[
                    "_id": "folder-ch",
                    "name": "chapters",
                    "docs": [["_id": "doc-two", "name": "two.tex"]],
                    "fileRefs": [],
                    "folders": [],
                ]],
            ]],
        ],
    ]

    func testBuildsPathsAndIds() {
        let tree = ProjectEntityTreeParser.tree(fromJoinPayload: payload)
        XCTAssertEqual(tree?.rootFolderId, "root")
        XCTAssertEqual(tree?.entity(at: "main.tex")?.id, "doc-main")
        XCTAssertEqual(tree?.entity(at: "main.tex")?.kind, .doc)
        XCTAssertEqual(tree?.entity(at: "figure.png")?.kind, .file)
        XCTAssertEqual(tree?.entity(at: "chapters/two.tex")?.parentFolderId, "folder-ch")
        XCTAssertEqual(tree?.folder(at: "chapters")?.id, "folder-ch")
    }

    func testFoldersAreDestinationsAndIdentified() {
        let tree = ProjectEntityTreeParser.tree(fromJoinPayload: payload)
        XCTAssertEqual(tree?.destinations.map(\.path), ["", "chapters"])
        XCTAssertTrue(ProjectEntityTree.isInside("chapters/two.tex", folder: "chapters"))
        XCTAssertFalse(ProjectEntityTree.isInside("chapters2/two.tex", folder: "chapters"))
        XCTAssertTrue(ProjectEntityTree.isInside("anything", folder: ""))
    }

    func testMissingRootFolderIsRejected() {
        XCTAssertNil(ProjectEntityTreeParser.tree(fromJoinPayload: ["project": [String: Any]()]))
        XCTAssertNil(ProjectEntityTreeParser.tree(fromJoinPayload: [:]))
    }
}

final class PresenceTests: XCTestCase {

    func testCollaboratorUpdate() {
        let update = RealtimePresence.update(
            name: "clientTracking.clientUpdated",
            payload: ["user_id": "u1", "first_name": "Ada", "last_name": "Lovelace"]
        )
        XCTAssertEqual(update?.id, "u1")
        XCTAssertEqual(update?.name, "Ada Lovelace")
        XCTAssertEqual(update?.online, true)
    }

    func testDisconnect() {
        let update = RealtimePresence.update(
            name: "clientTracking.clientDisconnected",
            payload: ["id": "client-1"]
        )
        XCTAssertEqual(update?.online, false)
        XCTAssertEqual(update?.name, "Collaborator")
    }

    func testUnrelatedEventIsIgnored() {
        XCTAssertNil(RealtimePresence.update(name: "reciveNewDoc", payload: ["id": "x"]))
    }

    func testInitials() {
        XCTAssertEqual(RealtimePresence.initials(for: "Ada Lovelace"), "AL")
        XCTAssertEqual(RealtimePresence.initials(for: "ada@example.com"), "A")
        XCTAssertEqual(RealtimePresence.initials(for: ""), "?")
    }
}
