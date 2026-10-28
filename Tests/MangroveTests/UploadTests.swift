import XCTest
@testable import Mangrove

/// Uploading a file starts with a path decision, then a copy into the working
/// copy. Both are testable without a network, and a wrong path would put a
/// figure in the wrong folder or make one file overwrite another.
final class FileImportTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangrove-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testFilesLandInTheChosenFolder() {
        XCTAssertEqual(FileImport.relativePath(for: "figure.png", in: ""), "figure.png")
        XCTAssertEqual(FileImport.relativePath(for: "figure.png", in: "figures"), "figures/figure.png")
        XCTAssertEqual(FileImport.relativePath(for: "figure.png", in: "/figures/"), "figures/figure.png")
    }

    func testRepeatedNameIsRenamedInsteadOfOverwritten() throws {
        let first = try write(name: "figure.png", in: "a", contents: "one")
        let second = try write(name: "figure.png", in: "b", contents: "two")

        let plan = FileImport.plan(urls: [first, second], folder: "figures")

        XCTAssertEqual(
            plan.items.map(\.relativePath),
            ["figures/figure.png", "figures/figure 2.png"]
        )
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testSuffixDoesNotCollideWithAnExplicitlyNamedCopy() throws {
        let first = try write(name: "figure.png", in: "a", contents: "one")
        let second = try write(name: "figure.png", in: "b", contents: "two")
        let third = try write(name: "figure 2.png", in: "c", contents: "three")

        let plan = FileImport.plan(urls: [first, second, third], folder: "")

        XCTAssertEqual(plan.items.map(\.name), ["figure.png", "figure 2.png", "figure 2 2.png"])
    }

    func testFoldersAndOversizedFilesAreSkipped() throws {
        let folder = scratch.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let big = try write(name: "big.png", in: "", contents: String(repeating: "x", count: 4096))
        let small = try write(name: "small.png", in: "", contents: "tiny")

        let plan = FileImport.plan(urls: [folder, big, small], folder: "", maxBytes: 1024)

        XCTAssertEqual(plan.items.map(\.name), ["small.png"])
        XCTAssertEqual(plan.skipped.map(\.name), ["folder", "big.png"])
        XCTAssertTrue(plan.skipped[1].reason.contains("larger than"), plan.skipped[1].reason)
    }

    private func write(name: String, in directory: String, contents: String) throws -> URL {
        let folder = directory.isEmpty
            ? scratch!
            : scratch.appendingPathComponent(directory, isDirectory: true)
        if !directory.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

final class WorkspaceImportTests: XCTestCase {
    private var projectId = ""
    private var workspace: ProjectWorkspace!

    override func setUpWithError() throws {
        projectId = "import-\(UUID().uuidString)"
        workspace = ProjectWorkspace(projectId: projectId)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace.root)
        try? FileManager.default.removeItem(at: workspace.baseRoot)
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(
            at: support.appendingPathComponent("Mangrove/State/\(projectId).json")
        )
    }

    func testImportedFileIsCopiedAndQueued() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(UUID().uuidString).png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try workspace.importFile(from: source, as: "figures/photo.png")

        XCTAssertEqual(try workspace.readData("figures/photo.png"), bytes)
        XCTAssertEqual(workspace.modifiedPaths, ["figures/photo.png"])
        let folder = workspace.fileTree().first { $0.name == "figures" }
        XCTAssertEqual(folder?.children.map(\.name), ["photo.png"])

        // A brand new file has no remote copy and no merge base, so the save
        // path has to classify it as an upload rather than a conflict.
        XCTAssertEqual(
            SyncPlanner.action(local: bytes, base: nil, remote: nil, isText: false),
            .uploadLocal
        )
    }

    func testImportingReplacesExistingContents() throws {
        try workspace.createFile("notes.txt")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).txt")
        try "replacement".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        try workspace.importFile(from: source, as: "notes.txt")

        XCTAssertEqual(try workspace.readText("notes.txt"), "replacement")
        XCTAssertTrue(workspace.modifiedPaths.contains("notes.txt"))
    }
}
