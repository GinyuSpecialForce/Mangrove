import XCTest
@testable import Mangrove

/// The local compiler cannot be exercised without TeX installed, so these tests
/// drive the same code path with a stand-in executable that behaves like
/// `latexmk`: reads `-outdir=`, writes `main.pdf`, and exits.
final class LocalBuildTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangrove-latex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("project"), withIntermediateDirectories: true
        )
        try "\\documentclass{article}".write(
            to: directory.appendingPathComponent("project/main.tex"), atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDetectionPrefersLatexmkAndIgnoresMissingTools() throws {
        let bin = directory.appendingPathComponent("bin")
        try makeScript("pdflatex", in: bin)
        XCTAssertEqual(LocalLaTeX.detect(in: [bin])?.tool, .pdflatex)

        try makeScript("latexmk", in: bin)
        XCTAssertEqual(LocalLaTeX.detect(in: [bin])?.tool, .latexmk)
        XCTAssertNil(LocalLaTeX.detect(in: [directory.appendingPathComponent("nowhere")]))
    }

    func testBuildRunsTheToolAndReturnsItsPDFAndLog() async throws {
        let bin = directory.appendingPathComponent("bin")
        try makeScript("latexmk", in: bin, body: """
        out=""
        for arg in "$@"; do
          case "$arg" in -outdir=*) out="${arg#-outdir=}";; esac
        done
        printf '%%PDF-1.4\\n%%fake\\n' > "$out/main.pdf"
        echo "This is the fake LaTeX log."
        exit 0
        """)

        let tool = try XCTUnwrap(LocalLaTeX.detect(in: [bin]))
        let output = try await tool.build(
            projectRoot: directory.appendingPathComponent("project"),
            mainFile: "main.tex",
            outputDirectory: directory.appendingPathComponent("build")
        )

        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.document, "main.tex")
        XCTAssertEqual(String(decoding: output.pdf, as: UTF8.self), "%PDF-1.4\n%fake\n")
        XCTAssertTrue(output.log.contains("fake LaTeX log"), "got: \(output.log)")
    }

    func testBuildReportsFailureWhenNoPDFAppears() async throws {
        let bin = directory.appendingPathComponent("bin")
        try makeScript("latexmk", in: bin, body: """
        echo "! LaTeX Error: something went wrong."
        exit 12
        """)

        let tool = try XCTUnwrap(LocalLaTeX.detect(in: [bin]))
        do {
            _ = try await tool.build(
                projectRoot: directory.appendingPathComponent("project"),
                mainFile: "main.tex",
                outputDirectory: directory.appendingPathComponent("build")
            )
            XCTFail("a build with no PDF must throw")
        } catch {
            XCTAssertTrue(
                (error as? LocalizedError)?.errorDescription?.contains("something went wrong") == true,
                "the log tail must be included: \(error)"
            )
        }
    }

    func testMissingDocumentIsReportedClearly() async throws {
        let bin = directory.appendingPathComponent("bin")
        try makeScript("latexmk", in: bin)
        let tool = try XCTUnwrap(LocalLaTeX.detect(in: [bin]))

        do {
            _ = try await tool.build(
                projectRoot: directory.appendingPathComponent("project"),
                mainFile: "nothere.tex",
                outputDirectory: directory.appendingPathComponent("build")
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nothere.tex"))
        }
    }

    private func makeScript(_ name: String, in directory: URL, body: String = "exit 0") throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
