import AppKit
import SwiftUI
import XCTest
@testable import Mangrove

/// The editor colours source by scanning it, so the scan has to agree with how
/// LaTeX actually reads: comments own the rest of their line, escaped characters
/// are not syntax, and math ends where it says it does.
final class HighlightingTests: XCTestCase {

    private func spans(_ text: String) -> [(LaTeXHighlighter.Kind, String)] {
        let source = text as NSString
        return LaTeXHighlighter.spans(in: text).map {
            ($0.kind, source.substring(with: $0.range))
        }
    }

    func testCommentRunsToEndOfLineOnly() {
        let text = "% note here\ntext after"
        let result = spans(text)
        XCTAssertEqual(result.first?.0, .comment)
        XCTAssertEqual(result.first?.1, "% note here")
        XCTAssertEqual(result.count, 1, "the next line must not stay coloured as a comment")
    }

    func testEscapedPercentIsNotAComment() {
        let text = #"50\% of it"#
        let kinds = spans(text).map(\.0)
        XCTAssertFalse(kinds.contains(.comment))
        XCTAssertEqual(spans(text).first?.1, #"\%"#)
    }

    func testSectioningCommandsAreHeadings() {
        let result = spans(#"\section{Method}"#)
        XCTAssertEqual(result.first?.0, .heading)
        XCTAssertEqual(result.first?.1, #"\section"#)
    }

    func testOrdinaryCommandsAreCommands() {
        XCTAssertEqual(spans(#"\textbf{hi}"#).first?.0, .command)
        XCTAssertEqual(spans(#"\textbf{hi}"#).first?.1, #"\textbf"#)
    }

    func testMathEnvironmentOpensAndCloses() {
        let text = """
        \\begin{equation}
        a = b
        \\end{equation}
        plain words
        """
        let result = spans(text)
        let math = result.filter { $0.0 == .math }.map(\.1)
        XCTAssertTrue(math.contains { $0.contains("a = b") })
        XCTAssertFalse(
            math.contains { $0.contains("plain words") },
            "text after \\end{equation} must not stay math"
        )
    }

    func testInlineDollarMath() {
        let result = spans(#"so $x + y$ holds"#)
        let math = result.filter { $0.0 == .math }.map(\.1).joined()
        XCTAssertEqual(math, "$x + y$")
    }

    func testDocumentIsAnEnvironmentButNotMath() {
        let text = "\\begin{document}\nhi\n\\end{document}"
        let result = spans(text)
        XCTAssertEqual(result.first?.0, .environment)
        XCTAssertFalse(result.contains { $0.0 == .math })
    }

    func testSpansNeverOverlap() {
        let text = #"""
        \documentclass{article}
        % a comment with \commands and $math$
        \begin{document}
        \section{Intro}
        Some $\alpha + \beta$ and \cite{key}.
        50\% done
        \begin{align}
        x &= y \\ z
        \end{align}
        \end{document}
        """#
        let ranges = LaTeXHighlighter.spans(in: text).map(\.range).sorted {
            $0.location < $1.location
        }
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(
                earlier.location + earlier.length, later.location,
                "spans must not overlap"
            )
        }
    }

    // MARK: Editor wiring

    /// Typing has to reach the app state, or nothing would ever be dirty.
    @MainActor
    func testTypingUpdatesTheBoundText() {
        var captured = ""
        let coordinator = SourceEditor.Coordinator(
            text: Binding(get: { captured }, set: { captured = $0 })
        )
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.attach(textView)
        textView.string = "hello"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(captured, "hello")
    }

    /// Body text must keep its ink in dark mode. Leaving the colour attribute off
    /// makes TextKit draw black regardless of appearance, which is unreadable on a
    /// dark page — the bug this guards.
    @MainActor
    func testBodyTextIsLightOnADarkPage() throws {
        let color = try bodyTextColour(in: .darkAqua)
        XCTAssertGreaterThan(luminance(color), 0.5, "dark mode body text must be light")
    }

    @MainActor
    func testBodyTextIsDarkOnALightPage() throws {
        let color = try bodyTextColour(in: .aqua)
        XCTAssertLessThan(luminance(color), 0.5, "light mode body text must be dark")
    }

    /// Syntax keeps its own colour, distinct from the body ink, in both modes.
    @MainActor
    func testCommentsDifferFromBodyInk() throws {
        var captured = ""
        let coordinator = SourceEditor.Coordinator(
            text: Binding(get: { captured }, set: { captured = $0 })
        )
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.attach(textView)
        textView.string = "% note\nplain"
        coordinator.highlight()

        let storage = try XCTUnwrap(textView.textStorage)
        let comment = try XCTUnwrap(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let body = try XCTUnwrap(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(comment, body)
    }

    /// Builds the editor inside a window with the given appearance and returns the
    /// colour applied to ordinary text.
    @MainActor
    private func bodyTextColour(in appearance: NSAppearance.Name) throws -> NSColor {
        var captured = ""
        let coordinator = SourceEditor.Coordinator(
            text: Binding(get: { captured }, set: { captured = $0 })
        )
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = textView

        coordinator.attach(textView)
        textView.string = "plain text\nsecond line"
        coordinator.highlight()

        let storage = try XCTUnwrap(textView.textStorage)
        return try XCTUnwrap(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    }

    // MARK: Palette

    /// Source colours are resolved per appearance, so this guards the dark-mode
    /// case: light ink on a dark page, dark ink on a light one, and syntax that
    /// stays distinguishable in both.
    func testPaletteAdaptsToAppearance() throws {
        let light = SourcePalette.resolve(for: try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = SourcePalette.resolve(for: try XCTUnwrap(NSAppearance(named: .darkAqua)))

        XCTAssertLessThan(luminance(light.ink), 0.4, "body text must be dark on a light page")
        XCTAssertGreaterThan(luminance(dark.ink), 0.6, "body text must be light on a dark page")

        for pair in [
            (light.command, dark.command),
            (light.environment, dark.environment),
            (light.math, dark.math),
            (light.comment, dark.comment),
        ] {
            XCTAssertNotEqual(pair.0, pair.1, "syntax colours must be tuned per appearance")
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * Double(rgb.redComponent)
            + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }

    func testUnfinishedInputStillHighlights() {
        // A half-typed environment is what you see while typing; it must not throw
        // or swallow the rest of the file.
        let text = "\\begin{equa"
        let result = spans(text)
        XCTAssertEqual(result.first?.0, .command)
    }
}
