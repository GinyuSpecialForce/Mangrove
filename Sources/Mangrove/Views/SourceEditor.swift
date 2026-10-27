import AppKit
import SwiftUI

// MARK: - LaTeX highlighting

/// Source spans that the editor colours, found without a parser.
///
/// A full LaTeX grammar is not needed to read a paper: what matters at a glance
/// is where the comments are, which words are commands, where math begins, and
/// which lines are section headings. Scanning in one pass keeps that honest for
/// unfinished input — a half-typed environment still colours sensibly.
enum LaTeXHighlighter {
    enum Kind: Equatable {
        case comment
        case command
        case heading
        case environment
        case math
    }

    struct Span: Equatable {
        let kind: Kind
        let range: NSRange
    }

    private static let sectioning: Set<String> = [
        "part", "chapter", "section", "subsection", "subsubsection",
        "paragraph", "subparagraph", "title",
    ]

    /// Environments whose bodies are math from `\begin` to `\end`.
    private static let mathEnvironments: Set<String> = [
        "equation", "align", "alignat", "flalign", "gather", "multline",
        "eqnarray", "split", "cases", "matrix", "pmatrix", "bmatrix",
        "vmatrix", "Vmatrix", "smallmatrix", "displaymath", "math",
    ]

    static func spans(in text: String) -> [Span] {
        let source = text as NSString
        let length = source.length
        var spans: [Span] = []
        var index = 0
        var insideMath = false
        var mathEnvironment: String?

        func append(_ kind: Kind, from start: Int, to end: Int) {
            guard end > start else { return }
            spans.append(Span(kind: kind, range: NSRange(location: start, length: end - start)))
        }

        while index < length {
            let character = source.character(at: index)

            // A comment runs to the end of the line, and wins over everything.
            if character == ascii("%") {
                var end = index
                while end < length, source.character(at: end) != ascii("\n") { end += 1 }
                append(.comment, from: index, to: end)
                index = end
                continue
            }

            if character == ascii("$") {
                var end = index + 1
                if end < length, source.character(at: end) == ascii("$") { end += 1 }
                append(.math, from: index, to: end)
                insideMath.toggle()
                if !insideMath { mathEnvironment = nil }
                index = end
                continue
            }

            if character == ascii("\\") {
                if insideMath {
                    if let close = mathClose(in: source, at: index) {
                        append(.math, from: index, to: close)
                        insideMath = false
                        mathEnvironment = nil
                        index = close
                        continue
                    }
                    if let env = environment(in: source, at: index, length: length) {
                        append(.environment, from: index, to: env.end)
                        if env.word == "end", mathEnvironment == env.base || mathEnvironment == nil {
                            insideMath = false
                            mathEnvironment = nil
                        }
                        index = env.end
                        continue
                    }
                    let end = commandEnd(in: source, at: index, length: length)
                    append(.math, from: index, to: end)
                    index = end
                    continue
                }

                // `\(` and `\[` open inline and display math.
                if index + 1 < length {
                    let next = source.character(at: index + 1)
                    if next == ascii("(") || next == ascii("[") {
                        append(.math, from: index, to: index + 2)
                        insideMath = true
                        index += 2
                        continue
                    }
                }

                if let env = environment(in: source, at: index, length: length) {
                    append(.environment, from: index, to: env.end)
                    if env.word == "begin", mathEnvironments.contains(env.base) {
                        insideMath = true
                        mathEnvironment = env.base
                    }
                    index = env.end
                    continue
                }

                let end = commandEnd(in: source, at: index, length: length)
                let word = commandWord(in: source, at: index, to: end)
                if let word, sectioning.contains(word) {
                    append(.heading, from: index, to: end)
                } else {
                    append(.command, from: index, to: end)
                }
                index = end
                continue
            }

            if insideMath {
                var end = index
                while end < length {
                    let next = source.character(at: end)
                    if next == ascii("$") || next == ascii("\\") || next == ascii("%") { break }
                    end += 1
                }
                if end == index { end = index + 1 }
                append(.math, from: index, to: end)
                index = end
                continue
            }

            index += 1
        }

        return spans
    }

    // MARK: Scanning helpers

    /// `\` followed by letters (or `@`, which LaTeX internals use), otherwise a
    /// two-character escape such as `\%` or `\\`.
    private static func commandEnd(in source: NSString, at index: Int, length: Int) -> Int {
        var end = index + 1
        guard end < length else { return length }
        if isCommandLetter(source.character(at: end)) {
            while end < length, isCommandLetter(source.character(at: end)) { end += 1 }
            return end
        }
        return min(end + 1, length)
    }

    private static func commandWord(in source: NSString, at index: Int, to end: Int) -> String? {
        guard end > index + 1 else { return nil }
        let first = source.character(at: index + 1)
        guard isCommandLetter(first) else { return nil }
        return source.substring(with: NSRange(location: index + 1, length: end - index - 1))
    }

    /// Matches `\begin{name}` / `\end{name}`, returning the whole construct.
    private static func environment(
        in source: NSString, at index: Int, length: Int
    ) -> (word: String, base: String, end: Int)? {
        let end = commandEnd(in: source, at: index, length: length)
        guard let word = commandWord(in: source, at: index, to: end),
              word == "begin" || word == "end" else { return nil }

        var cursor = end
        while cursor < length, source.character(at: cursor) == ascii(" ") { cursor += 1 }
        guard cursor < length, source.character(at: cursor) == ascii("{") else { return nil }

        var close = cursor + 1
        while close < length {
            let character = source.character(at: close)
            if character == ascii("}") { break }
            // A brace or backslash inside the name means this is not an environment.
            if character == ascii("{") || character == ascii("\\") || character == ascii("\n") {
                return nil
            }
            close += 1
        }
        guard close < length, close > cursor + 1 else { return nil }

        let raw = source.substring(with: NSRange(location: cursor + 1, length: close - cursor - 1))
        let base = raw.hasSuffix("*") ? String(raw.dropLast()) : raw
        return (word, base, close + 1)
    }

    /// `\)` and `\]` close math.
    private static func mathClose(in source: NSString, at index: Int) -> Int? {
        guard index + 1 < source.length else { return nil }
        let next = source.character(at: index + 1)
        return (next == ascii(")") || next == ascii("]")) ? index + 2 : nil
    }

    private static func isCommandLetter(_ character: unichar) -> Bool {
        (character >= ascii("a") && character <= ascii("z"))
            || (character >= ascii("A") && character <= ascii("Z"))
            || character == ascii("@")
    }

    private static func ascii(_ character: Character) -> unichar {
        unichar(character.asciiValue ?? 0)
    }
}

// MARK: - Palette

/// Colours for source text, resolved once per appearance so the editor reads
/// correctly in both modes. Green stays out of the code: in this app green means
/// signal (selection, saving, success), never syntax.
struct SourcePalette {
    let ink: NSColor
    let comment: NSColor
    let command: NSColor
    let heading: NSColor
    let environment: NSColor
    let math: NSColor

    static func resolve(for appearance: NSAppearance) -> SourcePalette {
        var palette = SourcePalette(
            ink: .labelColor,
            comment: .secondaryLabelColor,
            command: .labelColor,
            heading: .labelColor,
            environment: .labelColor,
            math: .labelColor
        )
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        appearance.performAsCurrentDrawingAppearance {
            palette = SourcePalette(
                // Resolved concretely: a dynamic colour left in an attributed
                // string resolves against the app's appearance at draw time, not
                // the view's, which can paint the body text the same colour as
                // the page.
                ink: (NSColor.labelColor.usingColorSpace(.sRGB) ?? .textColor),
                comment: resolved(
                    dark ? (0.47, 0.56, 0.49) : (0.42, 0.48, 0.42)
                ),
                command: resolved(
                    dark ? (0.47, 0.68, 0.96) : (0.10, 0.32, 0.62)
                ),
                heading: resolved(
                    dark ? (0.79, 0.86, 0.96) : (0.09, 0.22, 0.44)
                ),
                environment: resolved(
                    dark ? (0.76, 0.61, 0.97) : (0.44, 0.22, 0.60)
                ),
                math: resolved(
                    dark ? (0.95, 0.70, 0.45) : (0.58, 0.28, 0.08)
                )
            )
        }
        return palette
    }

    private static func resolved(_ rgb: (Double, Double, Double)) -> NSColor {
        NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    func color(for kind: LaTeXHighlighter.Kind) -> NSColor {
        switch kind {
        case .comment: return comment
        case .command: return command
        case .heading: return heading
        case .environment: return environment
        case .math: return math
        }
    }
}

// MARK: - Text view

/// `NSTextView` that reports appearance changes, so syntax colours can be
/// re-resolved when the system switches between light and dark.
final class SourceTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// A text view created off-window reports the app's appearance; once it is in a
    /// window it inherits the window's, which may differ. Colour again at that
    /// point so the ink always matches the page behind it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAppearanceChange?()
    }
}

/// The LaTeX source editor: an `NSTextView` with syntax colouring, because
/// SwiftUI's `TextEditor` cannot style source.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String

    static let fontSize: CGFloat = 12.5

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SourceTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        textView.delegate = context.coordinator
        context.coordinator.attach(textView)
        context.coordinator.setText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.attach(textView)
        // Only replace the text when it came from somewhere other than this
        // editor — otherwise every keystroke would reset the insertion point.
        if textView.string != text {
            context.coordinator.setText(text)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private weak var textView: SourceTextView?
        private var highlightScheduled = false
        private var isReplacingText = false

        init(text: Binding<String>) {
            self.text = text
        }

        func attach(_ textView: NSTextView) {
            guard let textView = textView as? SourceTextView, self.textView !== textView else { return }
            self.textView = textView
            textView.onAppearanceChange = { [weak self] in
                self?.textView?.typingAttributes = self?.baseAttributes(ink: self?.inkColor() ?? .labelColor) ?? [:]
                self?.highlight()
            }
            // The view only learns its real appearance once it is in a window, so
            // colour once more after attaching.
            scheduleHighlight()
        }

        func setText(_ newText: String) {
            guard let textView else { return }
            isReplacingText = true
            textView.string = newText
            isReplacingText = false
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if let scrollView = textView.enclosingScrollView {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            highlight()
        }

        func textDidChange(_ notification: Notification) {
            guard !isReplacingText, let textView else { return }
            text.wrappedValue = textView.string
            textView.typingAttributes = baseAttributes(ink: inkColor())
            scheduleHighlight()
        }

        /// Attribute passes are deferred a runloop turn so they never land in the
        /// middle of an edit, and skipped entirely while an input method is
        /// composing.
        private func scheduleHighlight() {
            guard !highlightScheduled else { return }
            highlightScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.highlightScheduled = false
                self?.highlight()
            }
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            guard !textView.hasMarkedText() else { return }

            let palette = SourcePalette.resolve(for: textView.effectiveAppearance)
            let base = baseAttributes(ink: palette.ink)
            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(base, range: full)
            for span in LaTeXHighlighter.spans(in: storage.string) {
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: palette.color(for: span.kind)
                ]
                if span.kind == .heading {
                    attributes[.font] = Self.boldFont
                }
                storage.addAttributes(attributes, range: span.range)
            }
            storage.endEditing()
            textView.typingAttributes = base
        }

        /// The ink must be written explicitly. Text that carries no foreground
        /// colour is drawn black by TextKit regardless of the appearance, which in
        /// dark mode means black text on a dark page.
        private func baseAttributes(ink: NSColor) -> [NSAttributedString.Key: Any] {
            [
                .font: Self.baseFont,
                .foregroundColor: ink,
                .paragraphStyle: Self.paragraphStyle,
            ]
        }

        private func inkColor() -> NSColor {
            let appearance = textView?.effectiveAppearance ?? NSApp.effectiveAppearance
            return SourcePalette.resolve(for: appearance).ink
        }

        static let baseFont = NSFont.monospacedSystemFont(ofSize: SourceEditor.fontSize, weight: .regular)
        static let boldFont = NSFont.monospacedSystemFont(ofSize: SourceEditor.fontSize, weight: .semibold)
        static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            return style
        }()
    }
}
