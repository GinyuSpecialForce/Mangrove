import SwiftUI

/// The main window: projects, then the project's files, then the source and the
/// compiled page.
struct MainView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ProjectSidebar()
                    .frame(minWidth: 196, idealWidth: 218, maxWidth: 300)

                content
                    .frame(minWidth: 640)
            }
            Rule()
            StatusBar()
        }
        .overlay(alignment: .top) {
            if state.remoteChangeDetected {
                RemoteChangeBanner()
                    .padding(.top, 8)
            }
        }
        .onChange(of: state.rightPane) { _ in
            state.pageVisibilityChanged()
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $state.isShowingMergeSheet) {
            if let merge = state.currentMerge {
                MergeConflictSheet(merge: merge)
                    .environmentObject(state)
                    .id(merge.id)
            }
        }
        .sheet(isPresented: $state.isShowingProjectSearch) {
            ProjectSearchSheet().environmentObject(state)
        }
        .sheet(isPresented: $state.isShowingHistory) {
            HistorySheet().environmentObject(state)
        }
        .sheet(isPresented: $state.isShowingNewFolderSheet) {
            NewFolderSheet().environmentObject(state)
        }
        .sheet(item: $state.renameRequest) { request in
            RenameSheet(request: request).environmentObject(state)
        }
        .sheet(item: $state.moveRequest) { request in
            MoveSheet(request: request).environmentObject(state)
        }
        .sheet(item: $state.deleteRequest) { request in
            DeleteFileSheet(request: request).environmentObject(state)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isOpeningProject {
            LoadingPane(message: "Downloading \(state.selectedProjectName ?? "project")…")
        } else if state.selectedProjectId != nil {
            EditorPanes()
        } else {
            WelcomePane()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await state.reloadProject() }
            } label: {
                Label("Reload from Overleaf", systemImage: "arrow.clockwise")
            }
            .disabled(state.selectedProjectId == nil || state.isOpeningProject)
            .help("Download this project again from Overleaf")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if state.remoteChangeDetected {
                Button {
                    Task { await state.loadRemoteChanges() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise.circle")
                }
                .help("Someone changed this project on Overleaf — reload to merge their changes")
            }

            CollaboratorBadge()
            SaveControl()
            CompileControl()

            Picker("Layout", selection: $state.rightPane) {
                ForEach(RightPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 188)
            .help("Show the source, the page, or both")
        }
    }
}

// MARK: - Toolbar controls

/// Initials of the people currently connected through the realtime channel. A
/// menu rather than a stack so long names do not crowd the toolbar.
private struct CollaboratorBadge: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if !state.collaborators.isEmpty {
            let names = state.collaborators.map(\.name).joined(separator: ", ")
            HStack(spacing: -3) {
                ForEach(state.collaborators.prefix(3)) { person in
                    Text(person.initials)
                        .font(Theme.Typeface.ui(8.5, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.leafMuted))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
                if state.collaborators.count > 3 {
                    Text("+\(state.collaborators.count - 3)")
                        .font(Theme.Typeface.mono(8.5, .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 7)
                }
            }
            .help("Also editing now: \(names)")
        }
    }
}

/// A persistent, quiet reminder that the working copy is behind Overleaf.
private struct RemoteChangeBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.warning)
            Text("Someone changed this project on Overleaf")
                .font(Theme.Typeface.ui(10.5, .medium))
            Button("Reload and Merge") {
                Task { await state.loadRemoteChanges() }
            }
            .buttonStyle(PrimaryButtonStyle(compact: true))
            Button {
                state.remoteChangeDetected = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

private struct SaveControl: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Button {
            Task { await state.saveCurrentFile() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.isDirty ? "arrow.up.circle.fill" : "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(state.isDirty ? Theme.warning : Theme.leaf)
                Text(state.isDirty ? "Save" : "Saved")
                    .font(Theme.Typeface.ui(11, .medium))
            }
        }
        .buttonStyle(.borderless)
        .disabled(!state.isDirty)
        .help(state.isDirty ? "Send this file to Overleaf (⌘S)" : "No unsaved changes")
    }
}

private struct CompileControl: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Button {
            Task { await state.saveAndCompile() }
        } label: {
            HStack(spacing: 5) {
                if state.isCompiling {
                    TinySpinner(size: 10, tint: .white)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                Text(state.isCompiling ? "Building" : "Compile")
                    .font(Theme.Typeface.ui(11, .semibold))
            }
        }
        // `borderedProminent` + tint does not fill with the brand colour inside a
        // macOS toolbar, so the primary action uses the explicit style.
        .buttonStyle(PrimaryButtonStyle(compact: true))
        .disabled(state.selectedProjectId == nil || state.isCompiling)
        .help("Save and compile on Overleaf (⌘B). Auto-compile is \(state.autoCompileEnabled ? "on" : "off").")
    }
}

// MARK: - Sidebar

/// The project list and the selected project's files in one tree: a project
/// unfolds to reveal its files, so the window gives its width to the source and
/// the compiled page instead of a separate file column.
private enum SidebarMode: String, CaseIterable, Identifiable {
    case files
    case outline

    var id: String { rawValue }
    var title: String { self == .files ? "Files" : "Outline" }
}

struct ProjectSidebar: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var expandedProjectId: String?
    @State private var expandedFolders: Set<String> = []
    @State private var isAddingFile = false
    @State private var newFileName = "section.tex"
    @State private var newFileFolder: String?
    @State private var mode: SidebarMode = .files

    private var filtered: [OverleafProject] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return state.projects }
        return state.projects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.canEditVisually {
                Picker("Sidebar", selection: $mode) {
                    ForEach(SidebarMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, 8)
            }
            if mode == .outline, state.canEditVisually {
                outlineList
            } else {
                SearchField(text: $query)
                projectList
            }
            Rule()
            accountFooter
        }
        .onChange(of: state.canEditVisually) { available in
            if !available { mode = .files }
        }
        .background(.thinMaterial)
        .onAppear {
            // A project may already be open when this view is rebuilt (switching
            // Source/Split/PDF recreates it), so restore what was unfolded.
            if expandedProjectId == nil, let selected = state.selectedProjectId {
                expandedProjectId = selected
            }
            if expandedFolders.isEmpty, let path = state.openPath {
                expandedFolders = Self.folders(containing: path)
            }
        }
        .onChange(of: state.selectedProjectId) { newValue in
            Task { await state.projectSelectionChanged(to: newValue) }
            // A different project means a different tree, so start it unfolded
            // with only the folders leading to the newly opened file open.
            expandedFolders = state.openPath.map(Self.folders(containing:)) ?? []
            if let newValue {
                if expandedProjectId != newValue {
                    withAnimation(.easeOut(duration: 0.14)) { expandedProjectId = newValue }
                }
            } else {
                expandedProjectId = nil
            }
        }
        .onChange(of: state.openPath) { path in
            guard let path else { return }
            // Reveal the file that was opened, wherever it lives.
            expandedFolders.formUnion(Self.folders(containing: path))
        }
        .onChange(of: state.lastImportedPath) { path in
            guard let path else { return }
            // An upload into a collapsed project or folder should still show
            // where the file landed.
            if let projectId = state.selectedProjectId, expandedProjectId != projectId {
                withAnimation(.easeOut(duration: 0.14)) { expandedProjectId = projectId }
            }
            expandedFolders.formUnion(Self.folders(containing: path))
        }
        .sheet(isPresented: $isAddingFile) {
            NewFileSheet(name: $newFileName, isPresented: $isAddingFile) { name in
                state.createFile(named: name, in: newFileFolder)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 22)
            Text("Mangrove")
                .font(Theme.Typeface.display(15))
            Spacer()
            Button {
                state.isShowingProjectSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.selectedProjectId == nil)
            .help("Find in project (⇧⌘F)")
            Button {
                Task { await state.refreshProjects() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.isOpeningProject)
            .help("Reload the project list")
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    // MARK: Outline

    private var outlineItems: [OutlineItem] {
        DocumentOutline.parse(text: state.editorText)
    }

    private var outlineList: some View {
        ScrollView {
            if outlineItems.isEmpty {
                VStack(spacing: 5) {
                    Text("No headings")
                        .font(Theme.Typeface.ui(11, .medium))
                    Text("Add \\section, \\subsection or \\chapter commands to outline this document.")
                        .font(Theme.Typeface.ui(9.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .padding(.top, 26)
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(outlineItems) { item in
                        Button {
                            state.revealOutlineItem(item)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.title)
                                    .font(Theme.Typeface.ui(
                                        item.level <= .section ? 11.5 : 10.5,
                                        item.level <= .section ? .medium : .regular
                                    ))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 2)
                                Text("\(item.wordCount)")
                                    .font(Theme.Typeface.mono(8.5))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.leading, CGFloat(max(0, item.level.rawValue - 1)) * 9 + 8)
                            .padding(.trailing, 7)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(item.level.title) on line \(item.line) · \(item.wordCount) words")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filtered.isEmpty {
                    VStack(spacing: 5) {
                        Text(state.projects.isEmpty ? "No projects yet" : "No matches")
                            .font(Theme.Typeface.ui(11, .medium))
                        Text(state.projects.isEmpty
                             ? "Projects you own or collaborate on appear here."
                             : "Try a different name.")
                            .font(Theme.Typeface.ui(10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 26)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(filtered) { project in
                        projectRow(project)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: OverleafProject) -> some View {
        let isExpanded = expandedProjectId == project.id
        let isSelected = state.selectedProjectId == project.id

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Button {
                    toggleExpansion(of: project)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide files" : "Show files")

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(Theme.Typeface.ui(12, isSelected ? .medium : .regular))
                        .lineLimit(1)
                    if let subtitle = subtitle(for: project, isExpanded: isExpanded) {
                        Text(subtitle)
                            .font(Theme.Typeface.ui(9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)

                if isSelected {
                    Menu {
                        Button("New File…") {
                            newFileFolder = nil
                            newFileName = "section.tex"
                            isAddingFile = true
                        }
                        Button("New Folder…") {
                            state.beginNewFolder(
                                in: state.openPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
                            )
                        }
                        Button("Upload Files…") {
                            state.chooseFilesToUpload()
                        }
                        .disabled(!state.canUploadFiles)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .help("Create a file or upload one from disk")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { select(project) }

            if isExpanded {
                expandedContent
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if state.isOpeningProject {
            HStack(spacing: 6) {
                TinySpinner(size: 9)
                Text("Loading files…")
                    .font(Theme.Typeface.ui(10))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 17)
            .padding(.vertical, 5)
        } else if state.fileTree.isEmpty {
            Text("No files yet")
                .font(Theme.Typeface.ui(10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 17)
                .padding(.vertical, 5)
        } else {
            fileTree(nodes: state.fileTree, depth: 0)
                .padding(.top, 2)
                .padding(.bottom, 3)
        }
    }

    /// Erased because the tree calls itself; there is no non-recursive opaque type
    /// that could describe it.
    private func fileTree(nodes: [FileNode], depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            ForEach(nodes) { node in
                if node.isDirectory {
                    let isOpen = expandedFolders.contains(node.path)
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            if isOpen { expandedFolders.remove(node.path) }
                            else { expandedFolders.insert(node.path) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 8)
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.leafMuted)
                            Text(node.name)
                                .font(Theme.Typeface.ui(11, .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(depth) * 12 + 18)
                        .padding(.trailing, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("New File Here…") {
                            newFileFolder = node.path
                            newFileName = "section.tex"
                            isAddingFile = true
                        }
                        Button("New Folder Here…") {
                            state.beginNewFolder(in: node.path)
                        }
                        Button("Upload Files Here…") {
                            state.chooseFilesToUpload(folder: node.path)
                        }
                        Divider()
                        Button("Rename Folder…") {
                            state.renameRequest = FileNameRequest(path: node.path, isFolder: true)
                        }
                        Button("Move Folder…") {
                            state.moveRequest = FileMoveRequest(path: node.path, isFolder: true)
                        }
                        Button("Delete Folder from Overleaf…") {
                            state.deleteRequest = FileDeleteRequest(path: node.path, isFolder: true)
                        }
                    }

                    if isOpen {
                        fileTree(nodes: node.children, depth: depth + 1)
                    }
                } else {
                    fileRow(node, depth: depth)
                }
            }
        })
    }

    @ViewBuilder
    private func fileRow(_ node: FileNode, depth: Int) -> some View {
        let isOpen = state.openPath == node.path
        let isUnsaved = state.unsavedFiles.contains(node.path)

        Button {
            if !isOpen { state.openFile(node.path) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: FileRowSymbols.symbol(for: node.name))
                    .font(.system(size: 10))
                    .foregroundStyle(isOpen ? Theme.leaf : Color.secondary)
                    .frame(width: 12)
                Text(node.name)
                    .font(Theme.Typeface.ui(11, isOpen ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if isUnsaved {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + 30)
            .padding(.trailing, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOpen ? Theme.leaf.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { state.openFile(node.path) }
            Divider()
            Button("Rename…") {
                state.renameRequest = FileNameRequest(path: node.path, isFolder: false)
            }
            Button("Move…") {
                state.moveRequest = FileMoveRequest(path: node.path, isFolder: false)
            }
            Button("Delete from Overleaf…") {
                state.deleteRequest = FileDeleteRequest(path: node.path, isFolder: false)
            }
            Divider()
            Button("Remove Locally") { state.deleteFile(node.path) }
        }
    }

    private var accountFooter: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.isSignedIn ? Theme.leaf : Color.secondary)
                .frame(width: 5, height: 5)
            Text(state.session?.host ?? "Not signed in")
                .font(Theme.Typeface.ui(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            Menu {
                Button("Reload Projects") {
                    Task { await state.refreshProjects() }
                }
                Divider()
                Button("Sign Out") { state.signOut() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func select(_ project: OverleafProject) {
        if state.selectedProjectId != project.id {
            state.selectedProjectId = project.id
        }
        if expandedProjectId != project.id {
            withAnimation(.easeOut(duration: 0.14)) { expandedProjectId = project.id }
        }
    }

    private func toggleExpansion(of project: OverleafProject) {
        if expandedProjectId == project.id {
            withAnimation(.easeOut(duration: 0.14)) { expandedProjectId = nil }
        } else {
            select(project)
        }
    }

    private func subtitle(for project: OverleafProject, isExpanded: Bool) -> String? {
        var parts: [String] = []
        if isExpanded, !state.isOpeningProject {
            parts.append("\(fileCount) \(fileCount == 1 ? "file" : "files")")
        }
        if let access = Self.accessLabel(for: project) {
            parts.append(access)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var fileCount: Int {
        func count(_ nodes: [FileNode]) -> Int {
            nodes.reduce(0) { total, node in
                total + (node.isDirectory ? count(node.children) : 1)
            }
        }
        return count(state.fileTree)
    }

    private static func accessLabel(for project: OverleafProject) -> String? {
        guard let access = project.accessLevel, access != "owner" else { return nil }
        switch access {
        case "readAndWrite", "readWrite": return "Shared"
        case "readOnly": return "Read only"
        default: return access.capitalized
        }
    }

    /// Folder paths that contain a file, so it can be revealed when opened.
    static func folders(containing path: String) -> Set<String> {
        var result: Set<String> = []
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var prefix: [String] = []
        for component in components {
            prefix.append(component)
            result.insert(prefix.joined(separator: "/"))
        }
        return result
    }
}

/// The symbols used for files in the tree, shared with the editor header.
enum FileRowSymbols {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "tex", "ltx", "latex": return "doc.text"
        case "bib": return "text.book.closed"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "eps", "ps": return "photo"
        case "sty", "cls", "def": return "shippingbox"
        default: return "doc"
        }
    }
}

struct NewFileSheet: View {
    @Binding var name: String
    @Binding var isPresented: Bool
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New file")
                .font(Theme.Typeface.display(15))
            TextField("section.tex", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typeface.mono(12))
                .frame(width: 280)
            Text("Use a slash to place it in a folder, relative to the project root.")
                .font(Theme.Typeface.ui(10))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(name)
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Editor and build panes

struct EditorPanes: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.rightPane {
        case .editor:
            EditorPane()
        case .pdf:
            BuildPane()
        case .split:
            HSplitView {
                EditorPane().frame(minWidth: 300, idealWidth: 620)
                BuildPane().frame(minWidth: 320, idealWidth: 600)
            }
        }
    }
}

/// Open files, in the order they were opened. A single open file needs no tab
/// strip; the document header already names it.
struct DocumentTabs: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(state.openDocuments) { document in
                    DocumentTab(document: document)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .frame(height: 29)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct DocumentTab: View {
    @EnvironmentObject private var state: AppState
    let document: OpenDocument
    @State private var isHovering = false

    private var isActive: Bool { state.openPath == document.path }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                if !isActive { state.openFile(document.path) }
            } label: {
                HStack(spacing: 5) {
                    if document.isDirty {
                        Circle().fill(Theme.warning).frame(width: 5, height: 5)
                    }
                    Text(document.name)
                        .font(Theme.Typeface.ui(10.5, isActive ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering || isActive {
                Button {
                    state.closeDocument(document.path)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close \(document.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close") { state.closeDocument(document.path) }
            Button("Close Other Tabs") {
                state.openFile(document.path)
                state.closeOtherDocuments()
            }
        }
    }
}

struct EditorPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.openDocuments.count > 1 {
                DocumentTabs()
                Rule()
            }
            if let path = state.openPath {
                documentHead(path: path)
                Rule()
                if state.editorMode == .visual && state.canEditVisually {
                    VisualEditor(
                        text: Binding(
                            get: { state.editorText },
                            set: { state.editorTextChanged($0) }
                        )
                    )
                    .id(path)
                } else {
                    SourceEditor(
                        text: Binding(
                            get: { state.editorText },
                            set: { state.editorTextChanged($0) }
                        ),
                        jump: state.editorJump,
                        completion: state.completionIndex,
                        onCaretLineChange: { state.caretLine = $0 },
                        onDropFiles: { urls, index in
                            state.insertDroppedFiles(urls, at: index)
                        }
                    )
                }
                Rule()
                documentFooter
            } else {
                EmptyState(
                    icon: "text.cursor",
                    title: "No file open",
                    detail: "Choose a file in the project to start editing."
                )
            }
        }
    }

    private func documentHead(path: String) -> some View {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(Theme.Typeface.ui(11, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if state.isDirty {
                        Circle().fill(Theme.warning).frame(width: 5, height: 5)
                    }
                }
                if !folder.isEmpty {
                    Text(folder)
                        .font(Theme.Typeface.ui(9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            Button {
                state.isShowingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(state.historyForOpenFile.isEmpty ? Color.secondary : Theme.leaf)
            }
            .buttonStyle(.plain)
            .disabled(state.historyForOpenFile.isEmpty)
            .help(state.historyForOpenFile.isEmpty
                  ? "Versions appear after this file is saved to Overleaf"
                  : "Browse earlier versions of this file")
            if state.canEditVisually {
                Picker("Editor mode", selection: $state.editorMode) {
                    Text("Code").tag(EditorMode.code)
                    Text("Visual").tag(EditorMode.visual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)
                .controlSize(.small)
                .help("Edit the LaTeX source, or a formatted view of it")
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 8)
    }

    private var passiveStatus: String {
        [
            state.autosaveEnabled ? "Autosave" : nil,
            state.autoCompileEnabled ? "Auto-compile" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var documentFooter: some View {
        HStack(spacing: 12) {
            Text("\(state.wordCount) words")
            Text("\(state.lineCount) lines")
            Text("Ln \(state.caretLine)")
            Spacer()
            if state.isDirty {
                Text(state.autosaveEnabled ? "Autosaving…" : "⌘S to save")
                    .foregroundStyle(Theme.warning)
            } else if !passiveStatus.isEmpty {
                Text(passiveStatus)
            }
        }
        .font(Theme.Typeface.ui(9))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 5)
    }
}

// MARK: - Welcome

struct WelcomePane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                AppMark(size: 76)
                VStack(spacing: 5) {
                    Text("Mangrove")
                        .font(Theme.Typeface.display(25))
                    Text("Write LaTeX and compile without leaving your desktop.")
                        .font(Theme.Typeface.ui(12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ShortcutHint(keys: "⌘B", label: "Save and compile the project")
                ShortcutHint(keys: "⌘S", label: "Send the open file to Overleaf")
                ShortcutHint(keys: "⌘R", label: "Reload the project from Overleaf")
            }
            .padding(.top, 4)

            Text(state.projects.isEmpty
                 ? "No projects yet — anything you own or collaborate on will appear on the left."
                 : "Choose a project on the left to begin.")
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(Theme.Typeface.mono(10, .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(label)
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            connectionState

            if state.pendingSyncCount > 0 {
                Text("\(state.pendingSyncCount) waiting to sync")
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(Theme.warning)
                    .help("These edits are safe on disk and will be sent to Overleaf automatically")
                if state.isOnline {
                    Button("Sync Now") { state.syncPendingChanges() }
                        .buttonStyle(.plain)
                        .font(Theme.Typeface.ui(9.5, .medium))
                        .foregroundStyle(Theme.leaf)
                        .disabled(state.isSyncing || state.isCompiling)
                }
            } else if !state.unsavedFiles.isEmpty {
                Text("\(state.unsavedFiles.count) unsaved")
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(Theme.warning)
            }

            if state.pendingCompile {
                Text("compile queued")
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.secondary)
            }

            if !state.pendingMerges.isEmpty {
                Button {
                    state.showNextMerge()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 9, weight: .semibold))
                        Text(state.pendingMerges.count == 1
                             ? "Resolve conflict"
                             : "Resolve \(state.pendingMerges.count) conflicts")
                    }
                    .font(Theme.Typeface.ui(9.5, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.warning)
            }

            Spacer()

            if let status = state.statusMessage {
                Text(status)
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder
    private var connectionState: some View {
        if !state.isOnline {
            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text("Offline")
                    .font(Theme.Typeface.ui(9.5, .medium))
            }
            .foregroundStyle(Theme.warning)
            .help("Edits are saved on this Mac and sync when the connection returns")
        } else if state.isSyncing {
            HStack(spacing: 5) {
                TinySpinner(size: 8)
                Text("Syncing…")
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
