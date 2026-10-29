import Foundation

/// A LaTeX toolchain installed on this Mac, used when Overleaf cannot be
/// reached. Overleaf compiles on its own servers, so offline compilation is only
/// possible if the machine has TeX installed; nothing is bundled with the app.
///
/// `latexmk` is preferred because it handles bibliography and rerun passes
/// itself. Plain `pdflatex` is used when that is all there is.
struct LocalLaTeX {

    enum Tool: String {
        case latexmk
        case pdflatex
    }

    struct BuildOutput {
        let pdf: Data
        let log: String
        let document: String
        let succeeded: Bool
        /// The PDF on disk, kept so SyncTeX can map between it and the source.
        let pdfURL: URL
    }

    let tool: Tool
    let executable: URL

    // MARK: - Detection

    static func detect(fileManager: FileManager = .default) -> LocalLaTeX? {
        detect(in: searchDirectories(fileManager: fileManager), fileManager: fileManager)
    }

    /// The search order is a parameter so the toolchain lookup can be tested
    /// without a TeX installation.
    static func detect(in directories: [URL], fileManager: FileManager = .default) -> LocalLaTeX? {
        // Prefer latexmk wherever it lives, rather than taking the first
        // pdflatex found in an earlier directory.
        for directory in directories {
            if let url = executable(named: "latexmk", in: directory, fileManager: fileManager) {
                return LocalLaTeX(tool: .latexmk, executable: url)
            }
        }
        for directory in directories {
            if let url = executable(named: "pdflatex", in: directory, fileManager: fileManager) {
                return LocalLaTeX(tool: .pdflatex, executable: url)
            }
        }
        return nil
    }

    static func searchDirectories(fileManager: FileManager = .default) -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Library/TeX/texbin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
        ]

        let home = fileManager.homeDirectoryForCurrentUser
        let tinyTeX = home.appendingPathComponent("Library/TinyTeX/bin")
        if let versions = try? fileManager.contentsOfDirectory(atPath: tinyTeX.path) {
            directories += versions.map { tinyTeX.appendingPathComponent($0) }
        }

        let texlive = URL(fileURLWithPath: "/usr/local/texlive")
        if let years = try? fileManager.contentsOfDirectory(atPath: texlive.path) {
            for year in years.sorted(by: >) {
                let bin = texlive.appendingPathComponent(year).appendingPathComponent("bin")
                if let architectures = try? fileManager.contentsOfDirectory(atPath: bin.path) {
                    directories += architectures.map { bin.appendingPathComponent($0) }
                }
            }
        }
        return directories
    }

    private static func executable(named name: String, in directory: URL, fileManager: FileManager) -> URL? {
        let url = directory.appendingPathComponent(name)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Compiling

    func build(projectRoot: URL, mainFile: String, outputDirectory: URL) async throws -> BuildOutput {
        let tool = self.tool
        let executable = self.executable
        return try await Task.detached(priority: .userInitiated) {
            try LocalLaTeX.run(
                tool: tool,
                executable: executable,
                projectRoot: projectRoot,
                mainFile: mainFile,
                outputDirectory: outputDirectory
            )
        }.value
    }

    private static func run(
        tool: Tool,
        executable: URL,
        projectRoot: URL,
        mainFile: String,
        outputDirectory: URL
    ) throws -> BuildOutput {
        let manager = FileManager.default
        let root = projectRoot.standardizedFileURL
        let output = outputDirectory.standardizedFileURL
        let documentURL = root.appendingPathComponent(mainFile)

        guard manager.fileExists(atPath: documentURL.path) else {
            throw MangroveError.message("“\(mainFile)” is not in the local copy, so it cannot be compiled here.")
        }
        try manager.createDirectory(at: output, withIntermediateDirectories: true)

        // Process output goes to a file rather than a pipe: a full TeX log can be
        // larger than a pipe buffer, and a blocked pipe would hang the compile.
        let capturedLogURL = output.appendingPathComponent("mangrove-toolchain.log")
        manager.createFile(atPath: capturedLogURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: capturedLogURL) else {
            throw MangroveError.message("Could not write to the local build folder.")
        }
        defer { try? handle.close() }

        let name = (mainFile as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension

        var status: Int32 = 0
        switch tool {
        case .latexmk:
            status = try execute(
                executable,
                arguments: [
                    "-pdf", "-interaction=nonstopmode", "-file-line-error",
                    "-synctex=1", "-outdir=\(output.path)", mainFile,
                ],
                workingDirectory: root,
                log: handle,
                timeout: 300
            )
        case .pdflatex:
            status = try execute(
                executable,
                arguments: [
                    "-interaction=nonstopmode", "-file-line-error", "-synctex=1",
                    "-output-directory=\(output.path)", mainFile,
                ],
                workingDirectory: root,
                log: handle,
                timeout: 300
            )
            // One pass is never enough if the document has a bibliography, and
            // two are needed for cross-references to settle in any case.
            if needsBibTeX(outputDirectory: output, stem: stem) {
                let bibtex = executable.deletingLastPathComponent().appendingPathComponent("bibtex")
                if manager.isExecutableFile(atPath: bibtex.path) {
                    _ = try? execute(
                        bibtex, arguments: [stem],
                        workingDirectory: output, log: handle, timeout: 120
                    )
                }
            }
            status = try execute(
                executable,
                arguments: [
                    "-interaction=nonstopmode", "-file-line-error", "-synctex=1",
                    "-output-directory=\(output.path)", mainFile,
                ],
                workingDirectory: root,
                log: handle,
                timeout: 300
            )
        }

        let pdfURL = output.appendingPathComponent("\(stem).pdf")
        let texLogURL = output.appendingPathComponent("\(stem).log")
        let log = readLog(preferring: texLogURL, fallback: capturedLogURL)

        guard let pdf = try? Data(contentsOf: pdfURL), !pdf.isEmpty else {
            throw MangroveError.message(
                log.isEmpty
                    ? "Local LaTeX could not produce a PDF."
                    : "Local LaTeX could not produce a PDF.\n\n\(tail(of: log))"
            )
        }
        return BuildOutput(
            pdf: pdf, log: log, document: mainFile, succeeded: status == 0, pdfURL: pdfURL
        )
    }

    private static func execute(
        _ executable: URL,
        arguments: [String],
        workingDirectory: URL,
        log: FileHandle,
        timeout: TimeInterval
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = log
        process.standardError = log

        var environment = ProcessInfo.processInfo.environment
        let toolDirectory = executable.deletingLastPathComponent().path
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        if !path.split(separator: ":").contains(Substring(toolDirectory)) {
            environment["PATH"] = toolDirectory + ":" + path
        }
        process.environment = environment

        // The handler must be installed before the process starts, or a very
        // fast failure can finish before there is anything to be told about.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            throw MangroveError.message("Local LaTeX timed out after \(Int(timeout)) seconds.")
        }
        return process.terminationStatus
    }

    private static func needsBibTeX(outputDirectory: URL, stem: String) -> Bool {
        let aux = outputDirectory.appendingPathComponent("\(stem).aux")
        guard let text = try? String(contentsOf: aux, encoding: .utf8) else { return false }
        return text.contains("\\bibdata") || text.contains("\\citation")
    }

    private static func readLog(preferring logURL: URL, fallback: URL) -> String {
        for candidate in [logURL, fallback] {
            if let data = try? Data(contentsOf: candidate),
               let text = String(data: data, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(text.prefix(120_000))
            }
        }
        return ""
    }

    /// The last lines of a TeX log hold the actual error; the first two hundred
    /// are package chatter.
    private static func tail(of log: String, lines count: Int = 12) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(count)
            .joined(separator: "\n")
    }
}
