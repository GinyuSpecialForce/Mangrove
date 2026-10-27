import Foundation

/// A local working copy of one Overleaf project.
///
/// Overleaf's only cookie-authenticated route that returns file contents is the
/// project zip, so the app keeps a real directory on disk: download → unpack →
/// edit → upload the files that changed.
final class ProjectWorkspace {
    let projectId: String
    let root: URL

    private var modified: Set<String> = []

    init(projectId: String) {
        self.projectId = projectId
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mangrove/Projects", isDirectory: true)
        self.root = base.appendingPathComponent(projectId, isDirectory: true)
    }

    var hasLocalChanges: Bool { !modified.isEmpty }
    var modifiedPaths: [String] { modified.sorted() }

    // MARK: - Sync down

    /// Replaces the working copy with the given archive.
    func replaceContents(withZip data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            try? manager.removeItem(at: item)
        }

        let archive = root.deletingLastPathComponent()
            .appendingPathComponent(".download-\(projectId).zip")
        try data.write(to: archive, options: .atomic)
        defer { try? manager.removeItem(at: archive) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", archive.path, "-d", root.path]
        let errors = Pipe()
        unzip.standardOutput = Pipe()
        unzip.standardError = errors
        try unzip.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MangroveError.zipFailed(detail.isEmpty ? "unzip exited with \(unzip.terminationStatus)" : detail)
        }

        collapseSingleRootFolderIfNeeded()
        modified.removeAll()
    }

    /// Some archives wrap the project in a single folder; the editor wants the
    /// project files at the top level.
    private func collapseSingleRootFolderIfNeeded() {
        let manager = FileManager.default
        guard let top = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ), top.count == 1, let only = top.first else { return }

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: only.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        let children = (try? manager.contentsOfDirectory(at: only, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let destination = root.appendingPathComponent(child.lastPathComponent)
            try? manager.moveItem(at: child, to: destination)
        }
        try? manager.removeItem(at: only)
    }

    // MARK: - Tree

    func fileTree() -> [FileNode] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [FileNode] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            let path = relativePath(for: url) ?? url.lastPathComponent
            files.append(FileNode(
                path: path,
                name: url.lastPathComponent,
                isDirectory: false,
                children: []
            ))
        }
        return WorkspaceTreeBuilder.build(from: files)
    }

    func relativePath(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    // MARK: - Read / write

    func readText(_ relativePath: String) throws -> String {
        let data = try Data(contentsOf: url(for: relativePath))
        guard let text = String(data: data, encoding: .utf8) else {
            throw MangroveError.message("\(relativePath) is not a UTF-8 text file.")
        }
        return text
    }

    func readData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(for: relativePath))
    }

    func writeText(_ relativePath: String, text: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: target, options: .atomic)
        modified.insert(relativePath)
    }

    func createFile(_ relativePath: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: target, options: .atomic)
        modified.insert(relativePath)
    }

    func deleteFile(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url(for: relativePath))
        // Uploads can create and overwrite but never remove, so a deleted file
        // stops being an upload candidate; Overleaf keeps its copy until it is
        // deleted on the website.
        modified.remove(relativePath)
    }

    func markClean(_ relativePath: String) {
        modified.remove(relativePath)
    }

    func markDirty(_ relativePath: String) {
        modified.insert(relativePath)
    }
}

/// Turns a flat list of relative paths into a sorted folder hierarchy.
enum WorkspaceTreeBuilder {
    static func build(from files: [FileNode]) -> [FileNode] {
        var directories: [String: [FileNode]] = [:]
        var topLevel: [FileNode] = []

        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            if components.count <= 1 {
                topLevel.append(file)
            } else {
                let directory = components.dropLast().joined(separator: "/")
                directories[directory, default: []].append(file)
            }
        }

        func node(forDirectory path: String) -> FileNode {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let children = directories[path] ?? []
            var subdirectories: [String] = []
            for candidate in directories.keys where candidate != path {
                let parent = candidate.split(separator: "/").dropLast().joined(separator: "/")
                if parent == path, !subdirectories.contains(candidate) {
                    subdirectories.append(candidate)
                }
            }
            let all = (children + subdirectories.map(node(forDirectory:))).sorted(by: sortNodes)
            return FileNode(path: path, name: name, isDirectory: true, children: all)
        }

        let roots = directories.keys
            .filter { !$0.contains("/") }
            .map(node(forDirectory:))

        return (topLevel + roots).sorted(by: sortNodes)
    }

    private static func sortNodes(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let aLatex = FileNode.isLatex(a.name)
        let bLatex = FileNode.isLatex(b.name)
        if aLatex != bLatex { return aLatex }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
