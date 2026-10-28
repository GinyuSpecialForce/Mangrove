import AppKit
import XCTest
@testable import Mangrove

@MainActor
final class VisualDocumentTests: XCTestCase {

    private let sample = #"""
    \documentclass[11pt]{article}
    \usepackage{amsmath}
    \usepackage{hyperref}
    \title{Visual \LaTeX{} Test}
    \author{A. Author}
    \date{2026}

    \begin{document}
    \maketitle
    \section{Introduction}\label{sec:intro}

    The method begins with a direction that decreases the objective and
    uses \textbf{bold text}, \emph{emphasis}, and $x^2 + y^2$ inline math.
    See \cite{smith2020} for details. % a comment

    \subsection{Contributions}
    \begin{itemize}
      \item First contribution with \textit{style}.
      \item Second contribution.
    \end{itemize}

    \begin{equation}
      \dot{x} = f(x) + g(x)u
    \end{equation}

    \begin{figure}
      \includegraphics[width=0.5\textwidth]{figures/path.pdf}
      \caption{A path through the safe set.}
    \end{figure}

    \bibliography{refs}
    \end{document}
    """#

    func testDocumentStructure() {
        let document = VisualDocumentParser.parse(sample)

        XCTAssertEqual(document.title, "Visual LaTeX Test")
        XCTAssertEqual(document.author, "A. Author")
        XCTAssertEqual(document.date, "2026")
        XCTAssertEqual(document.packageCount, 2)

        XCTAssertEqual(document.blocks.count, 8, "got \(document.blocks.map(\.kind))")
        guard case let .heading(level) = document.blocks[0].kind else {
            return XCTFail("expected the first block to be a heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(document.blocks[1].kind, .paragraph)
        guard case let .heading(subLevel) = document.blocks[2].kind else {
            return XCTFail("expected a subsection")
        }
        XCTAssertEqual(subLevel, 2)

        guard case let .listItem(firstMarker) = document.blocks[3].kind,
              case let .listItem(secondMarker) = document.blocks[4].kind else {
            return XCTFail("expected two list items")
        }
        XCTAssertEqual(firstMarker, .bullet)
        XCTAssertEqual(secondMarker, .bullet)
        XCTAssertEqual(document.blocks[5].kind, .math)
        XCTAssertEqual(document.blocks[5].detail, "equation")
        XCTAssertEqual(document.blocks[6].kind, .figure)
        XCTAssertEqual(document.blocks[6].caption, "A path through the safe set.")
        XCTAssertEqual(document.blocks[6].path, "figures/path.pdf")
        XCTAssertEqual(document.blocks[7].kind, .command)
        XCTAssertTrue(document.blocks[7].source.contains("\\bibliography{refs}"))
    }

    func testEveryBlockRangeSlicesBackToItsSource() {
        let document = VisualDocumentParser.parse(sample)
        let source = sample as NSString
        for block in document.blocks {
            XCTAssertEqual(
                source.substring(with: block.range), block.source,
                "block \(block.id) at \(block.range) does not match its source"
            )
            if let editable = block.editable {
                XCTAssertEqual(source.substring(with: block.editableRange), editable)
            }
        }
    }

    func testParagraphKeepsInlineMarkupAndComments() throws {
        let document = VisualDocumentParser.parse(sample)
        let paragraph = try XCTUnwrap(document.blocks.first { $0.kind == .paragraph })
        XCTAssertTrue(paragraph.editable?.contains("\\textbf{bold text}") == true)
        XCTAssertTrue(paragraph.editable?.contains("$x^2 + y^2$") == true)
        XCTAssertTrue(paragraph.editable?.contains("% a comment") == true)
    }

    func testEditingRewritesOnlyTheParagraphAndKeepsLaterRangesValid() throws {
        let model = VisualDocumentModel()
        model.load(sample)
        let paragraphIndex = try XCTUnwrap(model.document.blocks.firstIndex { $0.kind == .paragraph })
        let mathIndex = try XCTUnwrap(model.document.blocks.firstIndex { $0.kind == .math })

        var emitted: String?
        model.setTextHandler { emitted = $0 }
        model.beginEditing(paragraphIndex)

        let replacement = "A completely new paragraph."
        model.update(paragraphIndex, with: replacement)
        let updated = try XCTUnwrap(emitted)

        XCTAssertTrue(updated.contains(replacement))
        XCTAssertFalse(updated.contains("The method begins"))
        XCTAssertTrue(updated.contains("\\section{Introduction}"))
        XCTAssertTrue(updated.contains("\\begin{equation}"))

        // The model has not re-parsed yet: the active text view must survive.
        XCTAssertEqual(model.document.blocks[paragraphIndex].kind, .paragraph)
        XCTAssertTrue(model.isEditing)

        // Later block ranges moved with the edit and still point at the right text.
        let mathRange = model.currentRange(for: mathIndex)
        XCTAssertTrue(
            (updated as NSString).substring(with: mathRange).hasPrefix("\\begin{equation}"),
            "math range no longer points at the equation"
        )

        model.commitNow()
        XCTAssertFalse(model.isEditing)
        let reparsed = try XCTUnwrap(model.document.blocks.first { $0.id == paragraphIndex })
        XCTAssertEqual(reparsed.editable, replacement)
    }

    func testHeadingRangeExcludesTheCommandAndOptionalShortTitle() {
        let text = #"""
        \section[Short]{A much \textbf{longer} title}
        Body.
        """#
        let document = VisualDocumentParser.parse(text)
        guard case .heading = document.blocks[0].kind else {
            return XCTFail("expected a heading")
        }
        XCTAssertEqual(document.blocks[0].editable, #"A much \textbf{longer} title"#)
        XCTAssertTrue(document.blocks[0].source.hasPrefix("\\section[Short]{"))

        let model = VisualDocumentModel()
        model.load(text)
        model.beginEditing(0)
        model.update(0, with: "New title")
        XCTAssertTrue(model.source.hasPrefix("\\section[Short]{New title}"))
    }

    func testNumberedListUsesItsItems() {
        let text = #"""
        \begin{enumerate}
          \item One.
          \item Two.
        \end{enumerate}
        """#
        let document = VisualDocumentParser.parse(text)
        XCTAssertEqual(document.blocks.count, 2)
        guard case let .listItem(first) = document.blocks[0].kind,
              case let .listItem(second) = document.blocks[1].kind else {
            return XCTFail("expected numbered items")
        }
        XCTAssertEqual(first, .number(1))
        XCTAssertEqual(second, .number(2))
        XCTAssertEqual(document.blocks[0].editable, "One.")
        XCTAssertEqual(document.blocks[1].editable, "Two.")
    }

    func testMultiParagraphListItemStaysInSource() {
        let text = #"""
        \begin{itemize}
          \item First paragraph.

          Second paragraph in the same item.
          \item A normal item.
        \end{itemize}
        """#
        let document = VisualDocumentParser.parse(text)
        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].kind, .raw)
        XCTAssertNil(document.blocks[0].editable)
        XCTAssertEqual(document.blocks[1].kind, .listItem(.bullet))
        XCTAssertEqual(document.blocks[1].editable, "A normal item.")
    }

    func testAuthorSeparatorBecomesProse() {
        XCTAssertEqual(
            InlineLaTeX.plainText(in: #"A. Author \and B. Author"#),
            "A. Author, B. Author"
        )
    }

    func testTitleNotesAreNotPartOfTheTitleText() {
        XCTAssertEqual(
            InlineLaTeX.plainText(in: #"A paper\thanks{Funded by a grant.}"#),
            "A paper"
        )
    }

    func testUnmodelledParagraphIsReadOnly() {
        let text = #"Text \begin{minipage}{3cm}inside\end{minipage} after."#
        let document = VisualDocumentParser.parse(text)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].kind, .raw)
        XCTAssertNil(document.blocks[0].editable)
    }

    func testEmptyDocumentParsesToNothing() {
        XCTAssertEqual(VisualDocumentParser.parse(""), .empty)
        let bodyOnly = VisualDocumentParser.parse("Just text.")
        XCTAssertEqual(bodyOnly.blocks.count, 1)
        XCTAssertEqual(bodyOnly.blocks[0].editable, "Just text.")
    }

    // MARK: Inline engine

    func testInlineRunsCarryFormattingAndAtomicTokens() {
        let input = #"The method uses \textbf{bold} and \emph{italic} and $x^2$ plus \cite{key}."#
        let runs = InlineLaTeX.runs(in: input)

        XCTAssertTrue(runs.contains { $0.text == "bold" && $0.style.contains(.bold) })
        XCTAssertTrue(runs.contains { $0.text == "italic" && $0.style.contains(.italic) })
        XCTAssertEqual(runs.compactMap { $0.token?.kind }, [.math, .citation])
        XCTAssertTrue(runs.contains { $0.token?.source == "$x^2$" })
        XCTAssertTrue(runs.contains { $0.token?.source == "\\cite{key}" })
    }

    func testInlineRoundTripPreservesSemanticsAndTokens() {
        let input = #"The method uses \textbf{bold} and \emph{italic} and $x^2$ plus \cite{key}."#
        let output = serialize(InlineLaTeX.runs(in: input))
        XCTAssertEqual(
            output,
            #"The method uses \textbf{bold} and \textit{italic} and $x^2$ plus \cite{key}."#
        )
    }

    func testSpecialCharactersAreEscapedAndUnescaped() {
        let input = #"50\% of \& and \_ plus \{x\}"#
        let runs = InlineLaTeX.runs(in: input)
        XCTAssertEqual(runs.map(\.text).joined(), "50% of & and _ plus {x}")
        XCTAssertEqual(serialize(runs), #"50\% of \& and \_ plus \{x\}"#)
    }

    func testTypedSpecialCharactersAreEscapedOnSave() {
        let font = bodyFont()
        let attribute = InlineLaTeX.attributed(
            runs: [InlineRun(text: "100% & $5_1 #3", style: [], token: nil)],
            baseFont: font,
            paragraphStyle: NSParagraphStyle(),
            palette: palette()
        )
        XCTAssertEqual(
            InlineLaTeX.latex(from: attribute, baseFont: font),
            ##"100\% \& \$5\_1 \#3"##
        )
    }

    func testBoldRunSerializesToTextbf() {
        let font = bodyFont()
        let attribute = InlineLaTeX.attributed(
            runs: [InlineRun(text: "important", style: .bold, token: nil)],
            baseFont: font,
            paragraphStyle: NSParagraphStyle(),
            palette: palette()
        )
        XCTAssertEqual(InlineLaTeX.latex(from: attribute, baseFont: font), #"\textbf{important}"#)
    }

    func testPlainTextDropsMarkupAndComments() {
        let text = #"A \textbf{very} good paper \cite{smith2020}. % note"#
        XCTAssertEqual(InlineLaTeX.plainText(in: text), "A very good paper [smith2020].")
    }

    /// A chip is drawn with its own padding, so a citation ending a sentence
    /// must not leave the `"[key] ."` gap the source never has.
    func testChipTucksAgainstFollowingPunctuation() {
        let font = bodyFont()

        func chipWidth(_ source: String) -> CGFloat {
            let attribute = InlineLaTeX.attributed(
                runs: InlineLaTeX.runs(in: source),
                baseFont: font,
                paragraphStyle: NSParagraphStyle(),
                palette: palette()
            )
            var width: CGFloat = 0
            attribute.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: attribute.length)
            ) { value, _, _ in
                if let attachment = value as? NSTextAttachment {
                    width = attachment.image?.size.width ?? 0
                }
            }
            return width
        }

        let tucked = chipWidth(#"As shown \cite{smith2020}."#)
        let loose = chipWidth(#"As shown \cite{smith2020} here."#)
        XCTAssertEqual(tucked + 4, loose, accuracy: 0.5)
    }

    func testMathChipIsAtomic() {
        let runs = InlineLaTeX.runs(in: "Before $a+b$ after")
        let math = runs.first { $0.token?.kind == .math }
        XCTAssertEqual(math?.token?.source, "$a+b$")
        XCTAssertEqual(math?.token?.display, "a+b")
    }

    // MARK: Helpers

    private func serialize(_ runs: [InlineRun]) -> String {
        let font = bodyFont()
        let attributed = InlineLaTeX.attributed(
            runs: runs,
            baseFont: font,
            paragraphStyle: NSParagraphStyle(),
            palette: palette()
        )
        return InlineLaTeX.latex(from: attributed, baseFont: font)
    }

    private func bodyFont() -> NSFont {
        NSFont(name: "Charter", size: 14) ?? NSFont.systemFont(ofSize: 14)
    }

    private func palette() -> VisualPalette {
        VisualPalette.resolve(for: NSAppearance(named: .aqua)!)
    }
}
