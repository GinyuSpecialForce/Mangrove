import Foundation

/// What keys can be completed at the caret, and which command asked for them.
struct CompletionIndex: Equatable {
    var citationKeys: [String] = []
    var referenceKeys: [String] = []

    enum Kind: Equatable {
        case citation
        case reference
    }

    struct Request: Equatable {
        let kind: Kind
        /// The text already typed after the last comma.
        let partial: String
    }

    static let citationCommands: Set<String> = [
        "cite", "citep", "citet", "citealp", "citeauthor", "citeyear",
        "parencite", "Parencite", "textcite", "Textcite", "autocite",
        "Autocite", "footcite", "footcitetext", "supercite", "nocite",
    ]

    static let referenceCommands: Set<String> = [
        "ref", "eqref", "autoref", "pageref", "cref", "Cref",
        "labelcref", "nameref", "vref", "Vref",
    ]

    var isEmpty: Bool { citationKeys.isEmpty && referenceKeys.isEmpty }

    func suggestions(for kind: Kind) -> [String] {
        switch kind {
        case .citation: return citationKeys
        case .reference: return referenceKeys
        }
    }

    // MARK: - Building

    /// Keys of every ordinary bibliography entry. `@string`, `@preamble` and
    /// `@comment` blocks are not citations and are skipped.
    static func bibliographyKeys(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(
            pattern: "@([A-Za-z]+)\\s*[{(]\\s*([^,\\s}]+)"
        )
        let source = text as NSString
        var keys: [String] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let type = source.substring(with: match.range(at: 1)).lowercased()
            guard type != "string", type != "preamble", type != "comment" else { continue }
            let key = source.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// Labels declared in a document, in source order and without duplicates.
    static func labels(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\\\\label\\{([^{}]+)\\}")
        let source = text as NSString
        var labels: [String] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let label = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    /// Detects a `\cite{…` or `\ref{…` command that the caret is still inside.
    ///
    /// Every command is matched, not just the last one, because the caret can sit
    /// after a comma inside a list: `\cite{a,b|}`. Only the segment since the last
    /// comma is treated as the partial completion.
    static func request(before caret: String) -> Request? {
        let window = String(caret.suffix(400))
        let pattern = try! NSRegularExpression(
            pattern: "\\\\([A-Za-z]+)\\*?\\s*(?:\\[[^\\]]*\\]\\s*)*\\{([^{}]*)$"
        )
        let source = window as NSString
        guard let match = pattern.matches(
            in: window, range: NSRange(location: 0, length: source.length)
        ).last else { return nil }

        let command = source.substring(with: match.range(at: 1))
        let body = source.substring(with: match.range(at: 2))
        let partial = body.split(separator: ",", omittingEmptySubsequences: false)
            .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

        if citationCommands.contains(command) {
            return Request(kind: .citation, partial: partial)
        }
        if referenceCommands.contains(command) {
            return Request(kind: .reference, partial: partial)
        }
        return nil
    }
}
