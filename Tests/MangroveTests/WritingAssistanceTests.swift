import Foundation
import XCTest
@testable import Mangrove

final class LaTeXAssistanceTests: XCTestCase {

    func testEnvironmentCloseAfterBeginLine() {
        let text = "\\begin{itemize}"
        let close = LaTeXAssistance.environmentClose(
            in: text, caret: (text as NSString).length
        )
        XCTAssertEqual(close?.environment, "itemize")
        XCTAssertEqual(close?.insertion, "\n\n\\end{itemize}")
    }

    func testEnvironmentCloseKeepsIndentation() {
        let text = "  \\begin{enumerate}"
        let close = LaTeXAssistance.environmentClose(
            in: text, caret: (text as NSString).length
        )
        XCTAssertEqual(close?.insertion, "\n\n  \\end{enumerate}")
    }

    func testEnvironmentCloseAcceptsOptionalArguments() {
        let text = "\\begin{figure}[htbp]"
        let close = LaTeXAssistance.environmentClose(
            in: text, caret: (text as NSString).length
        )
        XCTAssertEqual(close?.environment, "figure")
    }

    func testEnvironmentCloseDoesNotDuplicateAnExistingEnd() {
        let text = "\\begin{itemize}\n  \\item x\n\\end{itemize}"
        let caret = ("\\begin{itemize}" as NSString).length
        XCTAssertNil(LaTeXAssistance.environmentClose(in: text, caret: caret))
    }

    func testEnvironmentCloseRequiresAnEmptyRestOfLine() {
        let text = "\\begin{itemize} % list"
        let caret = ("\\begin{itemize}" as NSString).length
        XCTAssertNil(LaTeXAssistance.environmentClose(in: text, caret: caret))
    }

    func testEnvironmentCloseRequiresTheLineToStartWithBegin() {
        let text = "Intro \\begin{itemize}"
        XCTAssertNil(LaTeXAssistance.environmentClose(
            in: text, caret: (text as NSString).length
        ))
    }

    func testEnvironmentCloseRejectsIncompleteBegin() {
        let text = "\\begin{"
        XCTAssertNil(LaTeXAssistance.environmentClose(
            in: text, caret: (text as NSString).length
        ))
    }

    func testSnippetExpandsBackslashTrigger() {
        let before = "x + \\frac"
        guard let expansion = LaTeXAssistance.snippet(beforeCaret: before) else {
            return XCTFail("expected a snippet")
        }
        XCTAssertEqual(expansion.range, NSRange(location: 4, length: 5))
        XCTAssertEqual(expansion.insertion, "\\frac{}{}")
        XCTAssertEqual(expansion.caretOffset, 6)
    }

    func testSnippetExpandsWithoutBackslash() {
        guard let expansion = LaTeXAssistance.snippet(beforeCaret: "fig") else {
            return XCTFail("expected a snippet")
        }
        XCTAssertEqual(expansion.range, NSRange(location: 0, length: 3))
        XCTAssertTrue(expansion.insertion.hasPrefix("\\begin{figure}"))
        XCTAssertTrue(expansion.insertion.contains("\\end{figure}"))
    }

    func testSnippetReportsCaretInsideFigure() {
        guard let expansion = LaTeXAssistance.snippet(beforeCaret: "\\fig") else {
            return XCTFail("expected a snippet")
        }
        // The caret lands on the closing brace of the includegraphics path.
        let insertion = expansion.insertion as NSString
        XCTAssertEqual(insertion.character(at: expansion.caretOffset), 125)
        XCTAssertTrue(insertion.substring(to: expansion.caretOffset).hasSuffix("{"))
    }

    func testSnippetNeedsAWholeTrigger() {
        XCTAssertNil(LaTeXAssistance.snippet(beforeCaret: "myfig"))
        XCTAssertNil(LaTeXAssistance.snippet(beforeCaret: "fraction"))
    }

    func testSnippetIgnoresComments() {
        XCTAssertNil(LaTeXAssistance.snippet(beforeCaret: "% \\fig"))
    }

    func testSnippetUnknownWord() {
        XCTAssertNil(LaTeXAssistance.snippet(beforeCaret: "hello"))
    }
}

final class LaTeXLintTests: XCTestCase {

    func testUnmatchedClosingBrace() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "alpha } beta", file: "main.tex"
        )
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.message, "Unmatched closing brace.")
        XCTAssertEqual(diagnostics.first?.line, 1)
    }

    func testUnclosedBraceReportsOpeningLine() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "line one\n\\textbf{hello", file: "main.tex"
        )
        XCTAssertEqual(diagnostics.first?.message, "Unclosed brace opened here.")
        XCTAssertEqual(diagnostics.first?.line, 2)
    }

    func testEscapedBracesAreLiteral() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "\\{ literal \\}", file: "main.tex"
        )
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testCommentsAreIgnored() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "% } { \\begin{itemize}\nText.", file: "main.tex"
        )
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testBalancedEnvironmentsAreClean() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "\\begin{itemize}\n  \\item x\n\\end{itemize}",
            file: "main.tex"
        )
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testUnclosedEnvironment() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "\\begin{itemize}\n  \\item x", file: "main.tex"
        )
        XCTAssertEqual(diagnostics.first?.message, "\\begin{itemize} is never closed.")
        XCTAssertEqual(diagnostics.first?.severity, .error)
    }

    func testMismatchedEnvironment() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "\\begin{itemize}\n\\begin{enumerate}\n\\end{itemize}",
            file: "main.tex"
        )
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("does not match"))
    }

    func testDuplicateLabelIsAWarning() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "\\label{intro}\n\\label{intro}", file: "main.tex"
        )
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertTrue(diagnostics.first?.message.contains("Duplicate label") == true)
        XCTAssertEqual(diagnostics.first?.line, 2)
    }

    func testUnknownReferenceWarns() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "See \\ref{missing}.",
            file: "main.tex",
            knownReferences: ["intro"]
        )
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(diagnostics.first?.message, "Reference “missing” has no matching \\label.")
    }

    func testKnownReferenceIsClean() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "See \\ref{intro}.",
            file: "main.tex",
            knownReferences: ["intro"]
        )
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testReferenceChecksAreSkippedWithoutABibliographyIndex() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "See \\ref{missing}.",
            file: "main.tex",
            knownReferences: []
        )
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testUnknownCitationWarns() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "As shown in \\cite{smith2020}.",
            file: "main.tex",
            knownCitations: ["jones2021"]
        )
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(
            diagnostics.first?.message,
            "Citation “smith2020” is not in a .bib file."
        )
    }

    func testMultipleCitationKeys() {
        let diagnostics = LaTeXLint.builtInDiagnostics(
            text: "\\cite{known, missing}",
            file: "main.tex",
            knownCitations: ["known"]
        )
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("missing"))
    }

    func testChkTeXOutputWithColumn() {
        let output = "main.tex:12:3: Warning 1: Command terminated with space.\n"
        let diagnostics = LaTeXLint.parseChkTeX(output, file: "paper.tex")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(diagnostics.first?.line, 12)
        XCTAssertEqual(diagnostics.first?.message, "Command terminated with space.")
        XCTAssertEqual(diagnostics.first?.file, "paper.tex")
    }

    func testChkTeXOutputWithoutColumn() {
        let output = "main.tex:7: Error 2: Something went wrong.\n"
        let diagnostics = LaTeXLint.parseChkTeX(output, file: "paper.tex")
        XCTAssertEqual(diagnostics.first?.severity, .error)
        XCTAssertEqual(diagnostics.first?.line, 7)
    }

    func testChkTeXStripsColourCodes() {
        let output = "\u{1B}[31mmain.tex:3:1: Warning 8: Wrong dash.\u{1B}[0m\n"
        let diagnostics = LaTeXLint.parseChkTeX(output, file: "paper.tex")
        XCTAssertEqual(diagnostics.first?.message, "Wrong dash.")
    }

    func testChkTeXExecutableSearch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("chktex")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )

        XCTAssertEqual(
            LaTeXLint.chktexExecutable(in: [directory])?.path,
            executable.path
        )
        XCTAssertNil(LaTeXLint.chktexExecutable(in: []))
    }
}

final class IdleCompilePolicyTests: XCTestCase {

    private func allows(
        enabled: Bool = true,
        hasProject: Bool = true,
        needsCompile: Bool = true,
        isCompiling: Bool = false,
        isOpeningProject: Bool = false,
        hasPendingMerges: Bool = false,
        pageVisible: Bool = true,
        isOnline: Bool = true,
        localTeXAvailable: Bool = false
    ) -> Bool {
        IdleCompilePolicy.shouldCompile(
            enabled: enabled,
            hasProject: hasProject,
            needsCompile: needsCompile,
            isCompiling: isCompiling,
            isOpeningProject: isOpeningProject,
            hasPendingMerges: hasPendingMerges,
            pageVisible: pageVisible,
            isOnline: isOnline,
            localTeXAvailable: localTeXAvailable
        )
    }

    func testCompilesOnlineWithPendingEdits() {
        XCTAssertTrue(allows())
    }

    func testSkipsWhenDisabled() {
        XCTAssertFalse(allows(enabled: false))
    }

    func testSkipsWithoutEdits() {
        XCTAssertFalse(allows(needsCompile: false))
    }

    func testSkipsWhileCompilingOrOpening() {
        XCTAssertFalse(allows(isCompiling: true))
        XCTAssertFalse(allows(isOpeningProject: true))
    }

    func testSkipsWhileMergeIsPending() {
        XCTAssertFalse(allows(hasPendingMerges: true))
    }

    func testSkipsWhenPageIsHidden() {
        XCTAssertFalse(allows(pageVisible: false))
    }

    func testSkipsOfflineWithoutLocalTeX() {
        XCTAssertFalse(allows(isOnline: false, localTeXAvailable: false))
    }

    func testCompilesOfflineWithLocalTeX() {
        XCTAssertTrue(allows(isOnline: false, localTeXAvailable: true))
    }
}
