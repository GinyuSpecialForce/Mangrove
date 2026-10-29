import Foundation

/// A matching `\end{...}` to insert after a `\begin{...}` line.
struct EnvironmentClose: Equatable {
    let environment: String
    /// Newlines plus the indented `\end{...}`.
    let insertion: String
}

/// An expansion for a Tab-triggered snippet. `range` and `caretOffset` are in
/// UTF-16 units, so they can be used directly with `NSTextView`.
struct SnippetExpansion: Equatable {
    let range: NSRange
    let insertion: String
    let caretOffset: Int
}

/// Local, LaTeX-aware editing help: closing an environment and expanding short
/// commands. Both functions are pure so the editor's behavior can be tested
/// without an `NSTextView`.
enum LaTeXAssistance {

    /// Marks where the caret should land inside a snippet body. A control
    /// character is used because it cannot occur accidentally in LaTeX.
    static let caretMarker = "\u{1}"

    private static let environmentPrefix = try! NSRegularExpression(
        pattern: #"^\s*\\begin\{([A-Za-z][A-Za-z0-9*]*)\}(\[[^\]\n]*\])?\s*$"#
    )

    /// Snippets are deliberately short and structural. They are triggered by
    /// Tab, never expanded while typing, so prose that happens to end in one of
    /// these words is left alone.
    static let snippets: [(trigger: String, body: String)] = [
        ("subsection", "\\subsection{\(caretMarker)}"),
        ("section", "\\section{\(caretMarker)}"),
        ("equation", "\\begin{equation}\n  \(caretMarker)\n\\end{equation}"),
        ("enumerate", "\\begin{enumerate}\n  \\item \(caretMarker)\n\\end{enumerate}"),
        ("itemize", "\\begin{itemize}\n  \\item \(caretMarker)\n\\end{itemize}"),
        ("textbf", "\\textbf{\(caretMarker)}"),
        ("table", """
        \\begin{table}[htbp]
          \\centering
          \\begin{tabular}{|l|l|}
            \\hline
            \(caretMarker) & \\\\
            \\hline
          \\end{tabular}
          \\caption{}
          \\label{tab:}
        \\end{table}
        """),
        ("align", "\\begin{align}\n  \(caretMarker)\n\\end{align}"),
        ("emph", "\\emph{\(caretMarker)}"),
        ("label", "\\label{\(caretMarker)}"),
        ("cite", "\\cite{\(caretMarker)}"),
        ("sqrt", "\\sqrt{\(caretMarker)}"),
        ("frac", "\\frac{\(caretMarker)}{}"),
        ("figure", """
        \\begin{figure}[htbp]
          \\centering
          \\includegraphics[width=\\linewidth]{\(caretMarker)}
          \\caption{}
          \\label{fig:}
        \\end{figure}
        """),
        ("ref", "\\ref{\(caretMarker)}"),
        ("fig", """
        \\begin{figure}[htbp]
          \\centering
          \\includegraphics[width=\\linewidth]{\(caretMarker)}
          \\caption{}
          \\label{fig:}
        \\end{figure}
        """),
        ("tab", """
        \\begin{table}[htbp]
          \\centering
          \\begin{tabular}{|l|l|}
            \\hline
            \(caretMarker) & \\\\
            \\hline
          \\end{tabular}
          \\caption{}
          \\label{tab:}
        \\end{table}
        """),
    ].sorted { $0.trigger.count > $1.trigger.count }

    /// Returns the environment to close when the caret sits at the end of a
    /// complete `\begin{...}` line. The line may carry optional arguments, and
    /// nothing but whitespace may follow the caret on that line.
    static func environmentClose(in text: String, caret: Int) -> EnvironmentClose? {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return nil }

        var lineStart = caret
        while lineStart > 0, source.character(at: lineStart - 1) != 10 {
            lineStart -= 1
        }
        let line = source.substring(
            with: NSRange(location: lineStart, length: caret - lineStart)
        )
        guard let environment = environmentName(inBeginLine: line) else { return nil }

        var lineEnd = caret
        while lineEnd < source.length, source.character(at: lineEnd) != 10 {
            lineEnd += 1
        }
        let tail = source.substring(
            with: NSRange(location: caret, length: lineEnd - caret)
        )
        guard tail.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // Do not add a second end when the block that follows already closes
        // this environment. Blank lines end the block, so an end further down
        // the document is not mistaken for the one this begin line wants.
        let remainder = source.substring(from: caret)
        let following = remainder.drop(while: { $0.isWhitespace })
        for line in following.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { break }
            if content.hasPrefix("\\end{\(environment)}") { return nil }
        }

        let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
        return EnvironmentClose(
            environment: environment,
            insertion: "\n\n\(indentation)\\end{\(environment)}"
        )
    }

    private static func environmentName(inBeginLine line: String) -> String? {
        let source = line as NSString
        guard let match = environmentPrefix.firstMatch(
            in: line, range: NSRange(location: 0, length: source.length)
        ), match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        return range.location == NSNotFound ? nil : source.substring(with: range)
    }

    /// Finds a snippet trigger immediately before the caret. A leading
    /// backslash is removed along with the trigger, so `\fig` and `fig` both
    /// expand to the same complete command.
    static func snippet(beforeCaret text: String) -> SnippetExpansion? {
        let source = text as NSString
        guard source.length > 0 else { return nil }

        var start = source.length
        while start > 0 {
            let character = source.character(at: start - 1)
            guard isWordCharacter(character) else { break }
            start -= 1
        }
        guard start < source.length else { return nil }

        let trigger = source.substring(
            with: NSRange(location: start, length: source.length - start)
        )
        guard let snippet = snippets.first(where: { $0.trigger == trigger }) else { return nil }

        var rangeStart = start
        if start > 0 {
            let before = source.character(at: start - 1)
            if before == ascii("\\") {
                rangeStart = start - 1
            } else if !isBoundary(before) {
                return nil
            }
        }

        // A word inside a comment is prose, not a command.
        if isInComment(at: rangeStart, in: source) { return nil }

        guard let marker = snippet.body.firstIndex(of: Character(caretMarker)) else {
            return nil
        }
        let beforeMarker = String(snippet.body[..<marker])
        let insertion = snippet.body.replacingOccurrences(of: caretMarker, with: "")
        return SnippetExpansion(
            range: NSRange(
                location: rangeStart,
                length: source.length - rangeStart
            ),
            insertion: insertion,
            caretOffset: (beforeMarker as NSString).length
        )
    }

    static func isWordCharacter(_ character: unichar) -> Bool {
        (character >= ascii("a") && character <= ascii("z"))
            || (character >= ascii("A") && character <= ascii("Z"))
            || (character >= ascii("0") && character <= ascii("9"))
    }

    private static func isBoundary(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
            || character == ascii("{") || character == ascii("[")
            || character == ascii("(") || character == ascii(",")
            || character == ascii(";") || character == ascii(":")
    }

    private static func isInComment(at location: Int, in source: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = source.character(at: index)
            if character == 10 { return false }
            if character == ascii("%") {
                var backslashes = 0
                var before = index - 1
                while before >= 0, source.character(at: before) == ascii("\\") {
                    backslashes += 1
                    before -= 1
                }
                return backslashes % 2 == 0
            }
            index -= 1
        }
        return false
    }

    private static func ascii(_ character: Character) -> unichar {
        unichar(character.asciiValue ?? 0)
    }
}
