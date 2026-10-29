import CryptoKit
import Foundation

/// A local working copy of one Overleaf project.
///
/// Overleaf's only cookie-authenticated route that returns file contents is the
/// project zip, so the app keeps a real directory on disk: download → unpack →
/// edit → upload the files that changed.
///
/// Three things live outside the project directory:
///
///   * `Bases/<project>` — the remote version of each file as we last saw it.
///     This is the common ancestor of a three-way merge; without it, two edits
///     to the same file can only overwrite one another.
///   * `State/<project>.json` — which files have unsaved edits and whether a
///     compile is waiting, so restarting the app (or losing the network) never
///     loses work.
///   * `Staging/` — a downloaded archive unpacked for comparison before
///     anything in the working copy is touched.
final class ProjectWorkspace {

    let projectId: String
    let root: URL
    let baseRoot: URL
    let historyRoot: URL

    private let supportRoot: URL
    private let stateURL: URL
    private var modified: Set<String>
    private var state: StoredState

    /// Files larger than this are not kept as merge bases: the extra copy would
    /// cost more disk than a conflict on a large asset is worth, and such files
    /// are treated as binaries.
    static let maxBaseBytes = 4 * 1024 * 1024

    struct StoredState: Codable {
        var modified: [String] = []
        var pendingCompile: Bool = false
        var lastRemoteDigest: String?
        var rootDocument: String?
        var lastOpenPath: String?
    }

    init(projectId: String) {
        self.projectId = projectId
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mangrove", isDirectory: true)

        self.supportRoot = support
        self.root = support.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
        self.baseRoot = support.appendingPathComponent("Bases", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
        self.stateURL = support.appendingPathComponent("State", isDirectory: true)
            .appendingPathComponent("\(projectId).json")
        self.historyRoot = support.appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)

        let stored = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONDecoder().decode(StoredState.self, from: $0) }
        self.state = stored ?? StoredState()
        self.modified = Set(stored?.modified ?? [])
    }

    // MARK: - Pending state

    var hasLocalChanges: Bool { !modified.isEmpty }
    var modifiedPaths: [String] { modified.sorted() }

    var pendingCompile: Bool {
        get { state.pendingCompile }
        set {
            state.pendingCompile = newValue
            persist()
        }
    }

    /// SHA-256 of the most recent downloaded archive. Recorded for diagnostics,
    /// not used to decide anything: zip metadata changes between downloads even
    /// when the files inside are identical.
    var lastRemoteDigest: String? { state.lastRemoteDigest }
    var rootDocument: String? {
        get { state.rootDocument }
        set {
            state.rootDocument = newValue
            persist()
        }
    }

    var lastOpenPath: String? {
        get { state.lastOpenPath }
        set {
            state.lastOpenPath = newValue
            persist()
        }
    }

    func recordRemoteDigest(_ digest: String) {
        state.lastRemoteDigest = digest
        persist()
    }

    private func persist() {
        state.modified = modified.sorted()
        let manager = FileManager.default
        try? manager.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: - Merge bases

    func saveBase(_ path: String, data: Data?) {
        guard let data else {
            removeBase(path)
            return
        }
        guard data.count <= Self.maxBaseBytes else {
            removeBase(path)
            return
        }
        let target = baseRoot.appendingPathComponent(path)
        let manager = FileManager.default
        try? manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: target, options: .atomic)
    }

    func baseData(_ path: String) -> Data? {
        try? Data(contentsOf: baseRoot.appendingPathComponent(path))
    }

    func removeBase(_ path: String) {
        try? FileManager.default.removeItem(at: baseRoot.appendingPathComponent(path))
    }

    func clearBases() {
        try? FileManager.default.removeItem(at: baseRoot)
    }

    func saveBases(from staged: StagedProject) {
        for path in staged.filePaths {
            saveBase(path, data: staged.data(for: path))
        }
    }

    // MARK: - Sync down

    /// Downloads an archive and unpacks it somewhere else, so the working copy
    /// can be compared file by file before anything is replaced.
    func stage(_ zip: Data) throws -> StagedProject {
        try StagedProject(projectId: projectId, zip: zip, supportRoot: supportRoot)
    }

    /// Replaces the working copy with a staged archive. Used for a first
    /// download and by the "discard everything" path.
    func install(_ staged: StagedProject) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: root)
        try manager.copyItem(at: staged.root, to: root)
        modified.removeAll()
        persist()
    }

    /// Replaces the working copy with the given archive.
    func replaceContents(withZip data: Data) throws {
        let staged = try stage(data)
        defer { staged.discard() }
        try install(staged)
        saveBases(from: staged)
    }

    /// Some archives wrap the project in a single folder; the editor wants the
    /// project files at the top level.
    static func collapseSingleRootFolder(in root: URL) {
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
        let files = allPaths().map { path in
            FileNode(
                path: path,
                name: (path as NSString).lastPathComponent,
                isDirectory: false,
                children: []
            )
        }
        return WorkspaceTreeBuilder.build(from: files)
    }

    func allPaths() -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            if let relative = relativePath(for: url) {
                paths.append(relative)
            }
        }
        return paths.sorted()
    }

    var hasFilesOnDisk: Bool {
        !allPaths().isEmpty
    }

    /// Local compile artefacts live outside the project so TeX's aux files never
    /// appear in the file tree or get uploaded.
    var buildDirectory: URL {
        supportRoot.appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
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

    func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: relativePath).path)
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

    func readDataIfPresent(_ relativePath: String) -> Data? {
        try? Data(contentsOf: url(for: relativePath))
    }

    func writeText(_ relativePath: String, text: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: target, options: .atomic)
        modified.insert(relativePath)
        persist()
    }

    /// Mirrors the editor to disk without queueing an upload. This is crash
    /// protection while typing, not a save: the pending flag is only set once
    /// the edit is committed with ⌘S or a file switch.
    func saveDraft(_ relativePath: String, text: String) {
        let target = url(for: relativePath)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(text.utf8).write(to: target, options: .atomic)
    }

    /// Writes the remote copy without marking the file as locally edited.
    func writeRemote(_ relativePath: String, data: Data) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
        modified.remove(relativePath)
        persist()
    }

    func createFile(_ relativePath: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: target, options: .atomic)
        modified.insert(relativePath)
        persist()
    }

    /// Copies a file from outside the project into the working copy and queues
    /// it for upload. An existing file is replaced, which is what choosing the
    /// same name in the picker means.
    func importFile(from source: URL, as relativePath: String) throws {
        // Harmless outside the sandbox, and required if the app ever gains one.
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try importData(try Data(contentsOf: source), as: relativePath)
    }

    func importData(_ data: Data, as relativePath: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
        modified.insert(relativePath)
        persist()
    }

    func deleteFile(_ relativePath: String) throws {
        try removeLocal(relativePath)
    }

    /// Removes a file, or a folder and everything below it, from the working
    /// copy. Pending uploads for the removed paths are dropped: they no longer
    /// have anything to upload.
    func removeItem(at relativePath: String) throws {
        let target = url(for: relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
        modified = modified.filter { !Self.isInside($0, folder: relativePath) }
        let base = baseRoot.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.removeItem(at: base)
        }
        persist()
    }

    func removeLocal(_ relativePath: String) throws {
        try removeItem(at: relativePath)
    }

    func createDirectory(_ relativePath: String) throws {
        guard !relativePath.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: url(for: relativePath), withIntermediateDirectories: true
        )
    }

    /// Moves or renames a file or folder in the working copy and carries its
    /// merge bases and pending-upload flags along. The caller updates the open
    /// documents separately.
    func moveItem(from source: String, to destination: String) throws {
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return }
        let from = url(for: source)
        let to = url(for: destination)
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw MangroveError.message("\(source) is not in the local copy.")
        }
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: to.path) {
            throw MangroveError.message("“\(destination)” already exists in this project.")
        }
        try FileManager.default.moveItem(at: from, to: to)

        modified = Set(modified.map { path in
            guard Self.isInside(path, folder: source) else { return path }
            return destination + String(path.dropFirst(source.count))
        })

        let baseFrom = baseRoot.appendingPathComponent(source)
        let baseTo = baseRoot.appendingPathComponent(destination)
        if FileManager.default.fileExists(atPath: baseFrom.path) {
            try? FileManager.default.createDirectory(
                at: baseTo.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.moveItem(at: baseFrom, to: baseTo)
        }
        persist()
    }

    /// True when `path` is `folder` or below it. The project root ("") contains
    /// everything.
    static func isInside(_ path: String, folder: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    func markClean(_ relativePath: String) {
        guard modified.remove(relativePath) != nil else { return }
        persist()
    }

    func markDirty(_ relativePath: String) {
        guard modified.insert(relativePath).inserted else { return }
        persist()
    }

    // MARK: - Hashing

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Staged download

/// One downloaded archive, unpacked outside the working copy.
final class StagedProject {
    let root: URL
    let digest: String
    let filePaths: [String]

    init(projectId: String, zip: Data, supportRoot: URL) throws {
        self.digest = ProjectWorkspace.digest(of: zip)
        let staging = supportRoot.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        self.root = staging.appendingPathComponent(
            "\(projectId)-\(UUID().uuidString)", isDirectory: true
        )
        try ProjectArchive.unpack(zip, into: root, collapseSingleRoot: true)
        self.filePaths = Self.listFiles(in: root)
    }

    func data(for path: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(path))
    }

    func text(for path: String) -> String? {
        data(for: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    func discard() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func listFiles(in root: URL) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var paths: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths.sorted()
    }
}

// MARK: - Archive handling

enum ProjectArchive {
    static func unpack(_ data: Data, into root: URL, collapseSingleRoot: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.deletingLastPathComponent()
            .appendingPathComponent("archive-\(UUID().uuidString).zip")
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

        if collapseSingleRoot {
            ProjectWorkspace.collapseSingleRootFolder(in: root)
        }
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
