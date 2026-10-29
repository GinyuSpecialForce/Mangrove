import Foundation

/// Local writing checks for the file being edited.
///
/// The built-in pass catches mistakes that do not need a TeX installation:
/// unbalanced braces, environments that are never closed (or close the wrong
/// environment), duplicate labels, and references or citations with no matching
/// target. When `chktex` is installed, its typographic warnings are folded in as
/// well. Linting never compiles and never touches the network.
enum LaTeXLint {

    static let maxDiagnostics = 80

    // MARK: - Public entry points

    static func chktexExecutable(fileManager: FileManager = .default) -> URL? {
        var directories = LocalLaTeX.searchDirectories(fileManager: fileManager)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        directories += path.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        return chktexExecutable(in: directories, fileManager: fileManager)
    }

    /// Separated so the search can be tested with a temporary directory.
    static func chktexExecutable(
        in directories: [URL], fileManager: FileManager = .default
    ) -> URL? {
        var seen = Set<String>()
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            let candidate = standardized.appendingPathComponent("chktex")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func diagnostics(
        text: String,
        file: String,
        knownReferences: Set<String>,
        knownCitations: Set<String>,
        chktex: URL?
    ) async -> [BuildDiagnostic] {
        let local = await Task.detached(priority: .utility) {
            builtInDiagnostics(
                text: text,
                file: file,
                knownReferences: knownReferences,
                knownCitations: knownCitations
            )
        }.value

        guard let chktex else { return limited(local) }
        let external = await runChkTeX(text: text, file: file, executable: chktex)
        return limited(local + external)
    }

    // MARK: - Built-in checks

    static func builtInDiagnostics(
        text: String,
        file: String,
        knownReferences: Set<String> = [],
        knownCitations: Set<String> = []
    ) -> [BuildDiagnostic] {
        let source = text as NSString
        var results: [BuildDiagnostic] = []
        results.append(contentsOf: braceDiagnostics(in: source, file: file))
        results.append(contentsOf: environmentDiagnostics(in: source, file: file))
        results.append(contentsOf: labelDiagnostics(in: source, file: file))
        results.append(contentsOf: referenceDiagnostics(
            in: source, file: file, known: knownReferences
        ))
        results.append(contentsOf: citationDiagnostics(
            in: source, file: file, known: knownCitations
        ))
        return limited(results)
    }

    private static func braceDiagnostics(
        in source: NSString, file: String
    ) -> [BuildDiagnostic] {
        let starts = lineStarts(in: source)
        var results: [BuildDiagnostic] = []
        var stack: [Int] = []
        var index = 0

        while index < source.length {
            let character = source.character(at: index)
            if character == 10 {
                index += 1
                continue
            }
            if character == ascii("%") {
                if !isEscaped(index, in: source) {
                    while index < source.length, source.character(at: index) != 10 {
                        index += 1
                    }
                    continue
                }
            }
            if character == ascii("\\") {
                index = min(index + 2, source.length)
                continue
            }
            if character == ascii("{") {
                stack.append(index)
            } else if character == ascii("}") {
                if stack.isEmpty {
                    results.append(BuildDiagnostic(
                        severity: .error,
                        message: "Unmatched closing brace.",
                        file: file,
                        line: lineNumber(at: index, starts: starts),
                        detail: "syntax check"
                    ))
                } else {
                    stack.removeLast()
                }
            }
            index += 1
        }

        for open in stack.prefix(8) {
            results.append(BuildDiagnostic(
                severity: .error,
                message: "Unclosed brace opened here.",
                file: file,
                line: lineNumber(at: open, starts: starts),
                detail: "syntax check"
            ))
        }
        return results
    }

    private static func environmentDiagnostics(
        in source: NSString, file: String
    ) -> [BuildDiagnostic] {
        let starts = lineStarts(in: source)
        let matches = environmentPattern.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        )
        var stack: [(name: String, line: Int)] = []
        var results: [BuildDiagnostic] = []

        for match in matches {
            guard !isCommented(at: match.range.location, in: source) else { continue }
            guard match.numberOfRanges > 2 else { continue }
            let kind = source.substring(with: match.range(at: 1))
            let name = source.substring(with: match.range(at: 2))
            let line = lineNumber(at: match.range.location, starts: starts)

            // Verbatim bodies are literal text; only their own end counts.
            if let top = stack.last,
               ["verbatim", "lstlisting", "minted"].contains(top.name),
               !(kind == "end" && name == top.name) {
                continue
            }

            if kind == "begin" {
                stack.append((name, line))
                continue
            }

            if stack.last?.name == name {
                stack.removeLast()
            } else if let index = stack.lastIndex(where: { $0.name == name }) {
                let expected = stack.last?.name ?? name
                results.append(BuildDiagnostic(
                    severity: .error,
                    message: "\\end{\(name)} does not match the open \\begin{\(expected)}.",
                    file: file,
                    line: line,
                    detail: "syntax check"
                ))
                stack.removeSubrange(index...)
            } else {
                results.append(BuildDiagnostic(
                    severity: .error,
                    message: "\\end{\(name)} has no matching \\begin.",
                    file: file,
                    line: line,
                    detail: "syntax check"
                ))
            }
        }

        for open in stack.prefix(8) {
            results.append(BuildDiagnostic(
                severity: .error,
                message: "\\begin{\(open.name)} is never closed.",
                file: file,
                line: open.line,
                detail: "syntax check"
            ))
        }
        return results
    }

    private static func labelDiagnostics(
        in source: NSString, file: String
    ) -> [BuildDiagnostic] {
        let starts = lineStarts(in: source)
        let matches = labelPattern.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        )
        var firstLines: [String: Int] = [:]
        var results: [BuildDiagnostic] = []

        for match in matches {
            guard !isCommented(at: match.range.location, in: source) else { continue }
            let label = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            let line = lineNumber(at: match.range.location, starts: starts)
            if let first = firstLines[label] {
                results.append(BuildDiagnostic(
                    severity: .warning,
                    message: "Duplicate label “\(label)” (first defined on line \(first)).",
                    file: file,
                    line: line,
                    detail: "label check"
                ))
            } else {
                firstLines[label] = line
            }
        }
        return results
    }

    private static func referenceDiagnostics(
        in source: NSString, file: String, known: Set<String>
    ) -> [BuildDiagnostic] {
        guard !known.isEmpty else { return [] }
        let starts = lineStarts(in: source)
        let matches = referencePattern.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        )
        var reported = Set<String>()
        var results: [BuildDiagnostic] = []

        for match in matches {
            guard !isCommented(at: match.range.location, in: source) else { continue }
            let keys = source.substring(with: match.range(at: 1))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for key in keys where !key.isEmpty && !known.contains(key) {
                guard reported.insert(key).inserted else { continue }
                results.append(BuildDiagnostic(
                    severity: .warning,
                    message: "Reference “\(key)” has no matching \\label.",
                    file: file,
                    line: lineNumber(at: match.range.location, starts: starts),
                    detail: "reference check"
                ))
            }
        }
        return results
    }

    private static func citationDiagnostics(
        in source: NSString, file: String, known: Set<String>
    ) -> [BuildDiagnostic] {
        guard !known.isEmpty else { return [] }
        let starts = lineStarts(in: source)
        let matches = citationPattern.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        )
        var reported = Set<String>()
        var results: [BuildDiagnostic] = []

        for match in matches {
            guard !isCommented(at: match.range.location, in: source) else { continue }
            let keys = source.substring(with: match.range(at: 1))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for key in keys where !key.isEmpty && !known.contains(key) {
                guard reported.insert(key).inserted else { continue }
                results.append(BuildDiagnostic(
                    severity: .warning,
                    message: "Citation “\(key)” is not in a .bib file.",
                    file: file,
                    line: lineNumber(at: match.range.location, starts: starts),
                    detail: "citation check"
                ))
            }
        }
        return results
    }

    // MARK: - ChkTeX

    /// Runs ChkTeX on a temporary copy so unsaved edits are checked too. The
    /// temporary path is dropped from the result: diagnostics belong to the real
    /// file the reader has open.
    static func runChkTeX(
        text: String, file: String, executable: URL
    ) async -> [BuildDiagnostic] {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let directory = manager.temporaryDirectory
            let stem = "mangrove-lint-\(UUID().uuidString)"
            let sourceURL = directory.appendingPathComponent(stem + ".tex")
            let outputURL = directory.appendingPathComponent(stem + ".out")
            defer {
                try? manager.removeItem(at: sourceURL)
                try? manager.removeItem(at: outputURL)
            }

            guard (try? text.write(to: sourceURL, atomically: true, encoding: .utf8)) != nil else {
                return []
            }
            manager.createFile(atPath: outputURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: outputURL) else { return [] }
            defer { try? handle.close() }

            let process = Process()
            process.executableURL = executable
            process.arguments = [sourceURL.path]
            process.standardOutput = handle
            process.standardError = handle

            var environment = ProcessInfo.processInfo.environment
            let toolDirectory = executable.deletingLastPathComponent().path
            let path = environment["PATH"] ?? "/usr/bin:/bin"
            if !path.split(separator: ":").contains(Substring(toolDirectory)) {
                environment["PATH"] = toolDirectory + ":" + path
            }
            process.environment = environment

            do {
                try process.run()
            } catch {
                return []
            }
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                return []
            }
            try? handle.close()

            guard let output = try? String(contentsOf: outputURL, encoding: .utf8) else {
                return []
            }
            return parseChkTeX(output, file: file)
        }.value
    }

    static func parseChkTeX(_ output: String, file: String) -> [BuildDiagnostic] {
        var results: [BuildDiagnostic] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = clean(String(rawLine))
            guard !line.isEmpty else { continue }
            guard let parsed = chktexMatch(in: line) else { continue }
            results.append(BuildDiagnostic(
                severity: parsed.severity,
                message: parsed.message,
                file: file,
                line: parsed.line,
                detail: "chktex"
            ))
        }
        return limited(results)
    }

    private static func chktexMatch(in line: String) -> (
        severity: BuildDiagnostic.Severity, line: Int, message: String
    )? {
        let source = line as NSString
        for pattern in [chktexWithColumn, chktexWithoutColumn] {
            guard let match = pattern.firstMatch(
                in: line, range: NSRange(location: 0, length: source.length)
            ), match.numberOfRanges >= 5 else { continue }
            guard let lineNumber = Int(source.substring(with: match.range(at: 2))) else {
                continue
            }
            let rawSeverity = source.substring(with: match.range(at: 3)).lowercased()
            let messageRange = match.range(at: match.numberOfRanges - 1)
            let message = source.substring(with: messageRange)
                .trimmingCharacters(in: .whitespaces)
            guard !message.isEmpty else { continue }
            return (
                rawSeverity.contains("error") ? .error : .warning,
                lineNumber,
                message
            )
        }
        return nil
    }

    // MARK: - Helpers

    private static let environmentPattern = try! NSRegularExpression(
        pattern: #"\\(begin|end)\{([A-Za-z][A-Za-z0-9*]*)\}"#
    )

    private static let labelPattern = try! NSRegularExpression(
        pattern: #"\\label\{([^{}]+)\}"#
    )

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"\\(?:ref|eqref|autoref|pageref|cref|Cref)\{([^{}]+)\}"#
    )

    private static let citationPattern = try! NSRegularExpression(
        pattern: #"\\(?:cite|citep|citet|citeauthor|citeyear|parencite|textcite|autocite|footcite)\*?(?:\[[^\]\n]*\])*\{([^{}]+)\}"#
    )

    private static let chktexWithColumn = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+):\s*(Warning|Error)\s+\d+:\s*(.*)$"#
    )

    private static let chktexWithoutColumn = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):\s*(Warning|Error)\s+\d+:\s*(.*)$"#
    )

    private static func lineStarts(in source: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < source.length {
            if source.character(at: index) == 10 { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    private static func lineNumber(at location: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    private static func isCommented(at location: Int, in source: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = source.character(at: index)
            if character == 10 { return false }
            if character == ascii("%") {
                return !isEscaped(index, in: source)
            }
            index -= 1
        }
        return false
    }

    private static func isEscaped(_ location: Int, in source: NSString) -> Bool {
        var backslashes = 0
        var index = location - 1
        while index >= 0, source.character(at: index) == ascii("\\") {
            backslashes += 1
            index -= 1
        }
        return backslashes % 2 == 1
    }

    private static func clean(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limited(_ items: [BuildDiagnostic]) -> [BuildDiagnostic] {
        var seen = Set<String>()
        var results: [BuildDiagnostic] = []
        for item in items {
            let key = "\(item.severity)|\(item.line ?? -1)|\(item.message)"
            if seen.insert(key).inserted { results.append(item) }
            if results.count >= maxDiagnostics { break }
        }
        return results
    }

    private static func ascii(_ character: Character) -> unichar {
        unichar(character.asciiValue ?? 0)
    }
}
