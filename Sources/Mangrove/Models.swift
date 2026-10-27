import Foundation

// MARK: - Remote models

/// A project as returned by `GET /user/projects`.
struct OverleafProject: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let accessLevel: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name
        case accessLevel
    }
}

struct ProjectsResponse: Decodable {
    let projects: [OverleafProject]
}

/// One output artefact produced by a compile, e.g. `output.pdf`, `output.log`.
struct OutputFile: Hashable {
    let path: String
    let url: String?
    let type: String?

    init?(json: [String: Any]) {
        guard let path = json["path"] as? String else { return nil }
        self.path = path
        self.url = json["url"] as? String
        self.type = json["type"] as? String
    }
}

/// The parsed result of `POST /project/:id/compile`.
struct CompileResult {
    let status: String
    let outputFiles: [OutputFile]
    let clsiServerId: String?
    let pdfDownloadDomain: String?
    let outputUrlPrefix: String?
    let rawJSON: [String: Any]

    var succeeded: Bool { status == "success" }

    var pdf: OutputFile? { outputFiles.first { $0.path == "output.pdf" } }
    var log: OutputFile? { outputFiles.first { $0.path == "output.log" } }

    /// The build id is embedded in every output file url (`/build/<id>/output/…`).
    var buildId: String? {
        for file in outputFiles {
            guard let url = file.url else { continue }
            if let id = CompileResult.buildId(from: url) { return id }
        }
        return nil
    }

    static func buildId(from url: String) -> String? {
        guard let range = url.range(of: "/build/") else { return nil }
        let rest = url[range.upperBound...]
        guard let end = rest.firstIndex(of: "/") else { return nil }
        let id = String(rest[rest.startIndex..<end])
        return id.isEmpty ? nil : id
    }

    /// Human readable validation problems, if the compile reported any.
    var validationSummary: String? {
        guard let problems = rawJSON["validationProblems"] as? [String: Any] else { return nil }
        var lines: [String] = []
        for (file, value) in problems {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    let row = entry["row"] as? Int
                    let message = entry["message"] as? String ?? ""
                    lines.append(row.map { "\(file):\($0): \(message)" } ?? "\(file): \(message)")
                }
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Local working copy models

/// A node in the local file tree of a project working copy.
struct FileNode: Identifiable, Hashable {
    let path: String        // path relative to the project root
    let name: String
    let isDirectory: Bool
    var children: [FileNode]

    var id: String { path }

    /// LaTeX source files are what the editor is really for, so they sort first.
    static func isLatex(_ name: String) -> Bool {
        ["tex", "bib", "sty", "cls", "cls2"].contains((name as NSString).pathExtension.lowercased())
    }
}

/// Extensions we are willing to open in the text editor.
enum TextFileSupport {
    static let editable: Set<String> = [
        "tex", "bib", "sty", "cls", "txt", "md", "markdown", "ltx", "latex",
        "json", "yaml", "yml", "csv", "tsv", "xml", "html", "css", "js",
        "py", "r", "m", "sh", "gitignore", "bbl", "def", "cfg", "ini", "toml"
    ]

    static func isProbablyText(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return true }
        return editable.contains(ext)
    }
}

// MARK: - Errors

enum MangroveError: LocalizedError {
    case notAuthenticated
    case http(status: Int, body: String)
    case decoding(String)
    case compileFailed(String)
    case zipFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Your Overleaf session has expired. Please sign in again."
        case let .http(status, body):
            if status == 404 {
                return "Overleaf could not find that (HTTP 404). It may have been deleted, or your access may have changed."
            }
            let snippet = body.isEmpty ? "" : " — \(body)"
            return "Overleaf returned HTTP \(status)\(snippet)"
        case let .decoding(detail):
            return "Could not understand Overleaf's response: \(detail)"
        case let .compileFailed(detail):
            return "Compile failed: \(detail)"
        case let .zipFailed(detail):
            return "Could not unpack the project archive: \(detail)"
        case let .message(text):
            return text
        }
    }
}
