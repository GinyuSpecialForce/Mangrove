import XCTest
@testable import Mangrove

final class BuildDiagnosticsTests: XCTestCase {

    func testTeXErrorUsesEchoedLineAndFile() {
        let log = """
        This is pdfTeX, Version 3.141592653
        (./main.tex
        LaTeX2e <2022-11-01>
        ! Undefined control sequence.
        l.42 \\badcommand
        ! Emergency stop.
        """
        let diagnostics = BuildLogParser.diagnostics(log: log, defaultFile: "main.tex")

        XCTAssertEqual(diagnostics.count, 1, "got \(diagnostics.map(\.message))")
        let error = diagnostics[0]
        XCTAssertEqual(error.severity, .error)
        XCTAssertEqual(error.message, "Undefined control sequence.")
        XCTAssertEqual(error.file, "main.tex")
        XCTAssertEqual(error.line, 42)
        XCTAssertEqual(error.detail, "\\badcommand")
    }

    func testFileLineErrorsCarryTheirFileAndLine() {
        let log = """
        ./sections/method.tex:17: LaTeX Error: \\begin{equation} on input line 12 ended by \\end{document}.
        """
        let diagnostics = BuildLogParser.diagnostics(
            log: log,
            defaultFile: "main.tex",
            knownFiles: ["main.tex", "sections/method.tex"]
        )

        XCTAssertEqual(diagnostics.count, 1)
        let error = diagnostics[0]
        XCTAssertEqual(error.severity, .error)
        XCTAssertEqual(error.file, "sections/method.tex")
        XCTAssertEqual(error.line, 17)
        XCTAssertTrue(error.message.contains("ended by"))
    }

    func testWarningsKeepTheInputLineEvenWhenTheMessageWraps() {
        let log = """
        Package hyperref Warning: Token not allowed in a PDF string
        (pdfTeX) on input line 88.
        LaTeX Warning: Citation `smith2020' on page 1 undefined on input line 42.
        """
        let diagnostics = BuildLogParser.diagnostics(log: log, defaultFile: "main.tex")

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics.map(\.severity), [.warning, .warning])
        XCTAssertEqual(diagnostics[0].line, 88)
        XCTAssertEqual(diagnostics[1].line, 42)
        XCTAssertTrue(diagnostics[1].message.contains("Citation"))
    }

    func testOverfullBoxesAndFatalSummariesAreNotListed() {
        let log = """
        Overfull \\hbox (12.0pt too wide) in paragraph at lines 4--6
        ! ==> Fatal error occurred, no output PDF file produced!
        LaTeX Warning: There were undefined references.
        """
        let diagnostics = BuildLogParser.diagnostics(log: log, defaultFile: "main.tex")

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].message, "There were undefined references.")
    }

    func testRepeatedErrorsAreReportedOnce() {
        let log = """
        ./main.tex:9: Undefined control sequence.
        ./main.tex:9: Undefined control sequence.
        ./main.tex:9: Undefined control sequence.
        """
        let diagnostics = BuildLogParser.diagnostics(
            log: log, defaultFile: "main.tex", knownFiles: ["main.tex"]
        )
        XCTAssertEqual(diagnostics.count, 1)
    }

    func testValidationProblemsBecomeDiagnostics() {
        let validation: [String: Any] = [
            "main.tex": [
                ["message": "Misplaced alignment tab character &", "row": 12, "level": "error"],
                ["message": "Unused label", "row": 30, "level": "warning"],
            ]
        ]
        let diagnostics = BuildLogParser.diagnostics(
            log: "", defaultFile: "main.tex",
            knownFiles: ["main.tex"], validation: validation
        )

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertEqual(diagnostics[0].line, 12)
        XCTAssertEqual(diagnostics[1].severity, .warning)
        XCTAssertEqual(diagnostics[1].line, 30)
    }

    func testAbsoluteLogPathsResolveToProjectFiles() {
        let log = """
        /Users/someone/Library/Application Support/Mangrove/Projects/abc/main.tex:5: Missing $ inserted.
        """
        let diagnostics = BuildLogParser.diagnostics(
            log: log, defaultFile: "main.tex", knownFiles: ["main.tex", "sections/intro.tex"]
        )

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].file, "main.tex")
        XCTAssertEqual(diagnostics[0].line, 5)
    }

    func testOrderingPutsErrorsBeforeWarnings() {
        let items = [
            BuildDiagnostic(severity: .warning, message: "w"),
            BuildDiagnostic(severity: .error, message: "e1"),
            BuildDiagnostic(severity: .error, message: "e2"),
        ]
        XCTAssertEqual(items.orderedForDisplay().map(\.message), ["e1", "e2", "w"])
        XCTAssertEqual(items.errorCount, 2)
        XCTAssertEqual(items.warningCount, 1)
    }
}

@MainActor
final class SourceLineTests: XCTestCase {

    func testLineRangeSelectsTheWholeLine() {
        let text = "first\nsecond\nthird"
        let range = AppState.range(ofLine: 2, in: text)
        XCTAssertEqual((text as NSString).substring(with: range), "second")
    }

    func testLinePastTheEndClampsToTheLastLine() {
        let text = "only line"
        let range = AppState.range(ofLine: 99, in: text)
        XCTAssertEqual((text as NSString).substring(with: range), "only line")
    }

    func testEmptyDocumentHasAnEmptyRange() {
        let range = AppState.range(ofLine: 1, in: "")
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }
}
