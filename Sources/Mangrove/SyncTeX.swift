import Foundation

/// A local build's SyncTeX map, driven through the `synctex` command that ships
/// with TeX Live.
///
/// Remote builds do not expose their `.synctex.gz`, so jumps are only available
/// when the page came from `latexmk`/`pdflatex` on this Mac. That is a limitation
/// of the build, not of the mapping.
struct SyncTeX {
    let executable: URL
    let pdfURL: URL
    let projectRoot: URL

    struct SourceLocation: Equatable {
        let file: String
        let line: Int
        let column: Int?
    }

    /// Page numbers are one-based; `x` and `y` are in big points from the page's
    /// top-left corner, which is what `synctex edit` expects.
    struct Target: Equatable {
        let page: Int
        let x: Double
        let y: Double
    }

    /// Finds the CLI next to the TeX engine and checks that both the PDF and the
    /// map are there.
    static func locate(engine: URL, pdfURL: URL, projectRoot: URL) -> SyncTeX? {
        let tool = engine.deletingLastPathComponent().appendingPathComponent("synctex")
        let stem = pdfURL.deletingPathExtension()
        let manager = FileManager.default
        let hasMap = manager.fileExists(atPath: stem.appendingPathExtension("synctex.gz").path)
            || manager.fileExists(atPath: stem.appendingPathExtension("synctex").path)
        guard manager.isExecutableFile(atPath: tool.path),
              manager.fileExists(atPath: pdfURL.path), hasMap else { return nil }
        return SyncTeX(executable: tool, pdfURL: pdfURL, projectRoot: projectRoot)
    }

    func source(forPage page: Int, x: Double, y: Double) async -> SourceLocation? {
        let arguments = ["edit", "-o", "\(page):\(x):\(y):\(pdfURL.path)"]
        guard let output = await run(arguments) else { return nil }
        return Self.parseEdit(output)
    }

    func target(forFile file: String, line: Int, column: Int = 0) async -> Target? {
        let absolute: String
        if file.hasPrefix("/") {
            absolute = file
        } else {
            absolute = projectRoot.appendingPathComponent(file).path
        }
        let arguments = ["view", "-i", "\(line):\(column):\(absolute)", "-o", pdfURL.path]
        guard let output = await run(arguments) else { return nil }
        return Self.parseView(output)
    }

    // MARK: - Running

    private func run(_ arguments: [String]) async -> String? {
        let executable = self.executable
        let directory = projectRoot
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    // MARK: - Parsing

    /// `synctex edit` answers with `Input:`, `Line:` and `Column:` fields between
    /// result markers; the first block is the closest match.
    static func parseEdit(_ output: String) -> SourceLocation? {
        var file: String?
        var line: Int?
        var column: Int?
        for raw in output.split(separator: "\n") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Input:") {
                if file != nil { break }
                file = String(text.dropFirst("Input:".count))
            } else if text.hasPrefix("Line:") {
                if line != nil { break }
                line = Int(text.dropFirst("Line:".count).trimmingCharacters(in: .whitespaces))
            } else if text.hasPrefix("Column:") {
                column = Int(text.dropFirst("Column:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let file, !file.isEmpty, let line, line > 0 else { return nil }
        return SourceLocation(file: file, line: line, column: column)
    }

    /// `synctex view` repeats `Page:`, `x:` and `y:` per match; the first one is
    /// used, which is what a reader means by "where is this line".
    static func parseView(_ output: String) -> Target? {
        var page: Int?
        var x: Double?
        var y: Double?
        for raw in output.split(separator: "\n") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Page:") {
                if page != nil { break }
                page = Int(text.dropFirst("Page:".count).trimmingCharacters(in: .whitespaces))
            } else if text.hasPrefix("x:") {
                if x == nil { x = Double(text.dropFirst(2).trimmingCharacters(in: .whitespaces)) }
            } else if text.hasPrefix("y:") {
                if y == nil { y = Double(text.dropFirst(2).trimmingCharacters(in: .whitespaces)) }
            }
        }
        guard let page, page > 0, let x, let y else { return nil }
        return Target(page: page, x: x, y: y)
    }
}
