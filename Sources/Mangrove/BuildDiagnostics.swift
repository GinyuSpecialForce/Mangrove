import Foundation

/// One problem reported by a build, with enough location information to take
/// the reader to the line that caused it.
struct BuildDiagnostic: Identifiable, Equatable {
    enum Severity: Equatable {
        case error
        case warning
    }

    let id: UUID
    let severity: Severity
    let message: String
    /// Path relative to the project root, when the log made one available.
    let file: String?
    /// One-based line number.
    let line: Int?
    /// Extra context, such as the source line TeX echoed after the error.
    let detail: String?

    init(
        severity: Severity,
        message: String,
        file: String? = nil,
        line: Int? = nil,
        detail: String? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.detail = detail
    }

    var location: String? {
        guard let file else { return line.map { "line \($0)" } }
        guard let line else { return file }
        return "\(file):\(line)"
    }
}

/// Extracts errors and warnings from a TeX log.
///
/// LaTeX reports problems in a few different dialects: `!` blocks for TeX
/// errors, the `-file-line-error` form (`main.tex:42: …`), and warnings buried
/// in package chatter. The log is arranged for a terminal, not a parser, so this
/// reads the common forms and leaves anything it cannot recognise in the raw log
/// rather than guessing.
enum BuildLogParser {

    static func diagnostics(
        log: String,
        defaultFile: String?,
        knownFiles: Set<String> = [],
        validation: [String: Any]? = nil
    ) -> [BuildDiagnostic] {
        var results: [BuildDiagnostic] = []
        var currentFile = defaultFile
        var pending: Int?
        var pendingWarning: Int?

        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(rawLine)
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            if let hint = fileHint(in: text, knownFiles: knownFiles) {
                currentFile = hint
            }

            // Package warnings often wrap, with the line number on the next
            // line of the message.
            if let index = pendingWarning, results[index].line == nil,
               !trimmed.contains("Warning:"),
               let line = inputLineNumber(in: trimmed) {
                results[index] = BuildDiagnostic(
                    severity: results[index].severity,
                    message: results[index].message,
                    file: results[index].file,
                    line: line,
                    detail: results[index].detail,
                    id: results[index].id
                )
                pendingWarning = nil
            }

            // `l.42 \badcommand` follows an error and says where it happened.
            if let line = echoedLineNumber(trimmed) {
                if let index = pending, results[index].line == nil {
                    let detail = echoedSource(trimmed)
                    results[index] = BuildDiagnostic(
                        severity: results[index].severity,
                        message: results[index].message,
                        file: results[index].file,
                        line: line,
                        detail: detail,
                        id: results[index].id
                    )
                }
                pending = nil
                continue
            }

            if trimmed.hasPrefix("!") {
                pendingWarning = nil
                var message = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                // latexmk prints its own summary after the real error; it adds
                // nothing that is not already in the list.
                if message.hasPrefix("==> Fatal error") || message.hasPrefix("Emergency stop") {
                    continue
                }
                guard !message.isEmpty else { continue }
                if let range = message.range(of: "See the LaTeX manual") {
                    message = String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                let severity: BuildDiagnostic.Severity =
                    message.lowercased().contains("warning") ? .warning : .error
                pending = results.count
                results.append(BuildDiagnostic(
                    severity: severity,
                    message: clean(message),
                    file: currentFile
                ))
                continue
            }

            if let parsed = fileLineError(trimmed, knownFiles: knownFiles) {
                pendingWarning = nil
                pending = results.count
                results.append(parsed)
                continue
            }

            if let warning = warning(in: trimmed, file: currentFile) {
                pending = nil
                pendingWarning = warning.line == nil ? results.count : nil
                results.append(warning)
            }
        }

        if let validation {
            results.append(contentsOf: validationDiagnostics(validation, knownFiles: knownFiles))
        }

        return deduplicated(results)
    }

    // MARK: - Dialects

    /// `main.tex:42: Undefined control sequence.` — what latexmk and pdflatex
    /// print with `-file-line-error` (and what Overleaf sometimes returns).
    private static func fileLineError(
        _ line: String, knownFiles: Set<String>
    ) -> BuildDiagnostic? {
        guard let match = firstMatch(of: fileLinePattern, in: line) else { return nil }
        guard match.count >= 4 else { return nil }
        guard let lineNumber = Int(match[1]) else { return nil }
        guard let file = normalizeFile(match[0], knownFiles: knownFiles) else { return nil }
        var message = match[3].trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return nil }

        var severity: BuildDiagnostic.Severity = .error
        for prefix in ["error: ", "fatal error: ", "warning: "] {
            if message.lowercased().hasPrefix(prefix) {
                severity = prefix.hasPrefix("warning") ? .warning : .error
                message = String(message.dropFirst(prefix.count))
                break
            }
        }
        if message.lowercased().contains("warning") { severity = .warning }
        // latexmk announces a missing file twice; the second copy is noise.
        if message.lowercased().hasPrefix("latexmk:") { return nil }
        return BuildDiagnostic(
            severity: severity,
            message: clean(message),
            file: file,
            line: lineNumber
        )
    }

    private static func warning(in line: String, file: String?) -> BuildDiagnostic? {
        guard line.contains("Warning:") else { return nil }
        guard !line.hasPrefix("!") else { return nil }
        // Box warnings have no actionable location and can number in the hundreds.
        if line.contains("Overfull") || line.contains("Underfull") { return nil }
        if line.contains("pdfTeX warning (dest)") { return nil }

        var message = line
        if let range = message.range(of: "LaTeX Warning:") {
            message = String(message[range.upperBound...])
        } else if let range = message.range(of: "Warning:") {
            let prefix = message[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            message = prefix.isEmpty
                ? String(message[range.upperBound...])
                : "\(prefix): \(message[range.upperBound...])"
        }
        message = message.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return nil }

        let lineNumber = inputLineNumber(in: line)
        return BuildDiagnostic(
            severity: .warning,
            message: clean(message),
            file: file,
            line: lineNumber
        )
    }

    private static func validationDiagnostics(
        _ validation: [String: Any], knownFiles: Set<String>
    ) -> [BuildDiagnostic] {
        var results: [BuildDiagnostic] = []
        for (rawFile, value) in validation {
            guard let entries = value as? [[String: Any]] else { continue }
            let file = normalizeFile(rawFile, knownFiles: knownFiles)
            for entry in entries {
                guard let rawMessage = entry["message"] as? String, !rawMessage.isEmpty else { continue }
                let level = (entry["level"] as? String ?? entry["type"] as? String ?? "").lowercased()
                let severity: BuildDiagnostic.Severity =
                    level.contains("warn") ? .warning : .error
                let line = entry["row"] as? Int ?? entry["line"] as? Int
                results.append(BuildDiagnostic(
                    severity: severity,
                    message: clean(rawMessage),
                    file: file,
                    line: line
                ))
            }
        }
        return results
    }

    // MARK: - Scanning helpers

    // The path is lazy so that a build directory containing spaces still
    // matches; the `:line:` suffix anchors where the path really ends.
    private static let fileLinePattern = try! NSRegularExpression(
        pattern: #"^(.+?\.(?:tex|ltx|bib|sty|cls)):(\d+):(?:(\d+):)?\s*(.+)$"#
    )

    private static let texFilePattern = try! NSRegularExpression(
        pattern: #"\(([^()\s]+\.(?:tex|ltx))"#
    )

    private static let lineNumberPatterns = [
        try! NSRegularExpression(pattern: #"on input line (\d+)"#),
        try! NSRegularExpression(pattern: #"at line (\d+)"#),
        try! NSRegularExpression(pattern: #"at lines (\d+)"#),
    ]

    private static func firstMatch(
        of regex: NSRegularExpression, in string: String
    ) -> [String]? {
        let ns = string as NSString
        guard let match = regex.firstMatch(
            in: string, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }

        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
        }
        return groups
    }

    private static func echoedLineNumber(_ line: String) -> Int? {
        guard line.hasPrefix("l.") else { return nil }
        let rest = line.dropFirst(2)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func echoedSource(_ line: String) -> String? {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let source = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return source.isEmpty ? nil : String(source.prefix(180))
    }

    private static func inputLineNumber(in line: String) -> Int? {
        for regex in lineNumberPatterns {
            if let match = firstMatch(of: regex, in: line), let first = match.first, let number = Int(first) {
                return number
            }
        }
        return nil
    }

    /// The log opens files parenthetically; the most recent `.tex` is a useful
    /// default for `!` errors, which carry no filename of their own.
    private static func fileHint(in line: String, knownFiles: Set<String>) -> String? {
        let ns = line as NSString
        let matches = texFilePattern.matches(
            in: line, range: NSRange(location: 0, length: ns.length)
        )
        guard let match = matches.last, match.numberOfRanges > 1 else { return nil }
        return normalizeFile(ns.substring(with: match.range(at: 1)), knownFiles: knownFiles)
    }

    static func normalizeFile(_ raw: String, knownFiles: Set<String>) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]"))
        while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        guard !path.isEmpty else { return nil }

        if knownFiles.contains(path) { return path }
        // Absolute paths and Overleaf build directories differ per machine; the
        // tail is what identifies the file inside the project.
        let suffixMatches = knownFiles.filter { path.hasSuffix("/" + $0) }
        if let best = suffixMatches.max(by: { $0.count < $1.count }) { return best }

        let ext = (path as NSString).pathExtension.lowercased()
        guard ["tex", "ltx", "bib", "sty", "cls"].contains(ext) else { return nil }
        return path
    }

    private static func clean(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\u{1B}[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicated(_ items: [BuildDiagnostic]) -> [BuildDiagnostic] {
        var seen = Set<String>()
        var result: [BuildDiagnostic] = []
        for item in items {
            let key = "\(item.severity)|\(item.file ?? "")|\(item.line ?? -1)|\(item.message)"
            if seen.insert(key).inserted { result.append(item) }
        }
        return result
    }
}

extension Array where Element == BuildDiagnostic {
    var errorCount: Int { filter { $0.severity == .error }.count }
    var warningCount: Int { filter { $0.severity == .warning }.count }

    /// Errors first, each group in log order: the first problem is usually the
    /// cause and the rest are consequences.
    func orderedForDisplay() -> [BuildDiagnostic] {
        filter { $0.severity == .error } + filter { $0.severity == .warning }
    }
}
