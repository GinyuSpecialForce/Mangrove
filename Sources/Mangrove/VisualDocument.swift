import Foundation

// MARK: - Document model

/// The visual representation of one `.tex` file.
///
/// The source stays authoritative: each block remembers the exact range it came
/// from, so a visual edit rewrites only that range. Anything the parser cannot
/// model safely is shown as a read-only card with a way back to the source,
/// rather than being silently reinterpreted.
struct VisualDocument: Equatable {
    var title: String?
    var author: String?
    var date: String?
    var packageCount: Int
    var preambleRange: NSRange?
    var blocks: [VisualBlock]

    static let empty = VisualDocument(
        title: nil, author: nil, date: nil, packageCount: 0,
        preambleRange: nil, blocks: []
    )
}

struct VisualBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case listItem(ListMarker)
        case math
        case figure
        case table
        case verbatim
        case raw
        case command
    }

    enum ListMarker: Equatable {
        case bullet
        case number(Int)
        case label(String)
    }

    let id: Int
    let kind: Kind
    /// The whole construct, used for "Edit in code".
    let range: NSRange
    /// The part a visual edit replaces. Zero-length for read-only blocks.
    let editableRange: NSRange
    let editable: String?
    let source: String
    /// A short label: an environment name, a command summary, or a comment.
    let detail: String?
    let caption: String?
    let path: String?
}

// MARK: - Parser

enum VisualDocumentParser {

    private struct Line {
        let range: NSRange
        let text: String
    }

    private struct Command {
        let name: String
        let starred: Bool
        let end: Int
    }

    private struct Group {
        let content: NSRange
        let end: Int
    }

    private struct Environment {
        let name: String
        let end: Int
    }

    private struct ListItem {
        let start: Int
        let contentStart: Int
        var contentEnd: Int
        let label: String?
    }

    private static let headingLevels: [String: Int] = [
        "part": 0, "chapter": 0,
        "section": 1,
        "subsection": 2,
        "subsubsection": 3,
        "paragraph": 4, "subparagraph": 4,
    ]

    private static let mathEnvironments: Set<String> = [
        "equation", "align", "alignat", "flalign", "gather", "multline",
        "eqnarray", "displaymath", "math",
    ]

    private static let verbatimEnvironments: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "alltt",
    ]

    private static let standaloneCommands: Set<String> = [
        "tableofcontents", "listoffigures", "listoftables",
        "bibliography", "printbibliography", "addbibresource",
        "appendix", "newpage", "clearpage", "pagebreak",
        "input", "include",
    ]

    private static let skippedCommands: Set<String> = ["maketitle", "label"]

    // MARK: Entry point

    static func parse(_ text: String) -> VisualDocument {
        let source = text as NSString
        guard source.length > 0 else { return .empty }

        var bodyStart = 0
        var bodyEnd = source.length
        var preambleRange: NSRange?

        if let begin = find("\\begin{document}", in: source, from: 0, to: source.length) {
            preambleRange = NSRange(location: 0, length: begin.upperBound)
            var cursor = begin.upperBound
            while cursor < source.length, source.character(at: cursor) != 10 { cursor += 1 }
            bodyStart = min(cursor + 1, source.length)
            if let end = find("\\end{document}", in: source, from: bodyStart, to: source.length) {
                bodyEnd = end.location
            }
        }

        var title: String?
        var author: String?
        var date: String?
        var packageCount = 0
        if let preambleRange {
            let preambleText = source.substring(with: preambleRange)
            packageCount = occurrences(of: "\\usepackage", in: preambleText)
            title = groupContent(named: "title", in: preambleRange, source: source)
                .map { InlineLaTeX.plainText(in: source.substring(with: $0)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            author = groupContent(named: "author", in: preambleRange, source: source)
                .map { InlineLaTeX.plainText(in: source.substring(with: $0)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            date = groupContent(named: "date", in: preambleRange, source: source)
                .map { InlineLaTeX.plainText(in: source.substring(with: $0)) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        let lines = splitLines(in: source, from: bodyStart, to: bodyEnd)
        var blocks: [VisualBlock] = []
        var nextID = 0
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            guard !trimmed.isEmpty else {
                lineIndex += 1
                continue
            }

            // Comments are not content on the visual page; the source keeps them.
            if trimmed.hasPrefix("%") {
                lineIndex += 1
                continue
            }

            let contentStart = line.range.location + leadingWhitespace(in: line.text)

            if trimmed.hasPrefix("\\[") {
                if let end = find("\\]", in: source, from: contentStart + 2, to: bodyEnd) {
                    let closing = end.upperBound
                    let range = NSRange(location: contentStart, length: closing - contentStart)
                    blocks.append(VisualBlock(
                        id: nextID, kind: .math, range: range,
                        editableRange: NSRange(location: range.upperBound, length: 0),
                        editable: nil, source: source.substring(with: range),
                        detail: "display math", caption: nil, path: nil
                    ))
                    nextID += 1
                    lineIndex = advance(lineIndex, past: closing, lines: lines)
                    continue
                }
            }

            if trimmed.hasPrefix("$$") {
                if let end = find("$$", in: source, from: contentStart + 2, to: bodyEnd) {
                    let closing = end.upperBound
                    let range = NSRange(location: contentStart, length: closing - contentStart)
                    blocks.append(VisualBlock(
                        id: nextID, kind: .math, range: range,
                        editableRange: NSRange(location: range.upperBound, length: 0),
                        editable: nil, source: source.substring(with: range),
                        detail: "display math", caption: nil, path: nil
                    ))
                    nextID += 1
                    lineIndex = advance(lineIndex, past: closing, lines: lines)
                    continue
                }
            }

            guard let command = command(at: contentStart, in: source, limit: bodyEnd) else {
                let result = paragraphBlock(
                    startingAt: lineIndex, lines: lines, source: source,
                    bodyEnd: bodyEnd, nextID: nextID
                )
                blocks.append(result.block)
                nextID += 1
                lineIndex = result.nextLine
                continue
            }

            // Standalone labels and \maketitle are metadata, not content.
            if skippedCommands.contains(command.name),
               consumesLine(command: command, lineEnd: line.range.upperBound, source: source, limit: bodyEnd) {
                lineIndex += 1
                continue
            }

            if let level = headingLevels[command.name],
               let group = firstGroup(after: command.end, in: source, limit: bodyEnd) {
                let range = NSRange(location: contentStart, length: group.end - contentStart)
                blocks.append(VisualBlock(
                    id: nextID, kind: .heading(level: level), range: range,
                    editableRange: group.content,
                    editable: source.substring(with: group.content),
                    source: source.substring(with: range),
                    detail: nil, caption: nil, path: nil
                ))
                nextID += 1
                lineIndex = advance(lineIndex, past: group.end, lines: lines)
                continue
            }

            if command.name == "begin",
               let environment = environmentName(after: command.end, in: source, limit: bodyEnd),
               let end = findEnvironmentEnd(name: environment.name, from: environment.end, source: source, limit: bodyEnd) {

                let envRange = NSRange(location: contentStart, length: end.end - contentStart)
                let normalized = normalizeEnvironment(environment.name)
                var handled = true

                if ["itemize", "enumerate", "description"].contains(normalized.lowercased()) {
                    let items = listBlocks(
                        environmentName: environment.name,
                        beginEnd: environment.end,
                        endStart: end.start,
                        source: source,
                        firstID: nextID
                    )
                    if items.isEmpty {
                        handled = false
                    } else {
                        blocks.append(contentsOf: items)
                        nextID += items.count
                    }
                } else if mathEnvironments.contains(normalized.lowercased()) {
                    blocks.append(VisualBlock(
                        id: nextID, kind: .math, range: envRange,
                        editableRange: NSRange(location: envRange.upperBound, length: 0),
                        editable: nil, source: source.substring(with: envRange),
                        detail: environment.name, caption: nil, path: nil
                    ))
                    nextID += 1
                } else if normalized.lowercased().hasPrefix("figure") {
                    blocks.append(figureBlock(
                        id: nextID, envRange: envRange, source: source, isTable: false
                    ))
                    nextID += 1
                } else if normalized.lowercased().hasPrefix("table") {
                    blocks.append(figureBlock(
                        id: nextID, envRange: envRange, source: source, isTable: true
                    ))
                    nextID += 1
                } else if verbatimEnvironments.contains(normalized) {
                    blocks.append(VisualBlock(
                        id: nextID, kind: .verbatim, range: envRange,
                        editableRange: NSRange(location: envRange.upperBound, length: 0),
                        editable: nil, source: source.substring(with: envRange),
                        detail: environment.name, caption: nil, path: nil
                    ))
                    nextID += 1
                } else {
                    handled = false
                }

                if !handled {
                    blocks.append(VisualBlock(
                        id: nextID, kind: .raw, range: envRange,
                        editableRange: NSRange(location: envRange.upperBound, length: 0),
                        editable: nil, source: source.substring(with: envRange),
                        detail: environment.name, caption: nil, path: nil
                    ))
                    nextID += 1
                }

                lineIndex = advance(lineIndex, past: end.end, lines: lines)
                continue
            }

            if standaloneCommands.contains(command.name),
               consumesLine(command: command, lineEnd: line.range.upperBound, source: source, limit: bodyEnd) {
                let range = NSRange(location: contentStart, length: line.range.upperBound - contentStart)
                let sourceText = source.substring(with: range).trimmingCharacters(in: .whitespaces)
                blocks.append(VisualBlock(
                    id: nextID, kind: .command, range: range,
                    editableRange: NSRange(location: range.upperBound, length: 0),
                    editable: nil, source: sourceText,
                    detail: commandDetail(for: command, source: source, limit: bodyEnd),
                    caption: nil, path: includePath(for: command, source: source, limit: bodyEnd)
                ))
                nextID += 1
                lineIndex += 1
                continue
            }

            // A command that owns its line but is not a structure we model is
            // shown as a chip, which is safer than hiding it in prose.
            if consumesLine(command: command, lineEnd: line.range.upperBound, source: source, limit: bodyEnd),
               !["begin", "end", "item"].contains(command.name) {
                let range = NSRange(location: contentStart, length: line.range.upperBound - contentStart)
                let sourceText = source.substring(with: range).trimmingCharacters(in: .whitespaces)
                blocks.append(VisualBlock(
                    id: nextID, kind: .command, range: range,
                    editableRange: NSRange(location: range.upperBound, length: 0),
                    editable: nil, source: sourceText,
                    detail: shorten(sourceText, 64), caption: nil, path: nil
                ))
                nextID += 1
                lineIndex += 1
                continue
            }

            let result = paragraphBlock(
                startingAt: lineIndex, lines: lines, source: source,
                bodyEnd: bodyEnd, nextID: nextID
            )
            blocks.append(result.block)
            nextID += 1
            lineIndex = result.nextLine
        }

        return VisualDocument(
            title: title, author: author, date: date,
            packageCount: packageCount, preambleRange: preambleRange, blocks: blocks
        )
    }

    // MARK: Blocks

    private static func paragraphBlock(
        startingAt lineIndex: Int,
        lines: [Line],
        source: NSString,
        bodyEnd: Int,
        nextID: Int
    ) -> (block: VisualBlock, nextLine: Int) {
        let first = lines[lineIndex]
        let contentStart = first.range.location + leadingWhitespace(in: first.text)
        var end = first.range.upperBound
        var cursor = lineIndex + 1

        while cursor < lines.count {
            let next = lines[cursor]
            let trimmed = next.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            let nextStart = next.range.location + leadingWhitespace(in: next.text)
            if beginsBlock(at: nextStart, source: source, limit: bodyEnd) { break }
            if isLabelOnlyLine(at: nextStart, source: source, lineEnd: next.range.upperBound) { break }
            end = next.range.upperBound
            cursor += 1
        }

        let fullRange = NSRange(location: first.range.location, length: end - first.range.location)
        let editableRange = trimmingTrailingWhitespace(
            NSRange(location: contentStart, length: max(0, end - contentStart)),
            in: source
        )
        let editable = editableRange.length > 0 ? source.substring(with: editableRange) : ""
        let fullSource = source.substring(with: fullRange)

        let unsafe = editable.contains("\\begin{")
            || editable.contains("\\end{")
            || editable.contains("\\verb")
            || editable.contains("\\item")

        if unsafe {
            return (VisualBlock(
                id: nextID, kind: .raw, range: fullRange,
                editableRange: NSRange(location: fullRange.upperBound, length: 0),
                editable: nil, source: fullSource,
                detail: "markup", caption: nil, path: nil
            ), cursor)
        }

        return (VisualBlock(
            id: nextID, kind: .paragraph, range: fullRange,
            editableRange: editableRange, editable: editable,
            source: fullSource, detail: nil, caption: nil, path: nil
        ), cursor)
    }

    private static func listBlocks(
        environmentName: String,
        beginEnd: Int,
        endStart: Int,
        source: NSString,
        firstID: Int
    ) -> [VisualBlock] {
        let body = NSRange(location: beginEnd, length: max(0, endStart - beginEnd))
        // A nested list inside an item turns the whole environment into a card:
        // rewriting an item would otherwise flatten its contents.
        if find("\\begin{", in: source, from: body.location, to: body.upperBound) != nil {
            return []
        }

        var items: [ListItem] = []
        var cursor = body.location
        while let found = find("\\item", in: source, from: cursor, to: body.upperBound) {
            var after = found.upperBound
            if after < source.length, isCommandLetter(source.character(at: after)) {
                cursor = after
                continue
            }

            var contentStart = after
            while contentStart < body.upperBound, isWhitespace(source.character(at: contentStart)) {
                contentStart += 1
            }

            var label: String?
            if contentStart < body.upperBound, source.character(at: contentStart) == 91,
               let end = bracketEnd(at: contentStart, in: source, limit: body.upperBound) {
                let labelRange = NSRange(location: contentStart + 1, length: end - contentStart - 2)
                label = InlineLaTeX.plainText(in: source.substring(with: labelRange))
                contentStart = end
                while contentStart < body.upperBound, isWhitespace(source.character(at: contentStart)) {
                    contentStart += 1
                }
            }
            after = max(after, contentStart)
            items.append(ListItem(
                start: found.location, contentStart: contentStart,
                contentEnd: contentStart, label: label
            ))
            cursor = after
        }

        guard !items.isEmpty else { return [] }

        for index in items.indices {
            let end = index + 1 < items.count ? items[index + 1].start : body.upperBound
            let trimmed = trimmingTrailingWhitespace(
                NSRange(location: items[index].contentStart, length: max(0, end - items[index].contentStart)),
                in: source
            )
            items[index].contentEnd = max(trimmed.upperBound, items[index].contentStart)
        }

        let isEnumerated = normalizeEnvironment(environmentName).lowercased() == "enumerate"
        let isDescription = normalizeEnvironment(environmentName).lowercased() == "description"

        return items.enumerated().map { offset, item in
            let marker: VisualBlock.ListMarker
            if isEnumerated {
                marker = .number(offset + 1)
            } else if isDescription, let label = item.label, !label.isEmpty {
                marker = .label(label)
            } else {
                marker = .bullet
            }

            let editableRange = NSRange(
                location: item.contentStart,
                length: item.contentEnd - item.contentStart
            )
            let fullRange = NSRange(
                location: item.start,
                length: max(0, item.contentEnd - item.start)
            )
            let editable = source.substring(with: editableRange)

            // A blank line inside an item means several paragraphs. One text
            // view would flatten them on the first edit, so leave the item to the
            // source rather than lose structure silently.
            let hasBlankLine = editable.range(
                of: #"\n[ \t]*\n"#, options: .regularExpression
            ) != nil
            if hasBlankLine {
                return VisualBlock(
                    id: firstID + offset, kind: .raw, range: fullRange,
                    editableRange: NSRange(location: fullRange.upperBound, length: 0),
                    editable: nil,
                    source: source.substring(with: fullRange),
                    detail: "list item", caption: nil, path: nil
                )
            }

            return VisualBlock(
                id: firstID + offset, kind: .listItem(marker), range: fullRange,
                editableRange: editableRange,
                editable: editable,
                source: source.substring(with: fullRange),
                detail: isDescription ? "description" : nil, caption: nil, path: nil
            )
        }
    }

    private static func figureBlock(
        id: Int,
        envRange: NSRange,
        source: NSString,
        isTable: Bool
    ) -> VisualBlock {
        let captionRange = groupContent(named: "caption", in: envRange, source: source)
        let caption = captionRange
            .map { InlineLaTeX.plainText(in: source.substring(with: $0)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let graphicsRange = groupContent(named: "includegraphics", in: envRange, source: source)
        let path = graphicsRange.map { source.substring(with: $0).trimmingCharacters(in: .whitespaces) }
        return VisualBlock(
            id: id, kind: isTable ? .table : .figure, range: envRange,
            editableRange: NSRange(location: envRange.upperBound, length: 0),
            editable: nil, source: source.substring(with: envRange),
            detail: nil, caption: caption, path: path
        )
    }

    // MARK: Line scanning

    private static func splitLines(in source: NSString, from start: Int, to end: Int) -> [Line] {
        var lines: [Line] = []
        var cursor = start
        while cursor < end {
            let lineEnd = self.lineEnd(from: cursor, in: source, limit: end)
            let range = NSRange(location: cursor, length: lineEnd - cursor)
            lines.append(Line(range: range, text: source.substring(with: range)))
            cursor = lineEnd < end ? lineEnd + 1 : end
        }
        return lines
    }

    private static func advance(_ lineIndex: Int, past end: Int, lines: [Line]) -> Int {
        var index = lineIndex
        while index < lines.count, lines[index].range.location < end {
            index += 1
        }
        return max(index, lineIndex + 1)
    }

    private static func beginsBlock(at index: Int, source: NSString, limit: Int) -> Bool {
        guard index < limit else { return false }
        if source.character(at: index) == 37 { return true } // %
        let two = NSRange(location: index, length: min(2, limit - index))
        let prefix = source.substring(with: two)
        if prefix.hasPrefix("\\[") || prefix.hasPrefix("$$") { return true }
        guard let command = command(at: index, in: source, limit: limit) else { return false }
        if headingLevels[command.name] != nil { return true }
        if ["begin", "end", "item"].contains(command.name) { return true }
        return standaloneCommands.contains(command.name) || skippedCommands.contains(command.name)
    }

    private static func isLabelOnlyLine(at index: Int, source: NSString, lineEnd: Int) -> Bool {
        guard let command = command(at: index, in: source, limit: lineEnd),
              command.name == "label" else { return false }
        return consumesLine(command: command, lineEnd: lineEnd, source: source, limit: lineEnd)
    }

    private static func consumesLine(
        command: Command, lineEnd: Int, source: NSString, limit: Int
    ) -> Bool {
        var cursor = command.end
        while true {
            while cursor < lineEnd, isHorizontalSpace(source.character(at: cursor)) { cursor += 1 }
            guard cursor < lineEnd else { return true }
            if source.character(at: cursor) == 91 {
                guard let end = bracketEnd(at: cursor, in: source, limit: lineEnd) else { return false }
                cursor = end
            } else if source.character(at: cursor) == 123 {
                guard let group = group(at: cursor, in: source, limit: lineEnd) else { return false }
                cursor = group.end
            } else {
                break
            }
        }
        while cursor < lineEnd, isHorizontalSpace(source.character(at: cursor)) { cursor += 1 }
        if cursor >= lineEnd { return true }
        return source.character(at: cursor) == 37
    }

    // MARK: Lexical helpers

    private static func command(at index: Int, in source: NSString, limit: Int) -> Command? {
        guard index < limit, source.character(at: index) == 92 else { return nil }
        var cursor = index + 1
        guard cursor < limit, isCommandLetter(source.character(at: cursor)) else { return nil }
        while cursor < limit, isCommandLetter(source.character(at: cursor)) { cursor += 1 }
        let nameRange = NSRange(location: index + 1, length: cursor - index - 1)
        var starred = false
        if cursor < limit, source.character(at: cursor) == 42 {
            starred = true
            cursor += 1
        }
        return Command(
            name: source.substring(with: nameRange),
            starred: starred,
            end: cursor
        )
    }

    private static func environmentName(after index: Int, in source: NSString, limit: Int) -> Environment? {
        guard let group = firstGroup(after: index, in: source, limit: limit) else { return nil }
        let name = source.substring(with: group.content)
        guard !name.isEmpty, !name.contains("\\") else { return nil }
        return Environment(name: name, end: group.end)
    }

    private static func findEnvironmentEnd(
        name: String, from index: Int, source: NSString, limit: Int
    ) -> (start: Int, end: Int)? {
        guard let found = find("\\end{\(name)}", in: source, from: index, to: limit) else { return nil }
        return (found.location, found.upperBound)
    }

    private static func firstGroup(after index: Int, in source: NSString, limit: Int) -> Group? {
        var cursor = index
        while cursor < limit {
            let character = source.character(at: cursor)
            if character == 32 || character == 9 || character == 10 {
                cursor += 1
                continue
            }
            if character == 91 {
                guard let end = bracketEnd(at: cursor, in: source, limit: limit) else { return nil }
                cursor = end
                continue
            }
            break
        }
        return group(at: cursor, in: source, limit: limit)
    }

    private static func group(at index: Int, in source: NSString, limit: Int) -> Group? {
        guard index < limit, source.character(at: index) == 123 else { return nil }
        var depth = 0
        var cursor = index
        while cursor < limit {
            let character = source.character(at: cursor)
            if character == 92 {
                cursor += 2
                continue
            }
            if character == 123 { depth += 1 }
            if character == 125 {
                depth -= 1
                if depth == 0 {
                    return Group(
                        content: NSRange(location: index + 1, length: cursor - index - 1),
                        end: cursor + 1
                    )
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func bracketEnd(at index: Int, in source: NSString, limit: Int) -> Int? {
        guard index < limit, source.character(at: index) == 91 else { return nil }
        var depth = 0
        var cursor = index
        while cursor < limit {
            let character = source.character(at: cursor)
            if character == 92 {
                cursor += 2
                continue
            }
            if character == 91 { depth += 1 }
            if character == 93 {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }

    private static func groupContent(
        named name: String, in range: NSRange, source: NSString
    ) -> NSRange? {
        var cursor = range.location
        while let found = find("\\" + name, in: source, from: cursor, to: range.upperBound) {
            let after = found.upperBound
            if after < range.upperBound, isCommandLetter(source.character(at: after)) {
                cursor = after
                continue
            }
            if let group = firstGroup(after: after, in: source, limit: range.upperBound) {
                return group.content
            }
            cursor = after
        }
        return nil
    }

    private static func find(
        _ needle: String, in source: NSString, from start: Int, to end: Int
    ) -> NSRange? {
        guard start >= 0, end <= source.length, start < end else { return nil }
        let range = source.range(
            of: needle, options: [],
            range: NSRange(location: start, length: end - start)
        )
        return range.location == NSNotFound ? nil : range
    }

    private static func lineEnd(from index: Int, in source: NSString, limit: Int) -> Int {
        var cursor = max(0, min(index, limit))
        while cursor < limit, source.character(at: cursor) != 10 { cursor += 1 }
        return cursor
    }

    private static func trimmingTrailingWhitespace(_ range: NSRange, in source: NSString) -> NSRange {
        var end = range.upperBound
        while end > range.location, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: range.location, length: end - range.location)
    }

    private static func leadingWhitespace(in text: String) -> Int {
        text.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
    }

    private static func isHorizontalSpace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private static func isCommandLetter(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90)
            || (character >= 97 && character <= 122)
            || character == 64
    }

    private static func normalizeEnvironment(_ name: String) -> String {
        name.hasSuffix("*") ? String(name.dropLast()) : name
    }

    private static func commandDetail(
        for command: Command, source: NSString, limit: Int
    ) -> String {
        switch command.name {
        case "tableofcontents": return "Table of contents"
        case "listoffigures": return "List of figures"
        case "listoftables": return "List of tables"
        case "bibliography", "printbibliography", "addbibresource":
            if let group = firstGroup(after: command.end, in: source, limit: limit) {
                let path = source.substring(with: group.content)
                return "Bibliography · \(path)"
            }
            return "Bibliography"
        case "appendix": return "Appendix"
        case "newpage", "clearpage", "pagebreak": return "Page break"
        case "input", "include":
            if let group = firstGroup(after: command.end, in: source, limit: limit) {
                let path = source.substring(with: group.content)
                return "Include · \(path)"
            }
            return "Include"
        default:
            return command.name
        }
    }

    private static func includePath(
        for command: Command, source: NSString, limit: Int
    ) -> String? {
        guard command.name == "input" || command.name == "include" else { return nil }
        guard let group = firstGroup(after: command.end, in: source, limit: limit) else { return nil }
        var path = source.substring(with: group.content).trimmingCharacters(in: .whitespaces)
        if (path as NSString).pathExtension.isEmpty { path += ".tex" }
        return path
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    private static func shorten(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard single.count > limit else { return single }
        return String(single.prefix(limit - 1)) + "…"
    }
}

// MARK: - Editing model

/// Holds the parsed document and keeps block ranges in step while a block is
/// being edited. The blocks are only re-published when editing finishes: a
/// re-parse on every keystroke would replace the text view under the caret.
@MainActor
final class VisualDocumentModel: ObservableObject {
    @Published private(set) var document = VisualDocument.empty
    private(set) var source = ""
    private(set) var activeBlock: Int?

    private var blockRanges: [NSRange] = []
    private var editableRanges: [NSRange] = []
    private var refreshTask: Task<Void, Never>?
    private var onChange: ((String) -> Void)?

    var isEditing: Bool { activeBlock != nil }

    func load(_ text: String) {
        refreshTask?.cancel()
        activeBlock = nil
        source = text
        let parsed = VisualDocumentParser.parse(text)
        document = parsed
        blockRanges = parsed.blocks.map(\.range)
        editableRanges = parsed.blocks.map(\.editableRange)
    }

    func setTextHandler(_ handler: @escaping (String) -> Void) {
        onChange = handler
    }

    func beginEditing(_ index: Int) {
        refreshTask?.cancel()
        activeBlock = index
    }

    /// Re-parses shortly after focus leaves. The delay lets a click that moves
    /// between two blocks settle, so the next text view is not torn down while
    /// it is becoming first responder.
    func endEditing(_ index: Int) {
        guard activeBlock == index else { return }
        activeBlock = nil
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, self.activeBlock == nil else { return }
            self.refresh()
        }
    }

    func update(_ index: Int, with latex: String) {
        guard index >= 0, index < editableRanges.count else { return }
        let range = editableRanges[index]
        let sourceLength = (source as NSString).length
        guard range.location <= sourceLength, range.upperBound <= sourceLength else { return }

        let replacement = latex as NSString
        source = (source as NSString).replacingCharacters(in: range, with: latex)
        let delta = replacement.length - range.length

        editableRanges[index] = NSRange(location: range.location, length: replacement.length)
        blockRanges[index] = NSRange(
            location: blockRanges[index].location,
            length: max(0, blockRanges[index].length + delta)
        )
        if index + 1 < editableRanges.count {
            for later in (index + 1)..<editableRanges.count {
                editableRanges[later].location += delta
                blockRanges[later].location += delta
            }
        }
        onChange?(source)
    }

    func currentRange(for index: Int) -> NSRange {
        guard index >= 0, index < blockRanges.count else { return NSRange(location: 0, length: 0) }
        return blockRanges[index]
    }

    func currentEditableRange(for index: Int) -> NSRange {
        guard index >= 0, index < editableRanges.count else { return NSRange(location: 0, length: 0) }
        return editableRanges[index]
    }

    /// Drops a pending re-parse, e.g. when the editor is leaving the screen.
    func commitNow() {
        refreshTask?.cancel()
        activeBlock = nil
        refresh()
    }

    private func refresh() {
        let parsed = VisualDocumentParser.parse(source)
        document = parsed
        blockRanges = parsed.blocks.map(\.range)
        editableRanges = parsed.blocks.map(\.editableRange)
    }
}
