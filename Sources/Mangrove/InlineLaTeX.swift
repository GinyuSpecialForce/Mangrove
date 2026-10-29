import AppKit
import Foundation

// MARK: - Inline model

/// The formatting a run of prose carries, in the subset the visual editor can
/// round-trip without losing anything.
struct InlineStyle: OptionSet, Equatable {
    let rawValue: Int

    static let bold = InlineStyle(rawValue: 1 << 0)
    static let italic = InlineStyle(rawValue: 1 << 1)
    static let underline = InlineStyle(rawValue: 1 << 2)
    static let mono = InlineStyle(rawValue: 1 << 3)
}

/// A construct that is easier to keep intact than to edit as text: math, a
/// citation, a label. It is shown as a chip and written back verbatim.
struct InlineToken: Equatable {
    enum Kind: Equatable {
        case math
        case citation
        case reference
        case label
        case footnote
        case link
        case lineBreak
        case command
        case comment
    }

    let kind: Kind
    /// The exact LaTeX, delimiters included.
    let source: String
    /// What the chip shows.
    let display: String
}

struct InlineRun: Equatable {
    var text: String
    var style: InlineStyle = []
    var token: InlineToken?
}

// MARK: - Palette

/// Colours for the visual page. Resolved per appearance so the paper reads
/// correctly in both modes; the chips are deliberately quiet.
struct VisualPalette {
    let ink: NSColor
    let secondary: NSColor
    let mathInk: NSColor
    let mathFill: NSColor
    let citationInk: NSColor
    let citationFill: NSColor
    let neutralInk: NSColor
    let neutralFill: NSColor
    let commentInk: NSColor

    static func resolve(for appearance: NSAppearance) -> VisualPalette {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark {
            return VisualPalette(
                ink: NSColor(srgbRed: 0.91, green: 0.91, blue: 0.88, alpha: 1),
                secondary: NSColor(srgbRed: 0.64, green: 0.66, blue: 0.63, alpha: 1),
                mathInk: NSColor(srgbRed: 0.94, green: 0.73, blue: 0.42, alpha: 1),
                mathFill: NSColor(srgbRed: 0.77, green: 0.56, blue: 0.26, alpha: 0.20),
                citationInk: NSColor(srgbRed: 0.58, green: 0.76, blue: 1.00, alpha: 1),
                citationFill: NSColor(srgbRed: 0.38, green: 0.58, blue: 0.94, alpha: 0.18),
                neutralInk: NSColor(srgbRed: 0.74, green: 0.78, blue: 0.81, alpha: 1),
                neutralFill: NSColor(srgbRed: 0.58, green: 0.65, blue: 0.72, alpha: 0.18),
                commentInk: NSColor(srgbRed: 0.58, green: 0.66, blue: 0.58, alpha: 1)
            )
        }
        return VisualPalette(
            ink: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1),
            secondary: NSColor(srgbRed: 0.43, green: 0.45, blue: 0.43, alpha: 1),
            mathInk: NSColor(srgbRed: 0.55, green: 0.34, blue: 0.10, alpha: 1),
            mathFill: NSColor(srgbRed: 0.84, green: 0.67, blue: 0.35, alpha: 0.18),
            citationInk: NSColor(srgbRed: 0.10, green: 0.33, blue: 0.63, alpha: 1),
            citationFill: NSColor(srgbRed: 0.30, green: 0.52, blue: 0.85, alpha: 0.14),
            neutralInk: NSColor(srgbRed: 0.31, green: 0.35, blue: 0.38, alpha: 1),
            neutralFill: NSColor(srgbRed: 0.50, green: 0.56, blue: 0.62, alpha: 0.12),
            commentInk: NSColor(srgbRed: 0.42, green: 0.47, blue: 0.42, alpha: 1)
        )
    }
}

// MARK: - Attachment

extension NSAttributedString.Key {
    /// A copy of the raw token source, so a copied chip can still be written
    /// back as LaTeX.
    static let mangroveTokenSource = NSAttributedString.Key("MangroveTokenSource")
}

/// An atomic inline construct. Being an attachment means it behaves as one
/// character while editing, so the source can never be half-deleted.
final class InlineTokenAttachment: NSTextAttachment {
    let token: InlineToken

    init(token: InlineToken) {
        self.token = token
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("InlineTokenAttachment is created in code")
    }
}

// MARK: - The inline engine

enum InlineLaTeX {

    // MARK: Parsing

    static func runs(in source: String) -> [InlineRun] {
        var scanner = Scanner(chars: Array(source), style: [])
        scanner.scan()
        return scanner.runs
    }

    /// The readable text of a construct, used for captions and the title card.
    static func plainText(in source: String) -> String {
        var result = ""
        for run in runs(in: source) {
            if let token = run.token {
                switch token.kind {
                case .lineBreak:
                    result += " "
                case .comment:
                    break
                default:
                    if token.source == "\\and" {
                        if result.hasSuffix(" ") { result.removeLast() }
                        result += ", "
                    } else if token.source.hasPrefix("\\thanks{") {
                        // A title note belongs on the title page, not in a heading.
                        break
                    } else {
                        result += token.display
                    }
                }
            } else {
                result += run.text
            }
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Rendering

    static func attributed(
        runs: [InlineRun],
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        palette: VisualPalette
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (index, run) in runs.enumerated() {
            if let token = run.token {
                let attachment = InlineTokenAttachment(token: token)
                // A chip is a picture, so its own padding is the only space the
                // reader sees. When the source puts punctuation straight after
                // the construct (`\cite{key}.`), draw that side tight, or the
                // page reads "[key] ." with a gap LaTeX never prints.
                attachment.image = image(
                    for: token,
                    palette: palette,
                    tightRight: isFollowedByPunctuation(runs, at: index)
                )
                if let image = attachment.image {
                    attachment.bounds = CGRect(
                        x: 0, y: -3.5, width: image.size.width, height: image.size.height
                    )
                }
                let string = NSMutableAttributedString(attachment: attachment)
                string.addAttribute(
                    .font, value: baseFont,
                    range: NSRange(location: 0, length: string.length)
                )
                string.addAttribute(
                    .mangroveTokenSource, value: token.source,
                    range: NSRange(location: 0, length: string.length)
                )
                result.append(string)
            } else {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(for: run.style, base: baseFont),
                    .foregroundColor: palette.ink,
                    .paragraphStyle: paragraphStyle,
                ]
                if run.style.contains(.underline) {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }

        return result
    }

    /// The chip that is inserted by the format bar.
    static func attributedToken(
        _ token: InlineToken, baseFont: NSFont, palette: VisualPalette
    ) -> NSAttributedString {
        attributed(
            runs: [InlineRun(text: token.display, style: [], token: token)],
            baseFont: baseFont,
            paragraphStyle: NSMutableParagraphStyle(),
            palette: palette
        )
    }

    static func font(for style: InlineStyle, base: NSFont) -> NSFont {
        if style.contains(.mono) {
            let mono = NSFont.monospacedSystemFont(
                ofSize: base.pointSize * 0.92,
                weight: style.contains(.bold) ? .semibold : .regular
            )
            if style.contains(.italic) {
                return NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
            }
            return mono
        }

        var font = base
        if style.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if style.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    // MARK: Writing back

    /// Serializes an edited block. Text is escaped, attached chips are restored
    /// from their original source, and paragraphs are separated by a blank line.
    static func latex(from attributed: NSAttributedString, baseFont: NSFont) -> String {
        var output = ""
        var buffer = ""
        var bufferStyle: InlineStyle = []

        func flush() {
            guard !buffer.isEmpty else { return }
            output += wrap(buffer, style: bufferStyle)
            buffer = ""
            bufferStyle = []
        }

        let source = attributed.string as NSString
        var index = 0
        while index < attributed.length {
            let attributes = attributed.attributes(at: index, effectiveRange: nil)
            let character = source.substring(with: NSRange(location: index, length: 1))

            if attributes[.attachment] != nil || character == "\u{FFFC}" {
                let tokenSource = (attributes[.attachment] as? InlineTokenAttachment)?.token.source
                    ?? attributes[.mangroveTokenSource] as? String
                if let tokenSource {
                    flush()
                    output += tokenSource
                }
                index += 1
                continue
            }

            if character == "\n" {
                flush()
                output += "\n\n"
                index += 1
                continue
            }

            let style = style(in: attributes, base: baseFont)
            if style != bufferStyle {
                flush()
                bufferStyle = style
            }
            buffer += character
            index += 1
        }
        flush()

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\textbackslash{}"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "$": out += "\\$"
            case "&": out += "\\&"
            case "%": out += "\\%"
            case "#": out += "\\#"
            case "_": out += "\\_"
            case "^": out += "\\textasciicircum{}"
            case "~": out += "\\textasciitilde{}"
            case "\u{00A0}": out += "~"
            default: out.append(character)
            }
        }
        return out
    }

    private static func wrap(_ text: String, style: InlineStyle) -> String {
        guard !style.isEmpty else { return escape(text) }
        var result = escape(text)
        if style.contains(.mono) { result = "\\texttt{\(result)}" }
        if style.contains(.underline) { result = "\\underline{\(result)}" }
        if style.contains(.italic) { result = "\\textit{\(result)}" }
        if style.contains(.bold) { result = "\\textbf{\(result)}" }
        return result
    }

    private static func style(
        in attributes: [NSAttributedString.Key: Any], base: NSFont
    ) -> InlineStyle {
        var style: InlineStyle = []
        if let font = attributes[.font] as? NSFont {
            let manager = NSFontManager.shared
            let traits = manager.traits(of: font)
            let baseTraits = manager.traits(of: base)
            if traits.contains(.boldFontMask) != baseTraits.contains(.boldFontMask) {
                style.insert(.bold)
            }
            if traits.contains(.italicFontMask) != baseTraits.contains(.italicFontMask) {
                style.insert(.italic)
            }
            if font.isFixedPitch && !base.isFixedPitch {
                style.insert(.mono)
            }
        }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
            style.insert(.underline)
        }
        return style
    }

    // MARK: Chip art

    /// True when the next run starts with punctuation and no space, which is
    /// how normal prose follows a citation, reference or inline formula.
    private static func isFollowedByPunctuation(_ runs: [InlineRun], at index: Int) -> Bool {
        guard index + 1 < runs.count, runs[index + 1].token == nil,
              let first = runs[index + 1].text.first else { return false }
        return ".,;:!?)]}".contains(first)
    }

    private static func image(
        for token: InlineToken, palette: VisualPalette, tightRight: Bool = false
    ) -> NSImage {
        let text: String
        let ink: NSColor
        let fill: NSColor
        var font = NSFont.systemFont(ofSize: 10.5, weight: .medium)

        switch token.kind {
        case .math:
            text = token.display
            ink = palette.mathInk
            fill = palette.mathFill
            font = NSFont(name: "Times New Roman", size: 11.5)
                ?? NSFont.systemFont(ofSize: 11)
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case .citation, .reference, .link:
            text = token.display
            ink = palette.citationInk
            fill = palette.citationFill
        case .comment:
            text = token.display
            ink = palette.commentInk
            fill = palette.neutralFill
        case .label, .footnote, .lineBreak, .command:
            text = token.display
            ink = palette.neutralInk
            fill = palette.neutralFill
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height: CGFloat = 17
        let rightPad: CGFloat = tightRight ? 0.5 : 4.5
        let width = min(ceil(textSize.width) + 4.5 + rightPad, 310)
        let size = NSSize(width: max(width, 16), height: height)

        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.75),
                xRadius: 4, yRadius: 4
            )
            fill.setFill()
            path.fill()
            let y = (rect.height - textSize.height) / 2 + 0.5
            (text as NSString).draw(
                at: NSPoint(x: 4.5, y: y),
                withAttributes: attributes
            )
            return true
        }
    }

    // MARK: Scanner

    private struct Scanner {
        let chars: [Character]
        var index = 0
        var runs: [InlineRun] = []
        var style: InlineStyle

        init(chars: [Character], style: InlineStyle) {
            self.chars = chars
            self.style = style
        }

        mutating func scan() {
            while index < chars.count {
                let character = chars[index]
                switch character {
                case "\\":
                    parseCommand()
                case "$":
                    parseMath()
                case "%":
                    parseComment()
                case "~":
                    index += 1
                    appendText("\u{00A0}")
                case "{", "}", "&", "^", "_":
                    index += 1
                    appendToken(InlineToken(
                        kind: .command,
                        source: String(character),
                        display: String(character)
                    ))
                case "\n":
                    index += 1
                    appendText(" ")
                default:
                    index += 1
                    appendText(String(character))
                }
            }
        }

        // MARK: Runs

        mutating func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            if var last = runs.last, last.token == nil, last.style == style {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(InlineRun(text: text, style: style, token: nil))
            }
        }

        mutating func appendToken(_ token: InlineToken) {
            runs.append(InlineRun(text: token.display, style: style, token: token))
        }

        // MARK: Commands

        mutating func parseCommand() {
            let start = index
            index += 1
            guard index < chars.count else {
                appendText("\\")
                return
            }

            let next = chars[index]

            if next == "\\" {
                index += 1
                appendToken(InlineToken(kind: .lineBreak, source: "\\\\", display: "↵"))
                return
            }
            if "%&_#${}".contains(next) {
                index += 1
                appendText(String(next))
                return
            }
            if next == " " || next == "\t" || next == "\n" {
                index += 1
                appendText(" ")
                return
            }
            if next == "(" || next == "[" {
                let closing: Character = next == "(" ? ")" : "]"
                var cursor = index + 1
                while cursor + 1 < chars.count {
                    if chars[cursor] == "\\" && chars[cursor + 1] == closing {
                        let inner = String(chars[(index + 1)..<cursor])
                        let source = String(chars[start...(cursor + 1)])
                        index = cursor + 2
                        appendToken(InlineToken(
                            kind: .math, source: source, display: mathDisplay(inner)
                        ))
                        return
                    }
                    cursor += 1
                }
                index += 1
                appendToken(InlineToken(
                    kind: .command, source: String(chars[start..<index]), display: "\\("
                ))
                return
            }

            guard next.isLetter || next == "@" else {
                index += 1
                appendToken(InlineToken(
                    kind: .command,
                    source: String(chars[start..<index]),
                    display: String(chars[start..<index])
                ))
                return
            }

            var cursor = index
            while cursor < chars.count, chars[cursor].isLetter || chars[cursor] == "@" {
                cursor += 1
            }
            let name = String(chars[index..<cursor])
            var nameEnd = cursor
            if nameEnd < chars.count, chars[nameEnd] == "*" { nameEnd += 1 }
            index = nameEnd

            if let extra = styleCommand(name) {
                skipSpaces()
                if index < chars.count, chars[index] == "{", let group = groupRange(at: index) {
                    let inner = Array(chars[group.content])
                    var sub = Scanner(chars: inner, style: style.union(extra))
                    sub.scan()
                    runs.append(contentsOf: sub.runs)
                    index = group.end
                    return
                }
                // A style command without its argument is not worth a chip with
                // no content; show the command as written.
                appendToken(InlineToken(
                    kind: .command,
                    source: String(chars[start..<nameEnd]),
                    display: "\\" + name
                ))
                return
            }

            let arguments = captureArguments()
            let source = String(chars[start..<index])

            if let display = symbolDisplay(name) {
                appendToken(InlineToken(kind: .command, source: source, display: display))
                return
            }
            if name == "newline" || name == "linebreak" {
                appendToken(InlineToken(kind: .lineBreak, source: source, display: "↵"))
                return
            }

            switch name {
            case "cite", "citep", "citet", "citeauthor", "citeyear", "nocite",
                 "parencite", "textcite", "autocite", "footcite":
                let keys = arguments.last.map(citationKeys) ?? ""
                appendToken(InlineToken(
                    kind: .citation,
                    source: source,
                    display: shorten("[\(keys)]", 34)
                ))

            case "ref", "autoref", "cref", "Cref":
                let key = arguments.last ?? ""
                appendToken(InlineToken(
                    kind: .reference, source: source,
                    display: shorten("→ \(key)", 26)
                ))
            case "eqref":
                let key = arguments.last ?? ""
                appendToken(InlineToken(
                    kind: .reference, source: source,
                    display: shorten("(\(key))", 26)
                ))
            case "pageref":
                let key = arguments.last ?? ""
                appendToken(InlineToken(
                    kind: .reference, source: source,
                    display: shorten("p. \(key)", 26)
                ))
            case "label":
                let key = arguments.last ?? ""
                appendToken(InlineToken(
                    kind: .label, source: source,
                    display: shorten("#\(key)", 24)
                ))
            case "footnote":
                let note = arguments.last.map { plainText(in: $0) } ?? ""
                appendToken(InlineToken(
                    kind: .footnote, source: source,
                    display: shorten("† \(note)", 28)
                ))
            case "url":
                let url = arguments.last ?? ""
                appendToken(InlineToken(
                    kind: .link, source: source, display: shorten(url, 34)
                ))
            case "href":
                let label = arguments.count >= 2
                    ? plainText(in: arguments[arguments.count - 1])
                    : (arguments.last ?? "")
                appendToken(InlineToken(
                    kind: .link, source: source, display: shorten(label, 34)
                ))
            case "includegraphics":
                let path = arguments.last ?? ""
                let name = (path as NSString).lastPathComponent
                appendToken(InlineToken(
                    kind: .command, source: source,
                    display: shorten(name.isEmpty ? "figure" : name, 28)
                ))
            case "verb", "lstinline":
                appendToken(InlineToken(
                    kind: .command, source: source,
                    display: shorten("\\\(name)", 24)
                ))
            case "begin", "end":
                let env = arguments.first ?? ""
                appendToken(InlineToken(
                    kind: .command,
                    source: source,
                    display: shorten("\\\(name){\(env)}", 28)
                ))
            default:
                let display = arguments.isEmpty
                    ? "\\" + name
                    : "\\" + name + "{…}"
                appendToken(InlineToken(
                    kind: .command,
                    source: source,
                    display: shorten(display, 32)
                ))
            }
        }

        private func styleCommand(_ name: String) -> InlineStyle? {
            switch name {
            case "textbf", "bfseries": return .bold
            case "textit", "emph", "textsl": return .italic
            case "underline": return .underline
            case "texttt": return .mono
            default: return nil
            }
        }

        private func symbolDisplay(_ name: String) -> String? {
            switch name {
            case "LaTeX": return "LaTeX"
            case "TeX": return "TeX"
            case "LaTeXe": return "LaTeX2e"
            case "dots", "ldots": return "…"
            case "textbackslash": return "\\"
            case "textasciitilde": return "~"
            case "textasciicircum": return "^"
            default: return nil
            }
        }

        // MARK: Math and comments

        mutating func parseMath() {
            let start = index
            let double = index + 1 < chars.count && chars[index + 1] == "$"
            let delimiter = double ? 2 : 1
            var cursor = index + delimiter

            while cursor < chars.count {
                if chars[cursor] == "\\" {
                    cursor += 2
                    continue
                }
                if chars[cursor] == "$" {
                    if double {
                        guard cursor + 1 < chars.count, chars[cursor + 1] == "$" else {
                            cursor += 1
                            continue
                        }
                        let inner = String(chars[(index + delimiter)..<cursor])
                        let source = String(chars[start..<(cursor + 2)])
                        index = cursor + 2
                        appendToken(InlineToken(
                            kind: .math, source: source, display: mathDisplay(inner)
                        ))
                        return
                    }
                    let inner = String(chars[(index + 1)..<cursor])
                    let source = String(chars[start..<(cursor + 1)])
                    index = cursor + 1
                    appendToken(InlineToken(
                        kind: .math, source: source, display: mathDisplay(inner)
                    ))
                    return
                }
                cursor += 1
            }

            // Unclosed math: leave the delimiter as text rather than eating the
            // rest of the paragraph.
            index = start + delimiter
            appendText(double ? "$$" : "$")
        }

        mutating func parseComment() {
            let start = index
            while index < chars.count, chars[index] != "\n" { index += 1 }
            let source = String(chars[start..<index])
            appendToken(InlineToken(
                kind: .comment, source: source, display: shorten(source, 36)
            ))
        }

        // MARK: Argument scanning

        mutating func skipSpaces() {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" {
                index += 1
            }
        }

        mutating func captureArguments() -> [String] {
            var arguments: [String] = []
            while true {
                // Whitespace belongs to the prose unless an argument actually
                // follows it; `\LaTeX{} Test` must keep its space.
                let beforeSpaces = index
                skipSpaces()
                guard index < chars.count else {
                    index = beforeSpaces
                    break
                }
                if chars[index] == "[" {
                    guard let end = bracketEnd(at: index) else {
                        index = beforeSpaces
                        break
                    }
                    arguments.append(String(chars[(index + 1)..<(end - 1)]))
                    index = end
                } else if chars[index] == "{" {
                    guard let group = groupRange(at: index) else {
                        index = beforeSpaces
                        break
                    }
                    arguments.append(String(chars[group.content]))
                    index = group.end
                } else {
                    index = beforeSpaces
                    break
                }
            }
            return arguments
        }

        func groupRange(at open: Int) -> (content: Range<Int>, end: Int)? {
            guard open < chars.count, chars[open] == "{" else { return nil }
            var depth = 0
            var cursor = open
            while cursor < chars.count {
                let character = chars[cursor]
                if character == "\\" {
                    cursor += 2
                    continue
                }
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return ((open + 1)..<cursor, cursor + 1) }
                }
                cursor += 1
            }
            return nil
        }

        func bracketEnd(at open: Int) -> Int? {
            guard open < chars.count, chars[open] == "[" else { return nil }
            var depth = 0
            var cursor = open
            while cursor < chars.count {
                let character = chars[cursor]
                if character == "\\" {
                    cursor += 2
                    continue
                }
                if character == "[" { depth += 1 }
                if character == "]" {
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                }
                cursor += 1
            }
            return nil
        }

        // MARK: Display helpers

        private func citationKeys(_ argument: String) -> String {
            argument
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        private func mathDisplay(_ inner: String) -> String {
            let text = inner
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return shorten(text.isEmpty ? "math" : text, 42)
        }

        private func shorten(_ text: String, _ limit: Int) -> String {
            let single = text.replacingOccurrences(of: "\n", with: " ")
            guard single.count > limit else { return single }
            return String(single.prefix(max(limit - 1, 1))) + "…"
        }
    }
}
