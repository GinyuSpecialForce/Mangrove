import AppKit
import Foundation
import SwiftUI

enum RightPane: String, CaseIterable, Identifiable {
    case editor, split, pdf
    var id: String { rawValue }
    var title: String {
        switch self {
        case .editor: return "Source"
        case .split: return "Split"
        case .pdf: return "PDF"
        }
    }
}

/// Owns the whole client: session, project list, local working copy, and builds.
@MainActor
final class AppState: ObservableObject {

    // Session
    @Published private(set) var session: StoredSession?
    @Published var isSignedIn = false

    // Projects
    @Published var projects: [OverleafProject] = []
    @Published var selectedProjectId: String?
    @Published private(set) var openProjectName: String?

    // Files
    @Published var fileTree: [FileNode] = []
    @Published var openPath: String?
    @Published var editorText: String = ""
    @Published var isDirty = false
    @Published var unsavedFiles: [String] = []

    // Build output
    @Published var pdfData: Data?
    @Published var compilerLog: String = ""
    @Published var rightPane: RightPane = .split
    @Published var draftMode = false

    // UI feedback
    @Published var busyMessage: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var showSignInSheet = false
    @Published var isOpeningProject = false
    @Published var isCompiling = false

    private var client: OverleafClient?
    private var workspace: ProjectWorkspace?
    private var openProjectId: String?
    private var isCompletingSignIn = false
    private var savedText = ""
    private var openGeneration = 0
    private let store = SessionStore()

    var projectTitle: String {
        openProjectName ?? selectedProjectName ?? "Mangrove"
    }

    var selectedProjectName: String? {
        projects.first { $0.id == selectedProjectId }?.name
    }

    /// Words in the open document, for the editor's footer.
    var wordCount: Int {
        editorText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var lineCount: Int {
        editorText.isEmpty ? 0 : editorText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The base URL new sign-ins target. Kept in one place so self-hosted
    /// instances can be added later without touching the client.
    private var baseURL: URL {
        URL(string: session?.baseURL ?? "https://www.overleaf.com") ?? URL(string: "https://www.overleaf.com")!
    }

    /// The instance root, used as the base URL stored with a session.
    var instanceURL: URL { baseURL }

    /// Overleaf's root URL is its marketing sign-up page; send people straight to
    /// the sign-in form instead.
    var signInURL: URL {
        URL(string: "/login", relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    // MARK: - Lifecycle

    func restoreSession() async {
        guard let stored = store.load() else { return }
        let client = OverleafClient(session: stored)
        client.onSessionUpdate = { [weak self] updated in
            Task { @MainActor in self?.persist(updated) }
        }
        self.client = client
        self.session = stored

        if await client.verifySession() {
            isSignedIn = true
            await refreshProjects()
        } else {
            // Stale cookie — drop it so the user gets a clean sign-in screen.
            store.clear()
            self.session = nil
            self.client = nil
        }
    }

    func completeSignIn(with stored: StoredSession) async {
        // The web view reports cookies as soon as they appear, which can be a
        // moment before Overleaf has finished establishing the session — and the
        // poll can fire again for each rotation. Neither should produce a churn
        // of sign-in attempts or a spurious error.
        guard !isSignedIn, !isCompletingSignIn else { return }
        isCompletingSignIn = true
        defer { isCompletingSignIn = false }

        let client = OverleafClient(session: stored)
        client.onSessionUpdate = { [weak self] updated in
            Task { @MainActor in self?.persist(updated) }
        }

        var verified = false
        for attempt in 0..<4 {
            if await client.verifySession() {
                verified = true
                break
            }
            if isSignedIn { return }
            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        guard verified else {
            // A late attempt may have already completed the sign-in.
            if !isSignedIn {
                errorMessage = "Signed in to Overleaf, but the session could not be verified. Please try again."
            }
            return
        }

        self.client = client
        persist(stored)
        self.session = stored
        isSignedIn = true
        showSignInSheet = false
        statusMessage = "Signed in to \(stored.host)"
        await refreshProjects()
    }

    private func persist(_ stored: StoredSession) {
        session = stored
        try? store.save(stored)
    }

    func signOut() {
        store.clear()
        session = nil
        client = nil
        isSignedIn = false
        projects = []
        selectedProjectId = nil
        openProjectName = nil
        openProjectId = nil
        fileTree = []
        openPath = nil
        editorText = ""
        pdfData = nil
        compilerLog = ""
        workspace = nil
        statusMessage = nil
    }

    // MARK: - Projects

    func refreshProjects() async {
        guard let client else { return }
        busyMessage = "Loading projects…"
        defer { busyMessage = nil }
        do {
            projects = try await client.fetchProjects()
            statusMessage = "\(projects.count) projects"
        } catch {
            present(error)
        }
    }

    /// Called when the sidebar selection changes. Ignoring a repeat of the
    /// currently open project keeps the download from being triggered twice.
    func projectSelectionChanged(to projectId: String?) async {
        guard let projectId, projectId != openProjectId else { return }
        await openProject(projectId)
    }

    func openProject(_ projectId: String) async {
        guard let client else { return }
        guard let project = projects.first(where: { $0.id == projectId }) else { return }

        // Clicking through projects quickly can have several downloads in flight;
        // only the most recent one is allowed to touch the UI.
        openGeneration += 1
        let generation = openGeneration
        isOpeningProject = true
        defer { if generation == openGeneration { isOpeningProject = false } }

        do {
            let zip = try await client.downloadProjectZip(projectId)
            let workspace = ProjectWorkspace(projectId: projectId)
            try workspace.replaceContents(withZip: zip)
            guard generation == openGeneration else { return }

            self.workspace = workspace
            self.openProjectName = project.name
            self.openProjectId = projectId
            self.selectedProjectId = projectId
            self.fileTree = workspace.fileTree()
            self.unsavedFiles = []
            self.pdfData = nil
            self.compilerLog = ""
            self.errorMessage = nil
            self.isDirty = false
            self.openPath = nil
            self.editorText = ""

            // Open the project's main document if we can find one.
            if let main = defaultDocument(in: fileTree) {
                openFile(main)
            }
            statusMessage = "Loaded \(fileTree.count) items"
        } catch {
            guard generation == openGeneration else { return }
            // Put the sidebar back on the project that is actually open.
            selectedProjectId = openProjectId

            // A project listed by Overleaf that can no longer be read usually
            // means it was deleted or the user's access was revoked; the list is
            // stale, so refresh it rather than leaving a dead entry behind.
            if case let MangroveError.http(status, _) = error, status == 404 {
                errorMessage = "“\(project.name)” could not be opened. It may have been deleted, or your access to it may have changed."
                await refreshProjects()
                return
            }
            present(error)
        }
    }

    func reloadProject() async {
        guard let projectId = selectedProjectId else { return }
        guard !isDirty || confirmDiscard() else { return }
        await openProject(projectId)
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard local changes?"
        alert.informativeText = "This project has unsaved edits. Reloading from Overleaf will throw them away."
        alert.addButton(withTitle: "Discard and Reload")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Prefers `main.tex`, then `paper.tex`, then the shallowest .tex file.
    private func defaultDocument(in nodes: [FileNode]) -> String? {
        var texFiles: [FileNode] = []
        func walk(_ list: [FileNode]) {
            for node in list {
                if node.isDirectory { walk(node.children) } else if node.name.hasSuffix(".tex") { texFiles.append(node) }
            }
        }
        walk(nodes)
        for preferred in ["main.tex", "paper.tex", "thesis.tex", "document.tex", "report.tex"] {
            if let match = texFiles.first(where: { $0.name.lowercased() == preferred }) { return match.path }
        }
        return texFiles.min(by: { $0.path.count < $1.path.count })?.path
    }

    // MARK: - Files

    func openFile(_ path: String) {
        guard let workspace else { return }
        // Folders are not documents; clicking one in the tree does nothing.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workspace.url(for: path).path, isDirectory: &isDirectory
        ), !isDirectory.boolValue else { return }
        guard TextFileSupport.isProbablyText(path) else {
            statusMessage = "\(path) is not a text file, so it cannot be edited here."
            return
        }
        do {
            // Switching files must not discard what was typed: the edit is written
            // to the local working copy and waits there until it is saved.
            if isDirty, let current = openPath {
                try workspace.writeText(current, text: editorText)
                if !unsavedFiles.contains(current) { unsavedFiles.append(current) }
            }
            let text = try workspace.readText(path)
            openPath = path
            editorText = text
            savedText = text
            isDirty = false
        } catch {
            present(error)
        }
    }

    /// Called as the user types.
    func editorTextChanged(_ text: String) {
        editorText = text
        isDirty = text != savedText
    }

    /// Until writing is available, this is how an edit leaves the app.
    func copyCurrentFileToPasteboard() {
        guard let path = openPath else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editorText, forType: .string)
        statusMessage = "Copied \(path) to the clipboard"
    }

    /// Returns whether the file actually made it to Overleaf.
    @discardableResult
    func saveCurrentFile() async -> Bool {
        guard let path = openPath else { return false }
        return await save(paths: [path])
    }

    /// Uploads every file with local edits. Compile goes through this so a build
    /// always reflects what is on screen.
    @discardableResult
    func saveAllChanges() async -> Bool {
        guard let workspace else { return false }
        var paths = workspace.modifiedPaths
        if let open = openPath, isDirty, !paths.contains(open) { paths.append(open) }
        guard !paths.isEmpty else { return true }
        return await save(paths: paths)
    }

    private func save(paths: [String]) async -> Bool {
        guard let client, let workspace, let projectId = selectedProjectId else { return false }

        // The editor holds the newest text, so flush it before reading from disk.
        if let open = openPath, isDirty, paths.contains(open) {
            try? workspace.writeText(open, text: editorText)
        }

        busyMessage = paths.count == 1 ? "Saving \(paths[0])…" : "Saving \(paths.count) files…"
        defer { busyMessage = nil }

        var wrote = 0
        for path in paths {
            // Files deleted locally have nothing to upload; removing them on
            // Overleaf still has to happen on the website.
            guard FileManager.default.fileExists(atPath: workspace.url(for: path).path) else { continue }
            do {
                let contents = try workspace.readData(path)
                try await client.saveFile(projectId: projectId, relativePath: path, contents: contents)
                workspace.markClean(path)
                unsavedFiles.removeAll { $0 == path }
                if path == openPath {
                    savedText = editorText
                    isDirty = false
                }
                wrote += 1
            } catch {
                showSaveFailure(path: path, error: error)
                return false
            }
        }

        guard wrote > 0 else {
            errorMessage = "Nothing could be saved. Files deleted here have to be removed on Overleaf itself."
            return false
        }
        // A previous failure is no longer true once a save goes through.
        errorMessage = nil
        statusMessage = wrote == 1 ? "Saved \(paths[0])" : "Saved \(wrote) files"
        return true
    }

    private func showSaveFailure(path: String, error: Error) {
        if case MangroveError.notAuthenticated = error {
            present(error)
            return
        }
        if case let MangroveError.http(status, body) = error {
            if status == 429 {
                errorMessage = "Overleaf is limiting how many files can be uploaded at once. Wait a moment, then save again."
                return
            }
            if body.contains("folder_not_found") || body.contains("duplicate_file_name") || body.contains("invalid_filename") {
                errorMessage = "Overleaf would not accept “\(path)”. If a file with that name already exists there, rename or remove it on Overleaf first."
                return
            }
            if body.contains("project_has_too_many_files") {
                errorMessage = "This project has reached Overleaf's file limit, so “\(path)” was not saved."
                return
            }
        }
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = "“\(path)” was not saved. \(detail)"
    }

    func createFile(named name: String) {
        guard let workspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // New files go next to the currently open one.
        let directory = openPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let path = directory.isEmpty ? trimmed : "\(directory)/\(trimmed)"
        do {
            try workspace.createFile(path)
            fileTree = workspace.fileTree()
            openFile(path)
            isDirty = true
            savedText = ""
            statusMessage = "Created \(path) — save it to send it to Overleaf."
        } catch {
            present(error)
        }
    }

    func deleteFile(_ path: String) {
        guard let workspace else { return }
        do {
            try workspace.deleteFile(path)
            fileTree = workspace.fileTree()
            if openPath == path {
                openPath = nil
                editorText = ""
                savedText = ""
                isDirty = false
            }
            statusMessage = "Removed \(path) locally. Overleaf still has it — delete it there to remove it from the project."
        } catch {
            present(error)
        }
    }

    // MARK: - Build

    func saveAndCompile() async {
        guard let client, let projectId = selectedProjectId else { return }
        // Compile builds whatever Overleaf currently has, so every edit has to be
        // uploaded first — otherwise the PDF shows the last saved version.
        let saved = await saveAllChanges()
        let pendingEdits = !saved

        isCompiling = true
        defer { isCompiling = false }
        do {
            let result = try await client.compile(projectId: projectId, draft: draftMode)
            pdfData = nil

            if result.succeeded || result.pdf != nil {
                if let pdf = result.pdf {
                    pdfData = try await client.download(output: pdf, from: result, projectId: projectId)
                }
                compilerLog = await loadLog(from: result, client: client, projectId: projectId)
                if result.succeeded {
                    if pendingEdits {
                        statusMessage = "Compiled Overleaf's saved copy — your unsaved edits were not included"
                    } else {
                        statusMessage = "Saved and compiled"
                    }
                    if rightPane == .editor { rightPane = .split }
                } else {
                    statusMessage = "Compile finished with status “\(result.status)”"
                }
            } else {
                compilerLog = await loadLog(from: result, client: client, projectId: projectId)
                if compilerLog.isEmpty {
                    compilerLog = "Overleaf reported status “\(result.status)” with no log."
                }
                statusMessage = "Compile failed — see the build log"
                if pdfData == nil { rightPane = .editor }
            }
        } catch {
            present(error)
        }
    }

    private func loadLog(from result: CompileResult, client: OverleafClient, projectId: String) async -> String {
        if let problems = result.validationSummary { return problems }
        guard let log = result.log else { return "" }
        guard let data = try? await client.download(output: log, from: result, projectId: projectId) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Errors

    private func present(_ error: Error) {
        if case MangroveError.notAuthenticated = error {
            statusMessage = nil
            errorMessage = "Your Overleaf session expired. Please sign in again."
            signOut()
            errorMessage = "Your Overleaf session expired. Please sign in again."
            return
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func dismissError() { errorMessage = nil }
}
