import AppKit
import SwiftUI

// MARK: - Type

/// The visual page's own type scale. Charter (with a Palatino fallback) reads
/// like a paper rather than a code editor; the sizes follow LaTeX's sectioning.
enum VisualType {
    static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base = NSFont(name: "Charter", size: size)
            ?? NSFont(name: "Palatino", size: size)
            ?? NSFont.systemFont(ofSize: size)
        var font = base
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func heading(_ level: Int) -> NSFont {
        switch level {
        case 0: return serif(23, bold: true)
        case 1: return serif(19, bold: true)
        case 2: return serif(15.5, bold: true)
        case 3: return serif(13.5, bold: true)
        default: return serif(13.5, bold: true, italic: true)
        }
    }

    static func paragraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = .natural
        return style
    }
}

// MARK: - Formatting session

/// Commands from the format bar act on whichever block was last focused. The
/// reference is deliberately kept when the text view resigns first responder:
/// clicking a toolbar button should not lose the selection it is meant to
/// format.
@MainActor
final class VisualEditorSession: ObservableObject {
    @Published private(set) var hasBlock = false

    private weak var textView: NSTextView?
    private var lastSelection = NSRange(location: 0, length: 0)
    private var baseFont = VisualType.serif(14)

    func focus(_ textView: NSTextView, baseFont: NSFont) {
        self.textView = textView
        self.baseFont = baseFont
        lastSelection = textView.selectedRange()
        if !hasBlock { hasBlock = true }
    }

    func blur(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        lastSelection = textView.selectedRange()
    }

    func rememberSelection(_ range: NSRange) {
        lastSelection = range
    }

    /// Called when the document is replaced from outside (a save, a merge, a
    /// file switch). No block should receive a format command afterwards.
    func reset() {
        textView = nil
        hasBlock = false
        lastSelection = NSRange(location: 0, length: 0)
    }

    func toggleBold() { toggle(.boldFontMask) }
    func toggleItalic() { toggle(.italicFontMask) }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        refocus(textView)
        let range = selection(in: textView)

        if range.length == 0 {
            var attributes = textView.typingAttributes
            if attributes[.underlineStyle] != nil {
                attributes.removeValue(forKey: .underlineStyle)
            } else {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            textView.typingAttributes = attributes
            return
        }

        let snapshot = attributeSnapshot(storage, key: .underlineStyle, range: range)
        let underlined = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) != nil
        storage.beginEditing()
        if underlined {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range
            )
        }
        storage.endEditing()
        registerUndo(textView, key: .underlineStyle, snapshot: snapshot)
        textView.didChangeText()
        textView.setSelectedRange(range)
        rememberSelection(range)
    }

    func insertMath() {
        guard let textView else { return }
        let saved = selection(in: textView)
        guard let raw = prompt(
            title: "Insert math",
            message: "Type LaTeX without the dollar signs. It stays as inline math in the source.",
            placeholder: #"\alpha + \beta \le \gamma"#
        ) else { return }

        var math = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !math.isEmpty else { return }
        if math.hasPrefix("$") && math.hasSuffix("$") && math.count > 2 {
            math = String(math.dropFirst().dropLast())
        }
        if math.hasPrefix("\\[") && math.hasSuffix("\\]") && math.count > 4 {
            math = String(math.dropFirst(2).dropLast(2))
        }
        let token = InlineToken(
            kind: .math,
            source: "$\(math)$",
            display: shortened(math, 42)
        )
        insert(token, savedSelection: saved, in: textView)
    }

    func insertCitation() {
        guard let textView else { return }
        let saved = selection(in: textView)
        guard let raw = prompt(
            title: "Insert citation",
            message: "Type one or more BibTeX keys, separated by commas.",
            placeholder: "smith2020, doe2021"
        ) else { return }
        let keys = raw
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keys.isEmpty else { return }
        let token = InlineToken(
            kind: .citation,
            source: "\\cite{\(keys)}",
            display: shortened("[\(keys)]", 34)
        )
        insert(token, savedSelection: saved, in: textView)
    }

    // MARK: Internals

    private func toggle(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        refocus(textView)
        let range = selection(in: textView)

        if range.length == 0 {
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? baseFont
            let manager = NSFontManager.shared
            let has = manager.traits(of: font).contains(trait)
            attributes[.font] = has
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attributes
            return
        }

        let snapshot = attributeSnapshot(storage, key: .font, range: range)
        let manager = NSFontManager.shared
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? self.baseFont
            let has = manager.traits(of: font).contains(trait)
            let changed = has
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: changed, range: subrange)
        }
        storage.endEditing()
        registerUndo(textView, key: .font, snapshot: snapshot)
        textView.didChangeText()
        textView.setSelectedRange(range)
        rememberSelection(range)
    }

    private func insert(
        _ token: InlineToken, savedSelection: NSRange, in textView: NSTextView
    ) {
        refocus(textView)
        let range = clamped(savedSelection, to: textView)
        textView.setSelectedRange(range)
        let palette = VisualPalette.resolve(for: textView.effectiveAppearance)
        let attributed = InlineLaTeX.attributedToken(
            token,
            baseFont: (textView.typingAttributes[.font] as? NSFont) ?? baseFont,
            palette: palette
        )
        textView.insertText(attributed, replacementRange: range)
        textView.didChangeText()
        rememberSelection(textView.selectedRange())
        textView.window?.makeFirstResponder(textView)
    }

    private func refocus(_ textView: NSTextView) {
        if textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func selection(in textView: NSTextView) -> NSRange {
        let length = (textView.string as NSString).length
        let location = min(max(lastSelection.location, 0), length)
        let rangeLength = min(max(lastSelection.length, 0), length - location)
        return NSRange(location: location, length: rangeLength)
    }

    private func clamped(_ range: NSRange, to textView: NSTextView) -> NSRange {
        let length = (textView.string as NSString).length
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }

    private func attributeSnapshot(
        _ storage: NSTextStorage, key: NSAttributedString.Key, range: NSRange
    ) -> [(NSRange, Any?)] {
        var snapshot: [(NSRange, Any?)] = []
        storage.enumerateAttribute(key, in: range, options: []) { value, subrange, _ in
            snapshot.append((subrange, value))
        }
        return snapshot
    }

    private func registerUndo(
        _ textView: NSTextView, key: NSAttributedString.Key, snapshot: [(NSRange, Any?)]
    ) {
        guard let undoManager = textView.undoManager else { return }
        undoManager.registerUndo(withTarget: textView) { target in
            guard let storage = target.textStorage else { return }
            for (range, value) in snapshot where range.upperBound <= storage.length {
                if let value {
                    storage.addAttribute(key, value: value, range: range)
                } else {
                    storage.removeAttribute(key, range: range)
                }
            }
            target.didChangeText()
        }
        undoManager.setActionName("Format")
    }

    private func prompt(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func shortened(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard single.count > limit else { return single }
        return String(single.prefix(limit - 1)) + "…"
    }
}

// MARK: - Auto-sizing text view

/// An editable text view that reports its laid-out height to SwiftUI. The visual
/// page lets every block grow, so each one is measured at the pane's width
/// rather than living in its own scroll view.
final class VisualBlockTextView: NSTextView {
    var allowsParagraphs = true
    var onCommit: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    /// Each block keeps its own undo stack. Sharing the window's stack would let
    /// an undo in one block silently rewrite another block's source after the
    /// page has been re-parsed.
    private lazy var blockUndoManager = UndoManager()
    override var undoManager: UndoManager? { blockUndoManager }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return .zero }
        let width = max(bounds.width, 40)
        if abs(textContainer.containerSize.width - width) > 0.5 {
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = ceil(used.height + textContainerInset.height * 2)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 20))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            textContainer?.containerSize = NSSize(
                width: max(newSize.width, 1), height: .greatestFiniteMagnitude
            )
            invalidateIntrinsicContentSize()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func insertNewline(_ sender: Any?) {
        if allowsParagraphs {
            super.insertNewline(sender)
        } else {
            onCommit?()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

// MARK: - Editable block

struct VisualTextBlock: NSViewRepresentable {
    let block: VisualBlock
    let baseFont: NSFont
    let paragraphStyle: NSParagraphStyle
    let singleLine: Bool
    let model: VisualDocumentModel
    let session: VisualEditorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, session: session, block: block)
    }

    func makeNSView(context: Context) -> VisualBlockTextView {
        let view = VisualBlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        view.isRichText = true
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.allowsUndo = true
        view.usesFindBar = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.allowsParagraphs = !singleLine
        view.delegate = context.coordinator
        view.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.appearanceChanged()
        }
        view.onCommit = { [weak view] in
            view?.window?.makeFirstResponder(nil)
        }
        context.coordinator.attach(view)
        context.coordinator.apply(
            block: block, baseFont: baseFont, paragraphStyle: paragraphStyle
        )
        return view
    }

    func updateNSView(_ view: VisualBlockTextView, context: Context) {
        view.allowsParagraphs = !singleLine
        context.coordinator.apply(
            block: block, baseFont: baseFont, paragraphStyle: paragraphStyle
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let model: VisualDocumentModel
        private let session: VisualEditorSession
        private weak var textView: VisualBlockTextView?
        private var block: VisualBlock
        private var baseFont = VisualType.serif(14)
        private var paragraphStyle = VisualType.paragraphStyle(lineSpacing: 5)
        private var loadedEditable: String?
        private var isLoading = false

        init(model: VisualDocumentModel, session: VisualEditorSession, block: VisualBlock) {
            self.model = model
            self.session = session
            self.block = block
        }

        func attach(_ view: VisualBlockTextView) {
            textView = view
        }

        func apply(
            block: VisualBlock, baseFont: NSFont, paragraphStyle: NSParagraphStyle
        ) {
            self.block = block
            self.baseFont = baseFont
            self.paragraphStyle = paragraphStyle
            guard let textView else { return }
            guard textView.window?.firstResponder !== textView else { return }
            if loadedEditable != (block.editable ?? "") {
                render()
            }
            textView.typingAttributes = baseAttributes(for: textView)
        }

        func appearanceChanged() {
            guard let textView else { return }
            guard textView.window?.firstResponder !== textView else { return }
            render()
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView else { return }
            model.beginEditing(block.id)
            session.focus(textView, baseFont: baseFont)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView else { return }
            session.blur(textView)
            model.endEditing(block.id)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let textView { session.rememberSelection(textView.selectedRange()) }
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView else { return }
            let latex = InlineLaTeX.latex(
                from: textView.attributedString(), baseFont: baseFont
            )
            model.update(block.id, with: latex)
        }

        private func render() {
            guard let textView else { return }
            isLoading = true
            let palette = VisualPalette.resolve(for: textView.effectiveAppearance)
            let runs = InlineLaTeX.runs(in: block.editable ?? "")
            let attributed = InlineLaTeX.attributed(
                runs: runs,
                baseFont: baseFont,
                paragraphStyle: paragraphStyle,
                palette: palette
            )
            textView.textStorage?.setAttributedString(attributed)
            textView.textColor = palette.ink
            textView.insertionPointColor = palette.ink
            textView.typingAttributes = baseAttributes(for: textView, palette: palette)
            loadedEditable = block.editable ?? ""
            isLoading = false
            textView.invalidateIntrinsicContentSize()
        }

        private func baseAttributes(
            for textView: NSTextView, palette: VisualPalette? = nil
        ) -> [NSAttributedString.Key: Any] {
            let colors = palette ?? VisualPalette.resolve(for: textView.effectiveAppearance)
            return [
                .font: baseFont,
                .foregroundColor: colors.ink,
                .paragraphStyle: paragraphStyle,
            ]
        }
    }
}

// MARK: - The pane

struct VisualEditor: View {
    @EnvironmentObject private var state: AppState
    @Binding var text: String

    @StateObject private var model = VisualDocumentModel()
    @StateObject private var session = VisualEditorSession()

    var body: some View {
        VStack(spacing: 0) {
            formatBar
            Rule()
            ScrollView {
                page
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 26)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear(perform: connect)
        .onChange(of: text) { newValue in
            // The model's own edits arrive here as the value it just published,
            // so they are ignored. Anything else — a merge, a save that adopted
            // remote changes, a file switch — is authoritative and must replace
            // the page even if a paragraph has focus.
            guard newValue != model.source else { return }
            session.reset()
            model.load(newValue)
        }
        .onDisappear { model.commitNow() }
    }

    private func connect() {
        model.setTextHandler { updated in
            if text != updated { text = updated }
        }
        model.load(text)
    }

    // MARK: Format bar

    private var formatBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                formatButton("bold", help: "Bold") { session.toggleBold() }
                formatButton("italic", help: "Italic") { session.toggleItalic() }
                formatButton("underline", help: "Underline") { session.toggleUnderline() }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )

            HStack(spacing: 2) {
                formatButton("function", help: "Insert inline math") { session.insertMath() }
                formatButton("quote.bubble", help: "Insert a citation") { session.insertCitation() }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )

            if let preamble = model.document.preambleRange {
                Button {
                    state.revealInCode(range: NSRange(location: preamble.location, length: 0))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Preamble")
                            .font(Theme.Typeface.ui(9.5, .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("Edit the document preamble in the source")
            }

            Spacer(minLength: 4)

            Text(session.hasBlock ? "Formatted text" : "Click a paragraph to edit")
                .font(Theme.Typeface.ui(9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func formatButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, height: 19)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Page

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.document.blocks.isEmpty {
                EmptyState(
                    icon: "doc.text",
                    title: "Nothing to show",
                    detail: "This file has no document body yet. Switch to Code to write one."
                )
                .padding(.top, 30)
            } else {
                ForEach(model.document.blocks) { block in
                    VisualBlockRow(
                        block: block,
                        model: model,
                        session: session,
                        onEditInCode: { range in state.revealInCode(range: range) },
                        onOpenFile: { path in state.openFile(path) }
                    )
                    .padding(.top, topSpacing(for: block))
                }
            }
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 13, y: 4)
        )
    }

    @ViewBuilder
    private var header: some View {
        if model.document.title != nil
            || model.document.author != nil
            || model.document.date != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let title = model.document.title {
                    Text(title)
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let author = model.document.author {
                        Text(author)
                            .font(Theme.Typeface.ui(11.5))
                            .foregroundStyle(.secondary)
                    }
                    if let date = model.document.date {
                        Text(date)
                            .font(Theme.Typeface.ui(10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if model.document.packageCount > 0 {
                        Text("\(model.document.packageCount) packages")
                            .font(Theme.Typeface.ui(9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.bottom, 20)
            .overlay(alignment: .bottom) { Rule() }
            .padding(.bottom, 18)
        }
    }

    private func topSpacing(for block: VisualBlock) -> CGFloat {
        guard block.id != model.document.blocks.first?.id else { return 0 }
        switch block.kind {
        case let .heading(level):
            return level <= 1 ? 26 : (level == 2 ? 20 : 15)
        case .paragraph:
            return 11
        case .listItem:
            return 3
        case .command:
            return 7
        default:
            return 16
        }
    }
}

// MARK: - One block

@MainActor
struct VisualBlockRow: View {
    let block: VisualBlock
    let model: VisualDocumentModel
    let session: VisualEditorSession
    let onEditInCode: (NSRange) -> Void
    let onOpenFile: (String) -> Void

    var body: some View {
        switch block.kind {
        case let .heading(level):
            heading(level: level)
        case .paragraph:
            paragraph
        case let .listItem(marker):
            listItem(marker: marker)
        case .math:
            mathCard
        case .figure:
            figureCard
        case .table:
            tableCard
        case .verbatim:
            verbatimCard
        case .raw:
            rawCard
        case .command:
            commandRow
        }
    }

    // MARK: Editable

    private func heading(level: Int) -> some View {
        VisualTextBlock(
            block: block,
            baseFont: VisualType.heading(level),
            paragraphStyle: VisualType.paragraphStyle(lineSpacing: 1.5),
            singleLine: true,
            model: model,
            session: session
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paragraph: some View {
        VisualTextBlock(
            block: block,
            baseFont: VisualType.serif(14),
            paragraphStyle: VisualType.paragraphStyle(lineSpacing: 5.5),
            singleLine: false,
            model: model,
            session: session
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listItem(marker: VisualBlock.ListMarker) -> some View {
        VisualTextBlock(
            block: block,
            baseFont: VisualType.serif(14),
            paragraphStyle: VisualType.paragraphStyle(lineSpacing: 4),
            singleLine: false,
            model: model,
            session: session
        )
        .padding(.leading, 27)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            markerView(marker)
                .frame(width: 19, alignment: .trailing)
                .padding(.top, 3)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func markerView(_ marker: VisualBlock.ListMarker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(.secondary)
        case let .number(number):
            Text("\(number).")
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(.secondary)
        case let .label(label):
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: Read-only cards

    private var mathCard: some View {
        cardShell(
            icon: "function",
            label: block.detail?.uppercased() ?? "EQUATION",
            preview: mathPreview,
            mono: true
        )
    }

    private var figureCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardHead(icon: "photo", label: "FIGURE")
            if let caption = block.caption {
                Text(caption)
                    .font(.system(size: 12.5, design: .serif))
                    .italic()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let path = block.path {
                HStack(spacing: 5) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                    Text(path)
                        .font(Theme.Typeface.mono(9.5))
                }
                .foregroundStyle(.secondary)
            }
        }
        .cardBackground()
    }

    private var tableCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardHead(icon: "tablecells", label: "TABLE")
            if let caption = block.caption {
                Text(caption)
                    .font(.system(size: 12.5, design: .serif))
                    .italic()
                    .foregroundStyle(.primary)
            }
            Text(block.source)
                .font(Theme.Typeface.mono(9))
                .foregroundStyle(.tertiary)
                .lineLimit(4)
        }
        .cardBackground()
    }

    private var verbatimCard: some View {
        cardShell(
            icon: "text.alignleft",
            label: (block.detail ?? "code").uppercased(),
            preview: block.source,
            mono: true
        )
    }

    private var rawCard: some View {
        cardShell(
            icon: "square.dashed",
            label: (block.detail ?? "markup").uppercased(),
            preview: block.source,
            mono: true
        )
    }

    private var commandRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(block.detail ?? block.source)
                .font(Theme.Typeface.mono(9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let path = block.path {
                Button("Open") { onOpenFile(path) }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(Theme.leaf)
            }
            Button {
                onEditInCode(sourceStart)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Edit this command in the source")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func cardShell(
        icon: String, label: String, preview: String, mono: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            cardHead(icon: icon, label: label)
            Text(preview)
                .font(mono ? Theme.Typeface.mono(10.5) : Theme.Typeface.ui(11))
                .foregroundStyle(.secondary)
                .lineLimit(7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardBackground()
    }

    private func cardHead(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
            Text(label)
                .font(Theme.Typeface.ui(8.5, .semibold))
                .tracking(0.4)
            Spacer(minLength: 4)
            Button("Edit in Code") {
                onEditInCode(sourceStart)
            }
            .buttonStyle(.plain)
            .font(Theme.Typeface.ui(9.5, .medium))
            .foregroundStyle(Theme.leaf)
        }
        .foregroundStyle(.secondary)
    }

    /// A caret at the construct's first character. Selecting a whole figure or
    /// equation would scroll to its end, not show where it begins.
    private var sourceStart: NSRange {
        let range = model.currentRange(for: block.id)
        return NSRange(location: range.location, length: 0)
    }

    private var mathPreview: String {
        var lines = block.source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("\\begin{") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("\\end{") {
            lines.removeLast()
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\\[") && text.hasSuffix("\\]") && text.count > 4 {
            text = String(text.dropFirst(2).dropLast(2))
        }
        if text.hasPrefix("$$") && text.hasSuffix("$$") && text.count > 4 {
            text = String(text.dropFirst(2).dropLast(2))
        }
        return text
    }
}

// MARK: - Card chrome

private extension View {
    func cardBackground() -> some View {
        self
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.rule, lineWidth: 1)
            )
    }
}
