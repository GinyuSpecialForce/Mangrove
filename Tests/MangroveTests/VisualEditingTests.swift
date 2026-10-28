import AppKit
import XCTest
@testable import Mangrove

/// Exercises the bridge between the visual text view and the document model:
/// what the user types (or formats) must reach the source with the rest of the
/// file untouched.
@MainActor
final class VisualEditingTests: XCTestCase {

    func testTypingInAParagraphRewritesOnlyThatParagraph() throws {
        let source = """
        \\section{Intro}
        First paragraph.

        Second paragraph.
        """
        let (model, coordinator, textView) = try makeEditor(for: source, blockKind: .paragraph)
        let paragraph = try XCTUnwrap(model.document.blocks.first { $0.kind == .paragraph })
        XCTAssertEqual(textView.string, paragraph.editable)

        replaceAll(in: textView, with: "Rewritten first paragraph.")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertTrue(model.source.contains("Rewritten first paragraph."))
        XCTAssertTrue(model.source.contains("Second paragraph."))
        XCTAssertTrue(model.source.contains("\\section{Intro}"))
        XCTAssertFalse(model.source.contains("First paragraph."))
    }

    func testBoldAppliedInTheTextViewBecomesTextbf() throws {
        let source = "A paragraph."
        let (model, coordinator, textView) = try makeEditor(for: source, blockKind: .paragraph)

        let font = NSFontManager.shared.convert(
            VisualType.serif(14), toHaveTrait: .boldFontMask
        )
        textView.textStorage?.addAttribute(
            .font, value: font, range: NSRange(location: 2, length: 9)
        )
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertTrue(model.source.contains(#"A \textbf{paragraph}."#), model.source)
    }

    func testMathAttachmentSurvivesSerialization() throws {
        let source = "Before and after."
        let (model, coordinator, textView) = try makeEditor(for: source, blockKind: .paragraph)

        let token = InlineToken(kind: .math, source: "$x^2$", display: "x^2")
        let insertion = InlineLaTeX.attributedToken(
            token,
            baseFont: VisualType.serif(14),
            palette: VisualPalette.resolve(for: NSAppearance(named: .aqua)!)
        )
        textView.textStorage?.append(insertion)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertTrue(model.source.contains("$x^2$"), model.source)
        XCTAssertTrue(model.source.contains("Before and after."))
    }

    func testHeadingEditKeepsItsCommandAndLabel() throws {
        let source = """
        \\section{Old title}\\label{sec:old}
        Body.
        """
        let (model, coordinator, textView) = try makeEditor(for: source, blockKind: .heading(level: 1))
        replaceAll(in: textView, with: "New title")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertTrue(model.source.contains("\\section{New title}\\label{sec:old}"), model.source)
        XCTAssertTrue(model.source.contains("Body."))
    }

    // MARK: - Helpers

    private func makeEditor(
        for source: String,
        blockKind expected: VisualBlock.Kind
    ) throws -> (VisualDocumentModel, VisualTextBlock.Coordinator, VisualBlockTextView) {
        let model = VisualDocumentModel()
        model.load(source)
        let block = try XCTUnwrap(
            model.document.blocks.first { block in
                if case .paragraph = block.kind, case .paragraph = expected { return true }
                if case .heading = block.kind, case .heading = expected { return true }
                return false
            }
        )

        let session = VisualEditorSession()
        let coordinator = VisualTextBlock.Coordinator(
            model: model, session: session, block: block
        )
        let textView = VisualBlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        coordinator.attach(textView)
        coordinator.apply(
            block: block,
            baseFont: expected == .paragraph ? VisualType.serif(14) : VisualType.heading(1),
            paragraphStyle: VisualType.paragraphStyle(lineSpacing: 5)
        )
        return (model, coordinator, textView)
    }

    private func replaceAll(in textView: NSTextView, with text: String) {
        let length = (textView.string as NSString).length
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: length), with: text
        )
    }
}
