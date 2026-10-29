import Foundation

/// One heading in the open document, with the place it came from.
///
/// The outline is derived from the source every time it is needed rather than
/// stored: the `.tex` file stays the only truth, so headings added in code mode
/// appear in the sidebar without a second bookkeeping path to keep in sync.
struct OutlineItem: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case part = 0
        case chapter = 1
        case section = 2
        case subsection = 3
        case subsubsection = 4
        case paragraph = 5

        var title: String {
            switch self {
            case .part: return "Part"
            case .chapter: return "Chapter"
            case .section: return "Section"
            case .subsection: return "Subsection"
            case .subsubsection: return "Subsubsection"
            case .paragraph: return "Paragraph"
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let level: Level
    let title: String
    /// One-based line of the heading command.
    let line: Int
    /// Where the heading starts in UTF-16 units, for the source editor's jump.
    let location: Int
    /// Words between this heading and the next one at the same or a higher level.
    let wordCount: Int

    var id: String { "\(line)-\(level.rawValue)-\(title)" }
}

enum DocumentOutline {

    private static let headingPattern = try! NSRegularExpression(
        pattern: "\\\\(part|chapter|section|subsection|subsubsection|paragraph)(\\*)?\\s*(\\[[^\\]]*\\])?\\s*\\{"
    )

    /// Parses the headings of a LaTeX document in source order.
    ///
    /// Titles may contain balanced braces (`\section{The \emph{big} idea}`), so the
    /// closing brace is found by counting rather than with a regex.
    static func parse(text: String) -> [OutlineItem] {
        let source = text as NSString
        guard source.length > 0 else { return [] }

        let lineStarts = self.lineStarts(in: source)
        var raw: [(level: OutlineItem.Level, title: String, line: Int, location: Int, bodyStart: Int)] = []

        let matches = headingPattern.matches(
            in: text, range: NSRange(location: 0, length: source.length)
        )
        for match in matches {
            guard let levelRange = Range(match.range(at: 1), in: text),
                  let level = level(named: String(text[levelRange])) else { continue }

            // A heading behind a % is a comment, not a heading. Escaped percent
            // signs do not start a comment.
            if isCommented(at: match.range.location, in: source) { continue }

            let openBrace = match.range.location + match.range.length - 1
            guard let closeBrace = matchingBrace(in: source, from: openBrace) else { continue }
            let titleRange = NSRange(location: openBrace + 1, length: closeBrace - openBrace - 1)
            let title = InlineLaTeX.plainText(in: source.substring(with: titleRange))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let line = lineNumber(at: match.range.location, lineStarts: lineStarts)
            raw.append((
                level: level,
                title: title.isEmpty ? level.title : title,
                line: line,
                location: match.range.location,
                bodyStart: closeBrace + 1
            ))
        }

        // Word counts need the next heading at the same or a higher level, so
        // they are computed after every heading's extent is known. The end of the
        // document is a hard stop: the closing environment is not prose.
        let closing = source.range(of: "\\end{document}")
        let endDocument = closing.location == NSNotFound ? source.length : closing.location
        return raw.enumerated().map { index, item in
            var end = min(endDocument, source.length)
            for next in raw[(index + 1)...] where next.level <= item.level {
                end = next.location
                break
            }
            let body = source.substring(with: NSRange(
                location: item.bodyStart, length: max(0, end - item.bodyStart)
            ))
            return OutlineItem(
                level: item.level,
                title: item.title,
                line: item.line,
                location: item.location,
                wordCount: wordCount(in: body)
            )
        }
    }

    // MARK: - Helpers

    private static func level(named name: String) -> OutlineItem.Level? {
        switch name {
        case "part": return .part
        case "chapter": return .chapter
        case "section": return .section
        case "subsection": return .subsection
        case "subsubsection": return .subsubsection
        case "paragraph": return .paragraph
        default: return nil
        }
    }

    private static func lineStarts(in source: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < source.length {
            if source.character(at: index) == 10 { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    private static func lineNumber(at location: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    private static func isCommented(at location: Int, in source: NSString) -> Bool {
        var index = location - 1
        var backslashes = 0
        while index >= 0 {
            let character = source.character(at: index)
            if character == 10 { break }
            if character == 92 { backslashes += 1; index -= 1; continue }
            break
        }
        // An odd number of backslashes escapes the %; even means a comment.
        guard backslashes % 2 == 0 else { return false }
        index = location - 1
        while index >= 0 {
            let character = source.character(at: index)
            if character == 10 { return false }
            if character == 37 {
                var escapes = 0
                var before = index - 1
                while before >= 0, source.character(at: before) == 92 {
                    escapes += 1
                    before -= 1
                }
                return escapes % 2 == 0
            }
            index -= 1
        }
        return false
    }

    private static func matchingBrace(in source: NSString, from open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < source.length {
            let character = source.character(at: index)
            if character == 92 {
                // Skip the escaped character so \{ and \} do not count.
                index += 2
                continue
            }
            if character == 123 { depth += 1 }
            if character == 125 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func wordCount(in source: String) -> Int {
        var text = source
        text = text.replacingOccurrences(
            of: "(?m)%.*$", with: " ", options: .regularExpression
        )
        // Commands and their punctuation are markup, not prose.
        text = text.replacingOccurrences(
            of: "\\\\[A-Za-z@]+\\*?", with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "[{}$&#_^~\\\\]", with: " ", options: .regularExpression
        )
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
