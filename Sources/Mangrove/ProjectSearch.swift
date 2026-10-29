import Foundation

/// A file as the search engine sees it. Keeping this as a plain value makes the
/// engine testable without a working copy on disk.
struct SearchableFile: Equatable {
    let path: String
    let text: String
}

struct ProjectSearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
}

struct ProjectSearchHit: Identifiable, Equatable {
    let path: String
    let line: Int
    /// The match range within the whole file, for the editor jump.
    let range: NSRange
    let preview: String
    /// The match range within `preview`, for emphasis in the results list.
    let previewRange: NSRange

    var id: String { "\(path):\(range.location):\(range.length)" }
}

enum ProjectSearch {

    static let maxHits = 600

    static func hits(
        query: String,
        files: [SearchableFile],
        options: ProjectSearchOptions
    ) -> [ProjectSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let regex = expression(for: trimmed, options: options) else { return [] }

        var results: [ProjectSearchHit] = []
        for file in files {
            let source = file.text as NSString
            let matches = regex.matches(
                in: file.text, range: NSRange(location: 0, length: source.length)
            )
            for match in matches {
                let location = match.range.location
                let line = lineNumber(at: location, in: source)
                let preview = linePreview(
                    at: location, length: match.range.length, in: source
                )
                results.append(ProjectSearchHit(
                    path: file.path,
                    line: line,
                    range: match.range,
                    preview: preview.text,
                    previewRange: preview.range
                ))
                if results.count >= maxHits { return results }
            }
        }
        return results
    }

    /// Replaces every match in one file. Returns nil when nothing matched.
    static func replacing(
        in text: String,
        query: String,
        with replacement: String,
        options: ProjectSearchOptions
    ) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let regex = expression(for: trimmed, options: options) else {
            return nil
        }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    static func matchCount(
        query: String,
        in text: String,
        options: ProjectSearchOptions
    ) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let regex = expression(for: trimmed, options: options) else {
            return 0
        }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - Helpers

    private static func expression(
        for query: String,
        options: ProjectSearchOptions
    ) -> NSRegularExpression? {
        var pattern = NSRegularExpression.escapedPattern(for: query)
        // \b works for words that start or end with LaTeX punctuation badly, but
        // it is exactly the boundary people mean by "whole word" in prose.
        if options.wholeWord { pattern = "\\b" + pattern + "\\b" }
        return try? NSRegularExpression(
            pattern: pattern,
            options: options.caseSensitive ? [] : [.caseInsensitive]
        )
    }

    private static func lineNumber(at location: Int, in source: NSString) -> Int {
        var line = 1
        var index = 0
        while index < min(location, source.length) {
            if source.character(at: index) == 10 { line += 1 }
            index += 1
        }
        return line
    }

    /// The line around a match, windowed and trimmed for the results list. All
    /// offsets stay in UTF-16 so they can be used against the file directly.
    private static func linePreview(
        at location: Int, length: Int, in source: NSString
    ) -> (text: String, range: NSRange) {
        var start = 0
        var index = min(location, source.length) - 1
        while index >= 0 {
            if source.character(at: index) == 10 { start = index + 1; break }
            index -= 1
        }
        var end = start
        while end < source.length, source.character(at: end) != 10 { end += 1 }
        let full = source.substring(with: NSRange(location: start, length: end - start)) as NSString

        var leading = 0
        while leading < full.length,
              full.character(at: leading) == 32 || full.character(at: leading) == 9 {
            leading += 1
        }
        let localMatch = max(0, location - start - leading)
        let trimmed = full.substring(from: leading)
        let limit = 160

        guard trimmed.count > limit else {
            return (trimmed, NSRange(
                location: localMatch, length: min(length, max(0, trimmed.count - localMatch))
            ))
        }

        // Keep long lines readable: show a window around the match.
        let windowStart = max(0, min(localMatch - 60, trimmed.count - limit))
        let window = (trimmed as NSString).substring(with: NSRange(
            location: windowStart, length: min(limit, trimmed.count - windowStart)
        ))
        let prefix = windowStart > 0 ? "…" : ""
        let locationInWindow = localMatch - windowStart + prefix.count
        return (
            prefix + window + (windowStart + limit < trimmed.count ? "…" : ""),
            NSRange(location: locationInWindow, length: min(length, max(0, window.count - (localMatch - windowStart))))
        )
    }
}
