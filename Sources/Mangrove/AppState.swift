import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

/// Where the page in the PDF pane came from.
enum BuildSource {
    case none
    case overleaf
    case local
}

/// How the open document is being edited.
enum EditorMode: String, CaseIterable, Identifiable {
    case code
    case visual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .code: return "Code"
        case .visual: return "Visual"
        }
    }
}

/// A request to put the source editor on a range — a compiler error, or a
/// visual block that is easier to change in source. The token makes a second
/// jump to the same place take effect again.
struct EditorJump: Equatable {
    let token = UUID()
    let range: NSRange

    static func == (lhs: EditorJump, rhs: EditorJump) -> Bool {
        lhs.token == rhs.token
    }
}

/// A file open in the editor. The active document's fields are mirrored into
/// `AppState.editorText` so the editor and the save path keep one source of
/// truth while switching tabs.
struct OpenDocument: Identifiable, Equatable {
    let path: String
    var text: String
    var savedText: String
    var isDirty: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// A point on the compiled page to scroll to, requested by a SyncTeX lookup.
struct PDFFocus: Equatable {
    let token = UUID()
    let page: Int
    let x: Double
    let y: Double

    static func == (lhs: PDFFocus, rhs: PDFFocus) -> Bool {
        lhs.token == rhs.token
    }
}

/// Someone else connected to the project through Overleaf's realtime channel.
struct Collaborator: Identifiable, Equatable {
    let id: String
    var name: String
    var initials: String
}

struct FileNameRequest: Identifiable {
    let id = UUID()
    let path: String
    let isFolder: Bool
    var currentName: String { (path as NSString).lastPathComponent }
}

struct FileMoveRequest: Identifiable {
    let id = UUID()
    let path: String
    let isFolder: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct FileDeleteRequest: Identifiable {
    let id = UUID()
    let path: String
    let isFolder: Bool
    var name: String { (path as NSString).lastPathComponent }
}

/// Owns the whole client: session, project list, local working copy, builds and
/// the offline queue.
///
/// Saving is optimistic: the local copy is the truth while offline, and each
/// upload first checks whether Overleaf changed under us. If it did, the two
/// versions are merged against the last remote copy instead of overwriting one
/// another.
@MainActor
final class AppState: ObservableObject {

    // Session
    @Published private(set) var session: StoredSession?
    @Published var isSignedIn = false
    @Published var isOnline = true
    @Published var isSyncing = false

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
    @Published var pendingSyncCount = 0
    @Published var pendingCompile = false
    /// The last file added from disk, so the sidebar can reveal it.
    @Published var lastImportedPath: String?
    @Published var editorMode: EditorMode = .code
    @Published var editorJump: EditorJump?
    @Published var openDocuments: [OpenDocument] = []
    /// One-based caret line, reported by the source editor for SyncTeX.
    @Published var caretLine = 1
    @Published var completionIndex = CompletionIndex()
    @Published var autosaveEnabled: Bool = UserDefaults.standard.object(forKey: Defaults.autosave) as? Bool ?? true
    @Published var autoCompileEnabled: Bool = UserDefaults.standard.object(forKey: Defaults.autoCompile) as? Bool ?? true
    /// Live checks for the open file. Kept apart from compiler diagnostics so a
    /// build never wipes warnings the reader has not acted on yet.
    @Published private(set) var lintDiagnostics: [BuildDiagnostic] = []

    // Build output
    @Published var pdfData: Data?
    @Published var compilerLog: String = ""
    @Published var rightPane: RightPane = .split
    @Published var draftMode = false
    @Published var buildSource: BuildSource = .none
    @Published var lastBuildFailed = false
    @Published var buildDiagnostics: [BuildDiagnostic] = []
    @Published var localTeXAvailable = false
    @Published var syncTeX: SyncTeX?
    @Published var pdfFocus: PDFFocus?
    /// Whether the last finished build came from the idle scheduler. The build
    /// pane uses this to avoid pulling the reader away from another tab.
    @Published private(set) var lastBuildWasAutomatic = false

    // Project-wide tools
    @Published var isShowingProjectSearch = false
    @Published var isShowingHistory = false
    @Published var isShowingNewFolderSheet = false
    @Published var newFolderParent = ""
    @Published var renameRequest: FileNameRequest?
    @Published var moveRequest: FileMoveRequest?
    @Published var deleteRequest: FileDeleteRequest?
    @Published var collaborators: [Collaborator] = []
    @Published var remoteChangeDetected = false
    /// Increments after every finished build, so the build pane can decide which
    /// tab to show without treating two identical failures as one.
    @Published private(set) var buildRevision = 0

    // Conflicts
    @Published var pendingMerges: [PendingMerge] = []
    @Published var isShowingMergeSheet = false

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
    private var isFlushing = false
    private var draftTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var autoCompileTask: Task<Void, Never>?
    private var autoCompileNeeded = false
    private var lintTask: Task<Void, Never>?
    private var projectHistory: ProjectHistory?
    private var presenceTask: Task<Void, Never>?
    private var presenceStream: RealtimeStream?
    /// Our own uploads also echo back as tree events; ignore those for a moment
    /// after a save instead of nagging the reader to reload.
    private var ignoreRemoteChangesUntil: Date = .distantPast
    private var connectivityObserver: NSObjectProtocol?
    private let store = SessionStore()
    private let network = NetworkMonitor()
    private let projectCache = ProjectCache()

    init() {
        localTeXAvailable = LocalLaTeX.detect() != nil
        projects = projectCache.load()
        network.onChange = { [weak self] online in
            Task { @MainActor in self?.handleNetworkChange(online) }
        }
        // Coming back from sleep or another app is a natural moment to retry
        // work that was waiting for a connection.
        connectivityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let state = self
            Task { @MainActor in await state?.flushPendingWork() }
        }
    }

    deinit {
        if let connectivityObserver {
            NotificationCenter.default.removeObserver(connectivityObserver)
        }
    }

    // MARK: - Derived

    var projectTitle: String {
        openProjectName ?? selectedProjectName ?? "Mangrove"
    }

    /// Uploads need an open working copy, not just a selected project. While
    /// another project is downloading, `openProjectId` still names the old one.
    var canUploadFiles: Bool {
        openProjectId != nil && selectedProjectId != nil && !isOpeningProject
    }

    var selectedProjectName: String? {
        projects.first { $0.id == selectedProjectId }?.name
    }

    /// Folder paths in the working copy, for the move sheet. The root is the
    /// empty string and is offered first.
    var folderPaths: [String] {
        var paths: [String] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes where node.isDirectory {
                paths.append(node.path)
                walk(node.children)
            }
        }
        walk(fileTree)
        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Visual editing models LaTeX blocks; it only makes sense for a document,
    /// not for a bibliography or a style file.
    var canEditVisually: Bool {
        guard let openPath else { return false }
        return ["tex", "ltx", "latex"]
            .contains((openPath as NSString).pathExtension.lowercased())
    }

    var hasPendingWork: Bool {
        pendingSyncCount > 0 || pendingCompile
    }

    var currentMerge: PendingMerge? { pendingMerges.first }

    /// Words in the open document, for the editor's footer.
    var wordCount: Int {
        editorText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var lineCount: Int {
        editorText.isEmpty ? 0 : editorText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The base URL new sign-ins target.
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
        let client = makeClient(stored)
        self.client = client
        self.session = stored

        do {
            try await client.checkSession()
            isSignedIn = true
            isOnline = true
            await refreshProjects()
            await restoreLastProject()
        } catch {
            if Connectivity.isOffline(error) {
                // Being offline is not the same as being signed out: keep the
                // session and open whatever is already on disk.
                isSignedIn = true
                isOnline = false
                projects = projectCache.load()
                statusMessage = "Offline — editing the local copy"
                await restoreLastProject()
            } else {
                store.clear()
                session = nil
                self.client = nil
            }
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

        let client = makeClient(stored)
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
            if !isSignedIn {
                errorMessage = "Signed in to Overleaf, but the session could not be verified. Please try again."
            }
            return
        }

        self.client = client
        persist(stored)
        self.session = stored
        isSignedIn = true
        isOnline = true
        showSignInSheet = false
        statusMessage = "Signed in to \(stored.host)"
        await refreshProjects()
        await restoreLastProject()
    }

    private func makeClient(_ stored: StoredSession) -> OverleafClient {
        let client = OverleafClient(session: stored)
        client.onSessionUpdate = { [weak self] updated in
            Task { @MainActor in self?.persist(updated) }
        }
        return client
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
        openDocuments = []
        completionIndex = CompletionIndex()
        pdfData = nil
        compilerLog = ""
        buildDiagnostics = []
        editorJump = nil
        workspace = nil
        projectHistory = nil
        syncTeX = nil
        pdfFocus = nil
        collaborators = []
        remoteChangeDetected = false
        presenceTask?.cancel()
        presenceTask = nil
        presenceStream?.close()
        presenceStream = nil
        autosaveTask?.cancel()
        draftTask?.cancel()
        retryTask?.cancel()
        autoCompileTask?.cancel()
        autoCompileTask = nil
        autoCompileNeeded = false
        lintTask?.cancel()
        lintTask = nil
        lintDiagnostics = []
        lastBuildWasAutomatic = false
        statusMessage = nil
        pendingMerges = []
        isShowingMergeSheet = false
        pendingSyncCount = 0
        pendingCompile = false
        unsavedFiles = []
    }

    /// Opens the project that was open when the app last quit, if its working
    /// copy is still on disk. This is what makes an offline launch useful.
    private func restoreLastProject() async {
        guard openProjectId == nil,
              let id = UserDefaults.standard.string(forKey: Defaults.lastProjectId) else { return }
        let workspace = ProjectWorkspace(projectId: id)
        guard workspace.hasFilesOnDisk else { return }
        let name = UserDefaults.standard.string(forKey: Defaults.lastProjectName)
            ?? projects.first(where: { $0.id == id })?.name
        await openProject(id, name: name)
    }

    // MARK: - Network

    private func handleNetworkChange(_ online: Bool) {
        isOnline = online
        if online {
            statusMessage = "Back online"
            scheduleAutoCompile()
            Task { await flushPendingWork() }
        } else {
            autoCompileTask?.cancel()
            autoCompileTask = nil
            statusMessage = "Offline — edits are kept locally"
        }
    }

    // MARK: - Projects

    func refreshProjects() async {
        guard let client else { return }
        busyMessage = "Loading projects…"
        defer { busyMessage = nil }
        do {
            projects = try await client.fetchProjects()
            projectCache.save(projects)
            isOnline = true
            statusMessage = "\(projects.count) projects"
        } catch {
            if Connectivity.isOffline(error) {
                projects = projectCache.load()
                statusMessage = "Offline — showing the last known project list"
            } else {
                present(error)
            }
        }
    }

    /// Called when the sidebar selection changes. Ignoring a repeat of the
    /// currently open project keeps the download from being triggered twice.
    func projectSelectionChanged(to projectId: String?) async {
        guard let projectId, projectId != openProjectId else { return }
        // Queued work belongs to the project that is open; push it before
        // switching away, otherwise it waits until that project is reopened.
        if let workspace, workspace.hasLocalChanges, network.isOnline, pendingMerges.isEmpty {
            await flushPendingWork()
        }
        await openProject(projectId)
    }

    func openProject(_ projectId: String, name: String? = nil) async {
        // Clicking through projects quickly can have several downloads in flight;
        // only the most recent one is allowed to touch the UI.
        openGeneration += 1
        let generation = openGeneration
        // Reloading the same project should feel like a refresh, not like losing
        // every tab the reader had arranged.
        let previousProject = openProjectId
        let previousTabs = openDocuments.map(\.path)
        let previousActive = openPath
        isOpeningProject = true
        presenceTask?.cancel()
        autosaveTask?.cancel()
        draftTask?.cancel()
        autoCompileTask?.cancel()
        autoCompileTask = nil
        autoCompileNeeded = false
        lintTask?.cancel()
        lintTask = nil
        lintDiagnostics = []
        collaborators = []
        remoteChangeDetected = false
        defer { if generation == openGeneration { isOpeningProject = false } }

        let workspace = ProjectWorkspace(projectId: projectId)
        let displayName = name
            ?? projects.first(where: { $0.id == projectId })?.name
            ?? UserDefaults.standard.string(forKey: Defaults.lastProjectName)
            ?? "Project"

        // A conflict from another project has no meaning here.
        pendingMerges.removeAll()
        isShowingMergeSheet = false

        do {
            var note: String?
            var loadedFromNetwork = false
            var requestFailed = false
            if network.isOnline, let client {
                do {
                    let zip = try await downloadArchive(projectId: projectId, client: client)
                    let staged = try workspace.stage(zip)
                    defer { staged.discard() }

                    if workspace.hasFilesOnDisk {
                        let report = try await reconcile(
                            workspace: workspace, staged: staged, mode: .open,
                            batch: [], client: client, projectId: projectId
                        )
                        pendingMerges.append(contentsOf: report.conflicts)
                        if !report.conflicts.isEmpty { isShowingMergeSheet = true }
                        if !report.merged.isEmpty {
                            note = "Merged Overleaf's changes into \(report.merged.count) file(s)"
                        }
                    } else {
                        try workspace.install(staged)
                        workspace.saveBases(from: staged)
                    }
                    workspace.recordRemoteDigest(staged.digest)
                    loadedFromNetwork = true
                } catch {
                    // A working copy is perfectly usable when the network turns
                    // out to be down, so fall back to it rather than refusing to
                    // open a project the user can already edit.
                    guard Connectivity.isOffline(error), workspace.hasFilesOnDisk else { throw error }
                    isOnline = false
                    requestFailed = true
                    note = "Offline — opened the local copy"
                }
            }
            if !loadedFromNetwork, !workspace.hasFilesOnDisk {
                throw MangroveError.message(
                    "“\(displayName)” has not been downloaded yet. Connect to the internet to open it."
                )
            }

            guard generation == openGeneration else { return }

            self.workspace = workspace
            self.openProjectName = displayName
            self.openProjectId = projectId
            self.selectedProjectId = projectId
            self.fileTree = workspace.fileTree()
            self.unsavedFiles = workspace.modifiedPaths
            self.pendingSyncCount = unsavedFiles.count
            self.pendingCompile = workspace.pendingCompile
            self.pdfData = nil
            self.compilerLog = ""
            self.buildDiagnostics = []
            self.buildSource = .none
            self.lastBuildFailed = false
            self.errorMessage = nil
            self.isDirty = false
            self.openPath = nil
            self.editorText = ""
            self.savedText = ""
            self.openDocuments = []
            self.completionIndex = CompletionIndex()
            self.syncTeX = nil
            self.pdfFocus = nil
            self.lastBuildWasAutomatic = false
            self.projectHistory = ProjectHistory(root: workspace.historyRoot)
            self.refreshCompletionIndex()

            if let remembered = workspace.lastOpenPath,
               workspace.fileExists(remembered),
               TextFileSupport.isProbablyText(remembered) {
                openFile(remembered)
            } else if let main = workspace.rootDocument ?? defaultDocument(in: fileTree) {
                workspace.rootDocument = main
                openFile(main)
            }

            if previousProject == projectId {
                for path in previousTabs where path != openPath
                    && workspace.fileExists(path)
                    && TextFileSupport.isProbablyText(path) {
                    openFile(path)
                }
                if let previousActive, workspace.fileExists(previousActive),
                   TextFileSupport.isProbablyText(previousActive) {
                    openFile(previousActive)
                }
            }

            Defaults.rememberProject(id: projectId, name: displayName)
            statusMessage = note ?? "Loaded \(fileTree.count) items"

            if network.isOnline, !requestFailed {
                startPresenceWatcher(projectId: projectId)
            }

            if network.isOnline, !requestFailed, pendingMerges.isEmpty,
               workspace.hasLocalChanges || workspace.pendingCompile {
                await flushPendingWork()
            }
        } catch {
            guard generation == openGeneration else { return }
            // Put the sidebar back on the project that is actually open.
            selectedProjectId = openProjectId

            if Connectivity.isOffline(error) {
                statusMessage = "Offline — \(displayName) cannot be downloaded right now"
                return
            }
            // A project listed by Overleaf that can no longer be read usually
            // means it was deleted or the user's access was revoked; the list is
            // stale, so refresh it rather than leaving a dead entry behind.
            if case let MangroveError.http(status, _) = error, status == 404 {
                errorMessage = "“\(displayName)” could not be opened. It may have been deleted, or your access to it may have changed."
                await refreshProjects()
                return
            }
            present(error)
        }
    }

    func reloadProject() async {
        guard let projectId = openProjectId ?? selectedProjectId else { return }
        // Local edits are merged with the download rather than discarded; only a
        // genuine conflict needs the user's attention.
        await openProject(projectId)
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
        guard openPath != path else { return }

        stashActiveDocument(writing: true)

        do {
            if let index = openDocuments.firstIndex(where: { $0.path == path }) {
                var document = openDocuments[index]
                // An inactive tab may have been changed on disk by a reload or a
                // merge. A dirty tab holds text that exists nowhere else and wins.
                if !document.isDirty, let disk = try? workspace.readText(path) {
                    document.text = disk
                    document.savedText = disk
                    openDocuments[index] = document
                }
                activate(document)
            } else {
                let text = try workspace.readText(path)
                let document = OpenDocument(path: path, text: text, savedText: text, isDirty: false)
                openDocuments.append(document)
                activate(document)
            }
            refreshCompletionLabels()
        } catch {
            present(error)
        }
    }

    /// Makes an already-open tab active without touching its text.
    private func activate(_ document: OpenDocument) {
        openPath = document.path
        editorText = document.text
        savedText = document.savedText
        isDirty = document.isDirty
        editorJump = nil
        caretLine = 1
        workspace?.lastOpenPath = document.path
        refreshPendingState()
        // Checks belong to the file that is now active, not the previous tab.
        lintTask?.cancel()
        lintDiagnostics = []
        scheduleLint()
    }

    /// Copies the active editor buffer into its tab and, when asked, mirrors a
    /// dirty buffer to disk so a tab switch cannot lose the edit.
    private func stashActiveDocument(writing: Bool) {
        guard let path = openPath,
              let index = openDocuments.firstIndex(where: { $0.path == path }) else { return }
        openDocuments[index].text = editorText
        openDocuments[index].savedText = savedText
        openDocuments[index].isDirty = isDirty
        if writing, isDirty {
            try? workspace?.writeText(path, text: editorText)
            refreshPendingState()
            noteEditForCompile()
        }
    }

    /// A tab's title and dirty dot come from this copy, so it must be refreshed
    /// after every edit and save.
    private func syncActiveTab() {
        guard let path = openPath,
              let index = openDocuments.firstIndex(where: { $0.path == path }) else { return }
        openDocuments[index].text = editorText
        openDocuments[index].savedText = savedText
        openDocuments[index].isDirty = isDirty
    }

    func closeDocument(_ path: String) {
        guard let index = openDocuments.firstIndex(where: { $0.path == path }) else { return }
        if openPath == path {
            stashActiveDocument(writing: true)
            openDocuments.remove(at: index)
            if openDocuments.isEmpty {
                openPath = nil
                editorText = ""
                savedText = ""
                isDirty = false
                editorJump = nil
                autoCompileTask?.cancel()
                autoCompileTask = nil
                autoCompileNeeded = false
                lintTask?.cancel()
                lintDiagnostics = []
            } else {
                let next = min(index, openDocuments.count - 1)
                activate(openDocuments[next])
            }
        } else {
            // A background tab can still hold unsaved text. Mirror it to disk so
            // it joins the upload queue instead of disappearing with the tab.
            let document = openDocuments[index]
            if document.isDirty {
                try? workspace?.writeText(path, text: document.text)
                refreshPendingState()
            }
            openDocuments.remove(at: index)
        }
        refreshCompletionLabels()
    }

    func closeActiveDocument() {
        guard let path = openPath else { return }
        closeDocument(path)
    }

    func closeOtherDocuments() {
        guard let open = openPath else { return }
        for document in openDocuments where document.path != open {
            closeDocument(document.path)
        }
    }

    /// Called as the user types. The text is mirrored to disk shortly after
    /// typing stops, so a crash or a forced quit cannot lose an offline edit —
    /// the next launch notices the file differs from its merge base and queues
    /// it for upload.
    func editorTextChanged(_ text: String) {
        editorText = text
        isDirty = text != savedText
        syncActiveTab()
        scheduleDraftWrite()
        scheduleAutosave()
        refreshCompletionLabels()
        noteEditForCompile()
        scheduleLint()
    }

    private func scheduleDraftWrite() {
        draftTask?.cancel()
        guard let path = openPath, let projectId = openProjectId else { return }
        let text = editorText
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            // A project switch during the delay must not write this buffer into
            // the newly opened project.
            guard self.openProjectId == projectId,
                  self.openPath == path, self.editorText == text else { return }
            self.workspace?.saveDraft(path, text: text)
        }
    }

    /// Overleaf's own editor saves as you type; this is the desktop equivalent,
    /// but slower and only while the queue is actually reachable. The draft write
    /// above is the crash net; this is what makes the change visible to
    /// collaborators without a manual ⌘S.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard autosaveEnabled, isDirty, isOnline,
              !isCompiling, pendingMerges.isEmpty,
              let path = openPath, let projectId = openProjectId else { return }
        let text = editorText
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.openProjectId == projectId, self.openPath == path,
                  self.editorText == text, self.isDirty,
                  self.isOnline, self.pendingMerges.isEmpty else { return }
            _ = await self.save(paths: [path])
        }
    }

    func setAutosave(_ enabled: Bool) {
        autosaveEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Defaults.autosave)
        if !enabled {
            autosaveTask?.cancel()
        } else {
            scheduleAutosave()
        }
    }

    func copyCurrentFileToPasteboard() {
        guard let path = openPath else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editorText, forType: .string)
        statusMessage = "Copied \(path) to the clipboard"
    }

    /// A safe file name for an exported page. Project names may contain slashes
    /// or colons, which the save panel would otherwise read as path syntax.
    static func exportFileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "document" : cleaned) + ".pdf"
    }

    /// Saves the compiled page wherever the user asks. The PDF only exists once
    /// a build has produced one, so callers keep this disabled until then.
    func exportPDF() {
        guard let data = pdfData else {
            errorMessage = "Compile the project before exporting a PDF."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.message = "Save the compiled page from \(projectTitle)."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.exportFileName(for: projectTitle)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            present(error)
        }
    }

    /// Returns whether the edit is safe — on Overleaf when connected, in the
    /// local queue when not.
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
        guard let client, let workspace, let projectId = openProjectId else { return false }

        // The editor holds the newest text, so flush it before reading from disk.
        if let open = openPath, isDirty, paths.contains(open) {
            do {
                try workspace.writeText(open, text: editorText)
                savedText = editorText
                isDirty = false
                syncActiveTab()
            } catch {
                present(error)
                return false
            }
        }
        let textAtStart = editorText

        // Files deleted locally have nothing to upload.
        var uploadable: [String] = []
        for path in paths {
            if workspace.fileExists(path) {
                uploadable.append(path)
            } else {
                workspace.markClean(path)
            }
        }
        refreshPendingState()
        guard !uploadable.isEmpty else {
            errorMessage = "Nothing could be saved. Files deleted here have to be removed on Overleaf itself."
            return false
        }

        guard network.isOnline else {
            return stashForLater(paths: uploadable, reason: "You're offline")
        }

        busyMessage = uploadable.count == 1
            ? "Checking \(uploadable[0])…"
            : "Checking \(uploadable.count) files…"
        defer { busyMessage = nil }

        do {
            let zip = try await downloadArchive(projectId: projectId, client: client)
            let staged = try workspace.stage(zip)
            defer { staged.discard() }

            let report = try await reconcile(
                workspace: workspace, staged: staged, mode: .save,
                batch: Set(uploadable), client: client, projectId: projectId
            )
            refreshPendingState(rebuildTree: true)
            refreshOpenDocument(after: report, textAtStart: textAtStart)

            if !report.conflicts.isEmpty {
                // Never upload over a region both sides changed; ask first.
                pendingMerges.append(contentsOf: report.conflicts)
                isShowingMergeSheet = true
                statusMessage = "\(report.conflicts.count) file(s) need a merge decision"
                return false
            }

            errorMessage = nil
            ignoreRemoteChangesUntil = Date().addingTimeInterval(8)
            recordHistory(paths: report.uploaded)
            refreshCompletionIndex()
            if !report.merged.isEmpty {
                statusMessage = "Merged Overleaf's changes into \(report.merged.count) file(s)"
            } else if !report.uploaded.isEmpty {
                statusMessage = report.uploaded.count == 1
                    ? "Saved \(report.uploaded[0])"
                    : "Saved \(report.uploaded.count) files"
            } else {
                statusMessage = "Already up to date"
            }
            return true
        } catch {
            if Connectivity.isOffline(error) {
                return stashForLater(
                    paths: uploadable, reason: "Overleaf is unreachable"
                )
            }
            showSaveFailure(path: uploadable.first ?? "", error: error)
            return false
        }
    }

    /// Keeps the work on disk and leaves it in the queue. This is a success:
    /// nothing was lost, it simply has not reached Overleaf yet.
    private func stashForLater(paths: [String], reason: String) -> Bool {
        guard workspace != nil else { return false }
        // Everything here is already on disk, and the pending set is what the
        // queue is made of; nothing needs marking again.
        refreshPendingState()
        if let open = openPath, paths.contains(open) {
            savedText = editorText
            isDirty = false
        }
        errorMessage = nil
        statusMessage = "\(reason) — \(pendingSyncCount) file\(pendingSyncCount == 1 ? "" : "s") will sync automatically"
        scheduleRetry()
        return true
    }

    /// Pushes anything left over from an offline session, then runs a compile
    /// that was waiting for a connection.
    func flushPendingWork() async {
        guard isSignedIn, network.isOnline, !isFlushing, !isCompiling,
              let workspace, openProjectId != nil,
              pendingMerges.isEmpty else { return }
        guard workspace.hasLocalChanges || workspace.pendingCompile else { return }

        isFlushing = true
        isSyncing = true
        defer {
            isFlushing = false
            isSyncing = false
        }

        let compileWasQueued = workspace.pendingCompile
        let saved = await saveAllChanges()
        guard saved, pendingSyncCount == 0 else { return }

        if compileWasQueued {
            workspace.pendingCompile = false
            pendingCompile = false
            await saveAndCompile()
        } else {
            statusMessage = "Synced — everything is on Overleaf"
        }
    }

    func syncPendingChanges() {
        Task { await flushPendingWork() }
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

    func beginNewFolder(in parent: String) {
        newFolderParent = parent
        isShowingNewFolderSheet = true
    }

    func createFile(named name: String, in folder: String? = nil) {
        guard let workspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // New files go into the chosen folder, otherwise next to the open file.
        let directory = folder ?? openPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let path = directory.isEmpty ? trimmed : "\(directory)/\(trimmed)"
        do {
            try workspace.createFile(path)
            fileTree = workspace.fileTree()
            openFile(path)
            isDirty = true
            savedText = ""
            refreshPendingState()
            statusMessage = "Created \(path) — save it to send it to Overleaf."
        } catch {
            present(error)
        }
    }

    /// Opens the system file picker and adds the chosen files to the project.
    /// With no folder given they go beside the open file, matching New File; a
    /// folder's context menu passes its own path.
    func chooseFilesToUpload(folder: String? = nil) {
        guard canUploadFiles else {
            errorMessage = "Open the project before uploading files."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Upload to \(projectTitle)"
        panel.message = "Files are copied into the project. An existing file with the same name and folder is replaced."
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return }

        let destination = folder ?? openPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let urls = panel.urls
        Task { await uploadFiles(from: urls, to: destination) }
    }

    /// Copies files into the working copy and sends them. Offline they join the
    /// same queue as any other edit, so the upload runs when the connection
    /// returns.
    func uploadFiles(from urls: [URL], to folder: String) async {
        guard let workspace, openProjectId != nil else {
            errorMessage = "Open a project before uploading files."
            return
        }
        guard !urls.isEmpty else { return }

        let plan = FileImport.plan(urls: urls, folder: folder)
        var imported: [String] = []
        var skipped = plan.skipped.map { "“\($0.name)” \($0.reason)" }

        for item in plan.items {
            // Replacing a file that holds work done on this Mac would throw that
            // work away, so it is refused instead of silently overwritten.
            let hasUnsavedWork = workspace.modifiedPaths.contains(item.relativePath)
                || (openPath == item.relativePath && isDirty)
            if hasUnsavedWork {
                skipped.append("“\(item.name)” has unsaved changes here — save it first")
                continue
            }
            do {
                try workspace.importFile(from: item.source, as: item.relativePath)
                imported.append(item.relativePath)
            } catch {
                skipped.append("“\(item.name)” could not be read")
            }
        }

        guard !imported.isEmpty else {
            errorMessage = skipped.isEmpty
                ? "Nothing was uploaded."
                : "Nothing was uploaded — " + skipped.joined(separator: " · ")
            return
        }

        fileTree = workspace.fileTree()
        refreshPendingState()
        lastImportedPath = imported.first

        busyMessage = imported.count == 1
            ? "Uploading \(imported[0])…"
            : "Uploading \(imported.count) files…"
        let saved = await save(paths: imported)
        busyMessage = nil

        if saved, isOnline, pendingSyncCount == 0, pendingMerges.isEmpty {
            statusMessage = imported.count == 1
                ? "Uploaded \(imported[0])"
                : "Uploaded \(imported.count) files"
        }

        // Never replace a real upload error with the list of files the picker
        // refused; one is a failure, the other is a note about the rest.
        if skipped.isEmpty {
            if !saved, pendingMerges.isEmpty, errorMessage == nil {
                errorMessage = "The files were added locally but have not reached Overleaf yet."
            }
        } else {
            let note = "Not uploaded: " + skipped.joined(separator: " · ")
            errorMessage = errorMessage.map { "\($0) \(note)" } ?? note
        }
    }

    func deleteFile(_ path: String) {
        guard let workspace else { return }
        do {
            try workspace.deleteFile(path)
            workspace.removeBase(path)
            fileTree = workspace.fileTree()
            if openPath == path {
                openPath = nil
                editorText = ""
                savedText = ""
                isDirty = false
            }
            refreshPendingState()
            statusMessage = "Removed \(path) locally. Overleaf still has it — delete it there to remove it from the project."
        } catch {
            present(error)
        }
    }

    // MARK: - Merging

    /// Resolves one queued conflict. `choices` is one entry per conflicting
    /// region; `nil` keeps the local file wholesale.
    func resolveMerge(_ merge: PendingMerge, choosingTheirs choices: [Bool]?) {
        guard let workspace else { return }
        do {
            if merge.isBinary {
                if choices != nil, let remote = merge.remoteData {
                    try workspace.writeRemote(merge.path, data: remote)
                    workspace.saveBase(merge.path, data: remote)
                    if openPath == merge.path { openFile(merge.path) }
                    statusMessage = "Kept Overleaf's version of \(merge.path)"
                } else if choices != nil, merge.remoteData == nil {
                    // Overleaf no longer has the file, so taking its side means
                    // removing the local copy.
                    try? workspace.removeLocal(merge.path)
                    workspace.removeBase(merge.path)
                    if openPath == merge.path { openFile(merge.path) }
                    statusMessage = "Removed \(merge.path) to match Overleaf"
                } else {
                    // Keeping the local copy: make the remote version the base so
                    // the next save uploads this file instead of re-merging it.
                    workspace.saveBase(merge.path, data: merge.remoteData)
                    statusMessage = "Keeping your version of \(merge.path)"
                }
                pendingMerges.removeAll { $0.id == merge.id }
                isShowingMergeSheet = !pendingMerges.isEmpty
                refreshPendingState()
                if choices != nil { return }
                Task { await save(paths: [merge.path]) }
                return
            }

            let text: String
            if let choices {
                text = LineMerge.resolve(
                    mine: merge.mine, base: merge.base, theirs: merge.theirs,
                    choosingTheirs: choices
                )
            } else {
                text = merge.mine
            }
            try workspace.writeText(merge.path, text: text)
            // The remote version is the new common ancestor, so saving the
            // resolved text will not re-merge the same conflict.
            workspace.saveBase(merge.path, data: Data(merge.theirs.utf8))
            pendingMerges.removeAll { $0.id == merge.id }
            isShowingMergeSheet = !pendingMerges.isEmpty
            refreshPendingState()

            if openPath == merge.path {
                editorText = text
                savedText = text
                isDirty = false
            }
            noteEditForCompile()
            scheduleLint()
            statusMessage = "Merged \(merge.path) — saving"
            Task { await save(paths: [merge.path]) }
        } catch {
            present(error)
        }
    }

    func dismissMergeSheet() {
        isShowingMergeSheet = false
    }

    func showNextMerge() {
        if !pendingMerges.isEmpty { isShowingMergeSheet = true }
    }

    /// Re-reads the working copy after a merge so the editor and sidebar show
    /// what is actually on disk.
    private func refreshOpenDocument(after report: SyncReport, textAtStart: String) {
        guard let workspace else { return }

        // Background tabs were uploaded too; their in-memory copy has to learn
        // that the save happened.
        for index in openDocuments.indices {
            let path = openDocuments[index].path
            guard path != openPath else { continue }
            guard report.uploaded.contains(path) || report.merged.contains(path)
                    || report.adopted.contains(path) else { continue }
            if let text = try? workspace.readText(path) {
                openDocuments[index].text = text
                openDocuments[index].savedText = text
                openDocuments[index].isDirty = false
            }
        }

        guard let open = openPath else { return }
        if report.merged.contains(open) || report.adopted.contains(open) {
            if let text = try? workspace.readText(open) {
                editorText = text
                savedText = text
                isDirty = false
            }
        } else if report.uploaded.contains(open), editorText == textAtStart {
            savedText = editorText
            isDirty = false
        }
        syncActiveTab()
    }

    // MARK: - Build

    func saveAndCompile(automatic: Bool = false) async {
        guard openProjectId != nil else { return }
        autoCompileTask?.cancel()
        autoCompileTask = nil
        autoCompileNeeded = false
        lastBuildWasAutomatic = automatic
        // Compile builds whatever Overleaf currently has, so every edit has to be
        // uploaded first — unless the upload had to be queued.
        let saved = await saveAllChanges()

        guard pendingMerges.isEmpty else {
            // Building now would compile a file that is still being decided on.
            statusMessage = "Resolve the merge conflict before compiling"
            isShowingMergeSheet = true
            return
        }
        guard network.isOnline else {
            await compileWithoutOverleaf(
                queueIfUnavailable: !automatic, automatic: automatic
            )
            return
        }
        guard saved, pendingSyncCount == 0 else {
            statusMessage = "Compile skipped — the latest changes are not on Overleaf yet"
            return
        }

        guard let client, let projectId = openProjectId else { return }
        isCompiling = true
        buildDiagnostics = []
        // A remote page has no local SyncTeX map; an old local one would point at
        // the wrong document.
        syncTeX = nil
        defer {
            isCompiling = false
            if autoCompileNeeded { scheduleAutoCompile() }
        }

        do {
            let result = try await client.compile(projectId: projectId, draft: draftMode)
            // The previous PDF stays on screen while the new one downloads; the
            // viewer restores the page and zoom when it is replaced.

            if result.succeeded || result.pdf != nil {
                if let pdf = result.pdf {
                    pdfData = try await client.download(output: pdf, from: result, projectId: projectId)
                }
                compilerLog = await loadLog(from: result, client: client, projectId: projectId)
                updateDiagnostics(
                    log: compilerLog,
                    validation: result.rawJSON["validationProblems"] as? [String: Any]
                )
                buildSource = .overleaf
                lastBuildFailed = !result.succeeded
                buildRevision += 1
                if result.succeeded {
                    statusMessage = automatic
                        ? "Compiled automatically on Overleaf"
                        : "Saved and compiled on Overleaf"
                    if !automatic, rightPane == .editor { rightPane = .split }
                } else {
                    statusMessage = "Compile finished with status “\(result.status)”"
                }
            } else {
                compilerLog = await loadLog(from: result, client: client, projectId: projectId)
                if compilerLog.isEmpty {
                    compilerLog = "Overleaf reported status “\(result.status)” with no log."
                }
                updateDiagnostics(
                    log: compilerLog,
                    validation: result.rawJSON["validationProblems"] as? [String: Any]
                )
                buildSource = .overleaf
                lastBuildFailed = true
                buildRevision += 1
                statusMessage = "Compile failed — see the build log"
                // Surface the Problems tab: a failure that leaves the pane hidden
                // tells the reader nothing beyond the status line. An automatic
                // build stays quiet; its badge is enough.
                if !automatic, rightPane == .editor { rightPane = .split }
            }
        } catch {
            if Connectivity.isOffline(error) {
                await compileWithoutOverleaf(
                    queueIfUnavailable: !automatic, automatic: automatic
                )
            } else {
                present(error)
            }
        }
    }

    /// Compiles on this Mac when Overleaf cannot be reached. Without a TeX
    /// installation there is nothing to compile with, so the request is queued
    /// instead — that is a limitation, not a failure.
    private func compileWithoutOverleaf(
        queueIfUnavailable: Bool, automatic: Bool = false
    ) async {
        guard let workspace, openProjectId != nil else { return }
        let tool = LocalLaTeX.detect()
        localTeXAvailable = tool != nil

        guard let tool else {
            if automatic {
                statusMessage = "Auto-compile skipped — no local LaTeX and Overleaf is unreachable"
                return
            }
            if queueIfUnavailable {
                workspace.pendingCompile = true
                pendingCompile = true
                statusMessage = "Compile queued until Overleaf is reachable"
                errorMessage = "This compile is queued until the connection returns. No local LaTeX was found either — install BasicTeX or MacTeX to compile offline."
                scheduleRetry()
            } else {
                errorMessage = "No local LaTeX was found. Install BasicTeX or MacTeX to compile offline."
            }
            return
        }

        guard let document = workspace.rootDocument
            ?? defaultDocument(in: fileTree)
            ?? (openPath?.hasSuffix(".tex") == true ? openPath : nil) else {
            errorMessage = "No LaTeX document was found in this project to compile."
            return
        }
        workspace.rootDocument = document

        lastBuildWasAutomatic = automatic
        isCompiling = true
        busyMessage = "Compiling locally…"
        buildDiagnostics = []
        defer {
            isCompiling = false
            busyMessage = nil
            if autoCompileNeeded { scheduleAutoCompile() }
        }

        do {
            let output = try await tool.build(
                projectRoot: workspace.root,
                mainFile: document,
                outputDirectory: workspace.buildDirectory
            )
            pdfData = output.pdf
            compilerLog = output.log
            updateDiagnostics(log: output.log)
            syncTeX = SyncTeX.locate(
                engine: tool.executable, pdfURL: output.pdfURL, projectRoot: workspace.root
            )
            buildSource = .local
            lastBuildFailed = !output.succeeded
            buildRevision += 1
            workspace.pendingCompile = false
            pendingCompile = false
            if !automatic, rightPane == .editor { rightPane = .split }
            if output.succeeded {
                statusMessage = automatic
                    ? "Auto-compiled locally with \(tool.tool.rawValue)\(isOnline ? "" : " — offline")"
                    : "Compiled locally with \(tool.tool.rawValue)\(isOnline ? "" : " — offline")"
            } else {
                statusMessage = "Local compile finished with errors — see the build log"
            }
        } catch {
            buildSource = .none
            lastBuildFailed = true
            syncTeX = nil
            compilerLog = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            buildDiagnostics = []
            buildRevision += 1
            if automatic {
                statusMessage = "Auto-compile failed — see the build log"
            } else {
                errorMessage = compilerLog
            }
        }
    }

    func compileLocally() {
        autoCompileTask?.cancel()
        autoCompileTask = nil
        autoCompileNeeded = false
        lastBuildWasAutomatic = false
        Task { await compileWithoutOverleaf(queueIfUnavailable: false) }
    }

    /// Parses the log once, here, so the pane and the status bar agree about
    /// what failed and where.
    private func updateDiagnostics(log: String, validation: [String: Any]? = nil) {
        let known = Set(workspace?.allPaths() ?? [])
        let root = workspace?.rootDocument
            ?? (openPath?.lowercased().hasSuffix(".tex") == true ? openPath : nil)
        buildDiagnostics = BuildLogParser.diagnostics(
            log: log,
            defaultFile: root,
            knownFiles: known,
            validation: validation
        )
    }

    // MARK: - Completion

    /// Rebuilds the citation keys from every bibliography and the labels from
    /// every document in the project. Called when a project opens and after a
    /// save, not on every keystroke.
    func refreshCompletionIndex() {
        guard let workspace else {
            completionIndex = CompletionIndex()
            return
        }
        var citations: [String] = []
        var labels: [String] = []
        for path in workspace.allPaths() {
            let ext = (path as NSString).pathExtension.lowercased()
            guard ext == "bib" || ext == "tex" || ext == "ltx" || ext == "latex" else { continue }
            guard let data = workspace.readDataIfPresent(path), data.count < 512 * 1024,
                  let text = String(data: data, encoding: .utf8) else { continue }
            if ext == "bib" {
                citations.append(contentsOf: CompletionIndex.bibliographyKeys(in: text))
            } else {
                labels.append(contentsOf: CompletionIndex.labels(in: text))
            }
        }
        completionIndex = CompletionIndex(
            citationKeys: Self.orderedUnique(citations),
            referenceKeys: Self.orderedUnique(labels)
        )
        scheduleLint()
    }

    /// Labels live in the file being edited, so they follow the buffer instead of
    /// waiting for a save. Citation keys only change when a `.bib` changes.
    private func refreshCompletionLabels() {
        guard openPath?.lowercased().hasSuffix(".tex") == true
                || openPath?.lowercased().hasSuffix(".ltx") == true
                || openPath?.lowercased().hasSuffix(".latex") == true else { return }
        let labels = CompletionIndex.labels(in: editorText)
        if completionIndex.referenceKeys != labels {
            completionIndex.referenceKeys = labels
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - History

    var historyForOpenFile: [HistorySnapshot] {
        guard let path = openPath else { return [] }
        return projectHistory?.snapshots(for: path) ?? []
    }

    func historyContents(_ snapshot: HistorySnapshot) -> String? {
        projectHistory?.contents(of: snapshot)
    }

    /// Puts an old revision back in the editor as an unsaved change. Nothing is
    /// uploaded until the reader saves or autosave fires, so restoring is safe to
    /// try and easy to undo.
    func restoreHistory(_ snapshot: HistorySnapshot) {
        guard let text = projectHistory?.contents(of: snapshot), openPath == snapshot.path else {
            errorMessage = "That version is no longer on disk."
            return
        }
        editorText = text
        isDirty = text != savedText
        syncActiveTab()
        scheduleDraftWrite()
        scheduleAutosave()
        noteEditForCompile()
        scheduleLint()
        isShowingHistory = false
        statusMessage = "Restored \(snapshot.path) from \(Self.historyDateFormatter.string(from: snapshot.savedAt)) — save to keep it"
    }

    private func recordHistory(paths: [String]) {
        guard let workspace, let history = projectHistory else { return }
        for path in paths where TextFileSupport.isProbablyText(path) {
            guard let text = try? workspace.readText(path) else { continue }
            history.record(path: path, text: text)
        }
    }

    static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Project search

    /// Files the search engine is allowed to read. Big binaries and assets are
    /// skipped rather than decoded a second time.
    private func searchableFiles() -> [SearchableFile] {
        guard let workspace else { return [] }
        var files: [SearchableFile] = []
        for path in workspace.allPaths() {
            guard TextFileSupport.isProbablyText(path),
                  let data = workspace.readDataIfPresent(path), data.count < 1024 * 1024,
                  let text = String(data: data, encoding: .utf8) else { continue }
            files.append(SearchableFile(path: path, text: text))
        }
        return files
    }

    func searchProject(query: String, options: ProjectSearchOptions) -> [ProjectSearchHit] {
        ProjectSearch.hits(query: query, files: searchableFiles(), options: options)
    }

    func revealSearchHit(_ hit: ProjectSearchHit) {
        openFile(hit.path)
        guard openPath == hit.path else { return }
        editorMode = .code
        editorJump = EditorJump(range: hit.range)
    }

    /// Applies the replacement to every file in the project and uploads the ones
    /// that changed. The working copy is the batch: one merge check covers all
    /// the files, and a conflict is handled once, not per keystroke.
    @discardableResult
    func replaceAllProject(
        query: String, with replacement: String, options: ProjectSearchOptions
    ) async -> Int {
        guard let workspace else { return 0 }
        var changed: [String] = []
        var replacements = 0
        for file in searchableFiles() {
            guard let newText = ProjectSearch.replacing(
                in: file.text, query: query, with: replacement, options: options
            ), newText != file.text else { continue }
            do {
                try workspace.writeText(file.path, text: newText)
                replacements += ProjectSearch.matchCount(query: query, in: file.text, options: options)
                changed.append(file.path)
            } catch {
                present(error)
            }
        }

        guard !changed.isEmpty else {
            statusMessage = "No matches to replace"
            return 0
        }

        if let open = openPath, changed.contains(open), let text = try? workspace.readText(open) {
            editorText = text
            savedText = text
            isDirty = false
            syncActiveTab()
        }
        noteEditForCompile()
        scheduleLint()
        fileTree = workspace.fileTree()
        refreshPendingState()
        refreshCompletionLabels()

        if network.isOnline {
            _ = await save(paths: changed)
        } else {
            statusMessage = "Replaced \(replacements) in \(changed.count) files — queued until you're online"
        }
        return replacements
    }

    // MARK: - SyncTeX

    var syncTeXAvailable: Bool { syncTeX != nil }

    /// A double-click on a locally built page. Coordinates arrive from the page's
    /// top-left corner, in points, which is what `synctex edit` expects.
    func jumpFromPDF(page: Int, x: Double, y: Double) {
        guard let syncTeX else {
            statusMessage = "SyncTeX is only available for pages compiled on this Mac"
            return
        }
        Task { [weak self] in
            guard let location = await syncTeX.source(forPage: page, x: x, y: y) else {
                self?.statusMessage = "No source line maps to that point"
                return
            }
            guard let self else { return }
            self.openSource(at: location)
        }
    }

    /// Shows the caret's line on the compiled page when the page came from a
    /// local build.
    func revealInPDF() {
        guard let syncTeX else {
            statusMessage = "SyncTeX is only available for pages compiled on this Mac"
            return
        }
        guard let open = openPath, open.hasSuffix(".tex") || open.hasSuffix(".ltx") else { return }
        let line = caretLine
        Task { [weak self] in
            guard let target = await syncTeX.target(forFile: open, line: line) else {
                self?.statusMessage = "That line has no place on the page yet"
                return
            }
            guard let self else { return }
            self.pdfFocus = PDFFocus(page: target.page, x: target.x, y: target.y)
            if self.rightPane == .editor { self.rightPane = .split }
            self.statusMessage = "Line \(line) is on page \(target.page)"
        }
    }

    private func openSource(at location: SyncTeX.SourceLocation) {
        guard let workspace else { return }
        let root = workspace.root.standardizedFileURL.path
        var path = location.file
        if path.hasPrefix(root + "/") {
            path = String(path.dropFirst(root.count + 1))
        } else if let range = path.range(of: workspace.root.lastPathComponent + "/" ) {
            path = String(path[range.upperBound...])
        } else {
            path = (path as NSString).lastPathComponent
        }
        guard workspace.fileExists(path), TextFileSupport.isProbablyText(path) else {
            statusMessage = "The mapped source file is not part of this project"
            return
        }
        if openPath != path { openFile(path) }
        guard openPath == path else { return }
        editorMode = .code
        editorJump = EditorJump(range: Self.range(ofLine: location.line, in: editorText))
    }

    // MARK: - File operations

    /// Overleaf's write routes are id-based; the ids arrive with the realtime
    /// join. Resolving at the moment of the operation keeps a rename made in the
    /// browser from leaving the app with a stale id.
    private func entityTree(projectId: String) async throws -> ProjectEntityTree {
        guard let client else { throw MangroveError.message("Not signed in.") }
        return try await client.projectTree(projectId: projectId)
    }

    func createFolder(named name: String, in parent: String) async {
        guard let workspace, let client, let projectId = openProjectId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            errorMessage = "A folder name cannot be empty or contain a slash."
            return
        }
        guard network.isOnline else {
            errorMessage = "Creating a folder needs a connection so Overleaf and the working copy stay in step."
            return
        }
        let path = parent.isEmpty ? trimmed : "\(parent)/\(trimmed)"
        guard !workspace.fileExists(path) else {
            errorMessage = "“\(trimmed)” already exists here."
            return
        }
        busyMessage = "Creating \(trimmed)…"
        defer { busyMessage = nil }
        do {
            let tree = try await entityTree(projectId: projectId)
            let parentId = parent.isEmpty ? tree.rootFolderId : tree.folder(at: parent)?.id
            guard let parentId else {
                errorMessage = "Overleaf did not report the folder structure for this project."
                return
            }
            try await client.createFolder(projectId: projectId, name: trimmed, parentFolderId: parentId)
            try workspace.createDirectory(path)
            ignoreRemoteChangesUntil = Date().addingTimeInterval(8)
            fileTree = workspace.fileTree()
            isShowingNewFolderSheet = false
            statusMessage = "Created \(path)"
        } catch {
            present(error)
        }
    }

    func rename(_ request: FileNameRequest, to name: String) async {
        guard let workspace, openProjectId != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != request.currentName else {
            renameRequest = nil
            return
        }
        let parent = (request.path as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? trimmed : "\(parent)/\(trimmed)"
        guard !workspace.fileExists(destination) else {
            errorMessage = "“\(trimmed)” already exists here."
            return
        }
        await performEntityOperation(
            path: request.path,
            failure: "Could not rename “\(request.currentName)”:",
            commit: {
                try workspace.moveItem(from: request.path, to: destination)
                self.repathOpenDocuments(from: request.path, to: destination)
                self.renameRequest = nil
                self.statusMessage = "Renamed to \(trimmed)"
            },
            remote: { client, projectId, entity in
                try await client.renameEntity(
                    projectId: projectId, type: entity.kind, id: entity.id, name: trimmed
                )
            }
        )
    }

    func move(_ request: FileMoveRequest, to folder: String) async {
        guard let workspace, openProjectId != nil else { return }
        let name = request.name
        let destination = folder.isEmpty ? name : "\(folder)/\(name)"
        guard destination != request.path, !workspace.fileExists(destination) else {
            errorMessage = "“\(name)” already exists in that folder."
            return
        }
        await performEntityOperation(
            path: request.path,
            failure: "Could not move “\(name)”:",
            commit: {
                try workspace.moveItem(from: request.path, to: destination)
                self.repathOpenDocuments(from: request.path, to: destination)
                self.moveRequest = nil
                self.statusMessage = "Moved \(name) to \(folder.isEmpty ? "the project root" : folder)"
            },
            remote: { client, projectId, entity in
                let tree = try await client.projectTree(projectId: projectId)
                guard let destinationId = folder.isEmpty ? tree.rootFolderId : tree.folder(at: folder)?.id else {
                    throw MangroveError.message("Overleaf did not report the destination folder.")
                }
                try await client.moveEntity(
                    projectId: projectId, type: entity.kind, id: entity.id, folderId: destinationId
                )
            }
        )
    }

    func delete(_ request: FileDeleteRequest) async {
        guard let workspace, openProjectId != nil else { return }
        await performEntityOperation(
            path: request.path,
            failure: "Could not delete “\(request.name)”:",
            commit: {
                // The server copy is gone, so the local copy must not be queued
                // for upload afterwards.
                let affected = self.openDocuments.filter {
                    ProjectWorkspace.isInside($0.path, folder: request.path)
                }
                if let active = affected.first(where: { $0.path == self.openPath }) {
                    self.openPath = nil
                    self.editorText = ""
                    self.savedText = ""
                    self.isDirty = false
                    self.lintTask?.cancel()
                    self.lintDiagnostics = []
                    self.autoCompileTask?.cancel()
                    self.autoCompileTask = nil
                    self.autoCompileNeeded = false
                    self.statusMessage = "Closed \(active.path)"
                }
                self.openDocuments.removeAll {
                    ProjectWorkspace.isInside($0.path, folder: request.path)
                }
                try workspace.removeItem(at: request.path)
                self.fileTree = workspace.fileTree()
                self.deleteRequest = nil
                self.statusMessage = "Deleted \(request.name) from Overleaf"
            },
            remote: { client, projectId, entity in
                try await client.deleteEntity(projectId: projectId, type: entity.kind, id: entity.id)
            }
        )
    }

    /// Resolves the entity, checks the connection and the tree, performs the
    /// remote operation, then commits the same change locally. The local commit
    /// only runs after Overleaf accepted it, so the two cannot disagree after a
    /// failure.
    private func performEntityOperation(
        path: String,
        failure: String,
        commit: @escaping () throws -> Void,
        remote: @escaping (OverleafClient, String, ProjectEntity) async throws -> Void
    ) async {
        guard let client, let projectId = openProjectId else { return }
        guard network.isOnline else {
            errorMessage = "This needs a connection so Overleaf and the working copy stay in step."
            return
        }
        busyMessage = "Updating \(path)…"
        defer { busyMessage = nil }
        do {
            let tree = try await entityTree(projectId: projectId)
            guard let entity = tree.entity(at: path) else {
                errorMessage = "Overleaf no longer has “\(path)”. Reload the project to refresh the tree."
                return
            }
            try await remote(client, projectId, entity)
            try commit()
            ignoreRemoteChangesUntil = Date().addingTimeInterval(8)
            fileTree = workspace?.fileTree() ?? fileTree
            refreshPendingState()
            refreshCompletionLabels()
        } catch {
            errorMessage = "\(failure) \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Moves open tabs when their path moves with a rename or a folder move.
    private func repathOpenDocuments(from source: String, to destination: String) {
        for index in openDocuments.indices {
            let path = openDocuments[index].path
            guard ProjectWorkspace.isInside(path, folder: source) else { continue }
            let suffix = String(path.dropFirst(source.count))
            let document = openDocuments[index]
            openDocuments[index] = OpenDocument(
                path: destination + suffix,
                text: document.text,
                savedText: document.savedText,
                isDirty: document.isDirty
            )
        }
        if let open = openPath, ProjectWorkspace.isInside(open, folder: source) {
            openPath = destination + String(open.dropFirst(source.count))
            workspace?.lastOpenPath = openPath
        }
    }

    // MARK: - Presence and remote changes

    /// Keeps a realtime connection open for collaborators and remote saves. This
    /// is deliberately quiet: presence is a convenience, and a failed socket must
    /// never interrupt editing or saving.
    private func startPresenceWatcher(projectId: String) {
        presenceTask?.cancel()
        presenceStream?.close()
        presenceStream = nil
        collaborators = []
        guard let session, network.isOnline else { return }

        let baseURL = self.baseURL
        let cookies = session.cookieHeader()
        let task = Task { [weak self] in
            let channel = RealtimeChannel(
                baseURL: baseURL,
                cookieHeader: cookies,
                userAgent: OverleafClient.userAgent,
                log: { SyncDiagnostics.write($0) }
            )
            do {
                let stream = try await channel.openStream(projectId)
                guard !Task.isCancelled else { stream.close(); return }
                self?.adopt(stream, projectId: projectId)
            } catch {
                SyncDiagnostics.write("presence stream failed: \(error.localizedDescription)")
            }
        }
        presenceTask = task
    }

    private func adopt(_ stream: RealtimeStream, projectId: String) {
        presenceStream = stream
        stream.onEvent = { [weak self] name, args in
            guard let payload = args.compactMap({ $0 as? [String: Any] }).first else { return }
            Task { @MainActor in self?.handleRealtimeEvent(name: name, payload: payload, projectId: projectId) }
        }
        stream.onClose = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.openProjectId == projectId else { return }
                self.collaborators = []
            }
        }
    }

    private func handleRealtimeEvent(name: String, payload: [String: Any], projectId: String) {
        guard openProjectId == projectId else { return }

        if let update = RealtimePresence.update(name: name, payload: payload) {
            collaborators.removeAll { $0.id == update.id }
            if update.online {
                collaborators.append(Collaborator(
                    id: update.id,
                    name: update.name,
                    initials: RealtimePresence.initials(for: update.name)
                ))
            }
            return
        }

        if RealtimePresence.remoteChangeEvents.contains(name),
           Date() >= ignoreRemoteChangesUntil {
            remoteChangeDetected = true
        }
    }

    /// Reloads the working copy after someone else changed the project, then
    /// reconnects presence. Local edits are merged, never discarded.
    func loadRemoteChanges() async {
        remoteChangeDetected = false
        await reloadProject()
        if let projectId = openProjectId {
            startPresenceWatcher(projectId: projectId)
        }
    }

    // MARK: - Dropped images

    /// Copies dropped files into the document's folder, inserts an
    /// `\includegraphics` line at the drop point and uploads the images. The
    /// `.tex` edit stays local until the document is saved, like any other typing.
    func insertDroppedFiles(_ urls: [URL], at location: Int) {
        guard let workspace, openProjectId != nil else { return }
        guard let open = openPath, open.hasSuffix(".tex") || open.hasSuffix(".ltx") else {
            statusMessage = "Drop images into a .tex file to insert them"
            return
        }
        let folder = (open as NSString).deletingLastPathComponent
        var imported: [String] = []
        var snippets: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let destination = folder.isEmpty ? name : "\(folder)/\(name)"
            do {
                try workspace.importFile(from: url, as: destination)
                imported.append(destination)
                let reference = ((destination as NSString).deletingPathExtension)
                    .replacingOccurrences(of: " ", with: " ")
                snippets.append("\\includegraphics[width=\\linewidth]{\(reference)}")
            } catch {
                errorMessage = "Could not read \(name)."
            }
        }
        guard !snippets.isEmpty else { return }

        let text = editorText as NSString
        let safeLocation = min(max(location, 0), text.length)
        let insertion = snippets.joined(separator: "\n")
        editorText = text.replacingCharacters(in: NSRange(location: safeLocation, length: 0), with: insertion)
        isDirty = true
        syncActiveTab()
        scheduleDraftWrite()
        noteEditForCompile()
        scheduleLint()
        fileTree = workspace.fileTree()
        refreshPendingState()
        if network.isOnline {
            Task { _ = await save(paths: imported) }
        }
        statusMessage = snippets.count == 1
            ? "Inserted \(imported[0]) — save the document to compile with it"
            : "Inserted \(snippets.count) images"
    }

    /// Takes a compiler problem to its source line, switching back to code so
    /// the caret lands somewhere that can actually be edited.
    func revealDiagnostic(_ diagnostic: BuildDiagnostic) {
        if let file = diagnostic.file, !file.isEmpty, file != openPath {
            guard let workspace, workspace.fileExists(file),
                  TextFileSupport.isProbablyText(file) else {
                statusMessage = "\(file) is not editable in this project"
                return
            }
            openFile(file)
            guard openPath == file else { return }
        }
        editorMode = .code
        editorJump = EditorJump(range: Self.range(ofLine: diagnostic.line ?? 1, in: editorText))
    }

    /// Shows a block of the visual editor at its exact place in the source.
    func revealInCode(range: NSRange) {
        editorMode = .code
        editorJump = EditorJump(range: range)
    }

    /// Takes an outline heading to the source. Heads are read in code mode so the
    /// caret lands on the command rather than a formatted copy of the title.
    func revealOutlineItem(_ item: OutlineItem) {
        editorMode = .code
        editorJump = EditorJump(range: NSRange(location: item.location, length: 0))
    }

    static func range(ofLine line: Int, in text: String) -> NSRange {
        let source = text as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }

        var current = 1
        var start = 0
        var index = 0
        let target = max(line, 1)
        while index < source.length, current < target {
            if source.character(at: index) == 10 {
                current += 1
                start = index + 1
            }
            index += 1
        }
        var end = start
        while end < source.length, source.character(at: end) != 10 { end += 1 }
        let location = min(start, source.length)
        return NSRange(location: location, length: min(end, source.length) - location)
    }

    private func loadLog(from result: CompileResult, client: OverleafClient, projectId: String) async -> String {
        if let problems = result.validationSummary { return problems }
        guard let log = result.log else { return "" }
        guard let data = try? await client.download(output: log, from: result, projectId: projectId) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reconciliation

    private enum SyncMode {
        case open
        case save
    }

    private struct SyncReport {
        var uploaded: [String] = []
        var merged: [String] = []
        var adopted: [String] = []
        var conflicts: [PendingMerge] = []
    }

    /// Compares the working copy with a freshly downloaded project and does the
    /// least destructive thing per file: upload, adopt, merge, or ask.
    private func reconcile(
        workspace: ProjectWorkspace,
        staged: StagedProject,
        mode: SyncMode,
        batch: Set<String>,
        client: OverleafClient,
        projectId: String
    ) async throws -> SyncReport {
        var report = SyncReport()
        let remotePaths = Set(staged.filePaths)
        let localPaths = Set(workspace.allPaths())
        let modified = Set(workspace.modifiedPaths)

        var candidates = remotePaths
        switch mode {
        case .open:
            candidates.formUnion(localPaths)
        case .save:
            candidates.formUnion(batch)
            // Files with no local edits can follow Overleaf silently.
            candidates.formUnion(remotePaths.subtracting(modified))
        }

        for path in candidates.sorted() {
            // A file with edits that are not part of this save is left for its
            // own save to merge.
            if mode == .save, modified.contains(path), !batch.contains(path) { continue }

            let local = workspace.readDataIfPresent(path)
            let remote = staged.data(for: path)
            let base = workspace.baseData(path)
            let isText = TextFileSupport.isProbablyText(path)

            switch SyncPlanner.action(local: local, base: base, remote: remote, isText: isText) {
            case .unchanged:
                if let remote {
                    workspace.saveBase(path, data: remote)
                } else {
                    workspace.removeBase(path)
                }
                // Identical on both sides means there is nothing left to send.
                workspace.markClean(path)

            case .adoptRemote:
                if let remote {
                    try workspace.writeRemote(path, data: remote)
                    workspace.saveBase(path, data: remote)
                } else {
                    try? workspace.removeLocal(path)
                    workspace.removeBase(path)
                }
                report.adopted.append(path)

            case .uploadLocal:
                if mode == .save, batch.contains(path), let local {
                    try await client.saveFile(
                        projectId: projectId, relativePath: path, contents: local
                    )
                    workspace.saveBase(path, data: local)
                    workspace.markClean(path)
                    report.uploaded.append(path)
                } else if mode == .open, !modified.contains(path), local != nil {
                    // A local file that differs from a base we never uploaded.
                    // (`local` is nil for a file the user removed here; it is
                    // not pending, so it must not be queued.)
                    workspace.markDirty(path)
                }

            case let .merge(mine, ancestor, theirs):
                switch LineMerge.merge(mine: mine, base: ancestor, theirs: theirs) {
                case let .clean(text):
                    try workspace.writeText(path, text: text)
                    // The remote copy is the new common ancestor.
                    workspace.saveBase(path, data: Data(theirs.utf8))
                    report.merged.append(path)

                    if mode == .save, batch.contains(path) {
                        try await client.saveFile(
                            projectId: projectId, relativePath: path, contents: Data(text.utf8)
                        )
                        workspace.saveBase(path, data: Data(text.utf8))
                        workspace.markClean(path)
                        report.uploaded.append(path)
                    }
                case let .conflicted(_, conflicts):
                    report.conflicts.append(PendingMerge(
                        path: path, mine: mine, base: ancestor, theirs: theirs,
                        kind: .text(conflicts), localData: local, remoteData: remote
                    ))
                }

            case .conflict:
                report.conflicts.append(PendingMerge(
                    path: path, mine: "", base: "", theirs: "",
                    kind: .binary, localData: local, remoteData: remote
                ))
            }
        }

        // Files deleted on Overleaf: drop the clean local copies.
        if mode == .open {
            for path in localPaths.subtracting(remotePaths) where !modified.contains(path) {
                try? workspace.removeLocal(path)
                workspace.removeBase(path)
            }
        }

        workspace.recordRemoteDigest(staged.digest)
        return report
    }

    // MARK: - Scheduling

    func setAutoCompile(_ enabled: Bool) {
        autoCompileEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Defaults.autoCompile)
        if enabled {
            scheduleAutoCompile()
        } else {
            autoCompileTask?.cancel()
            autoCompileTask = nil
        }
    }

    /// Called when the reader switches away from the source-only layout. The
    /// page cannot be refreshed while it is hidden, so the pending edit waits.
    func pageVisibilityChanged() {
        if rightPane == .editor {
            autoCompileTask?.cancel()
            autoCompileTask = nil
        } else {
            scheduleAutoCompile()
        }
    }

    private func noteEditForCompile() {
        autoCompileNeeded = true
        scheduleAutoCompile()
    }

    /// Waits for a pause in editing before spending a compile. The timer is
    /// restarted by every edit; the source-only layout, a merge decision, an
    /// open project transition and the connection all gate it.
    private func scheduleAutoCompile() {
        autoCompileTask?.cancel()
        autoCompileTask = nil
        guard autoCompileEnabled, autoCompileNeeded, openProjectId != nil,
              !isOpeningProject, !isCompiling, pendingMerges.isEmpty,
              rightPane != .editor, isOnline || localTeXAvailable else { return }

        autoCompileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: IdleCompilePolicy.delay)
            guard !Task.isCancelled, let self else { return }
            await self.runAutoCompile()
        }
    }

    private func runAutoCompile() async {
        autoCompileTask = nil
        guard IdleCompilePolicy.shouldCompile(
            enabled: autoCompileEnabled,
            hasProject: openProjectId != nil,
            needsCompile: autoCompileNeeded,
            isCompiling: isCompiling,
            isOpeningProject: isOpeningProject,
            hasPendingMerges: !pendingMerges.isEmpty,
            pageVisible: rightPane != .editor,
            isOnline: network.isOnline,
            localTeXAvailable: localTeXAvailable
        ) else { return }

        autoCompileNeeded = false
        await saveAndCompile(automatic: true)
    }

    /// Rechecks the current buffer after a pause. The first pass is local and
    /// instant; when `chktex` is installed its process runs off the main thread.
    private func scheduleLint() {
        lintTask?.cancel()
        lintTask = nil
        guard let path = openPath, workspace != nil,
              ["tex", "ltx", "latex"].contains(
                (path as NSString).pathExtension.lowercased()
              ) else {
            lintDiagnostics = []
            return
        }

        let text = editorText
        let references = Set(completionIndex.referenceKeys)
        let citations = Set(completionIndex.citationKeys)
        let generation = openGeneration
        lintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.openPath == path, self.editorText == text,
                  self.openGeneration == generation else { return }

            let diagnostics = await LaTeXLint.diagnostics(
                text: text,
                file: path,
                knownReferences: references,
                knownCitations: citations,
                chktex: LaTeXLint.chktexExecutable()
            )
            guard !Task.isCancelled, self.openPath == path,
                  self.editorText == text else { return }
            self.lintDiagnostics = diagnostics
        }
    }

    /// Retries queued work once a minute. The system path monitor catches a real
    /// disconnect immediately; this covers the network being up while Overleaf
    /// itself is not answering.
    private func scheduleRetry() {
        retryTask?.cancel()
        guard isSignedIn, hasPendingWork else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.flushPendingWork()
            if self.hasPendingWork { self.scheduleRetry() }
        }
    }

    /// One retry for a transient server failure: a failed download must not be
    /// the reason a perfectly good save never happens.
    private func downloadArchive(projectId: String, client: OverleafClient) async throws -> Data {
        do {
            return try await client.downloadProjectZip(projectId)
        } catch {
            guard !Connectivity.isOffline(error) else { throw error }
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await client.downloadProjectZip(projectId)
        }
    }

    // MARK: - Pending state

    private func refreshPendingState(rebuildTree: Bool = false) {
        guard let workspace else {
            unsavedFiles = []
            pendingSyncCount = 0
            pendingCompile = false
            return
        }
        if rebuildTree { fileTree = workspace.fileTree() }
        unsavedFiles = workspace.modifiedPaths
        pendingSyncCount = unsavedFiles.count
        pendingCompile = workspace.pendingCompile
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
        if Connectivity.isOffline(error) {
            errorMessage = nil
            statusMessage = "Overleaf is not reachable — work is kept locally"
            return
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func dismissError() { errorMessage = nil }
}

// MARK: - Small persisted helpers

private enum Defaults {
    static let lastProjectId = "mangrove.lastProjectId"
    static let lastProjectName = "mangrove.lastProjectName"
    static let autosave = "mangrove.autosave"
    static let autoCompile = "mangrove.autoCompile"

    static func rememberProject(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: lastProjectId)
        UserDefaults.standard.set(name, forKey: lastProjectName)
    }
}

/// The last project list seen, so an offline launch still shows something to
/// click rather than an empty sidebar.
private struct ProjectCache {
    private var url: URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Mangrove/projects.json")
    }

    func load() -> [OverleafProject] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([OverleafProject].self, from: data)) ?? []
    }

    func save(_ projects: [OverleafProject]) {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
