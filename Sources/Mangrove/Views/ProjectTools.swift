import SwiftUI

// MARK: - Project search

/// Find and replace across every text file in the working copy. The sheet stays
/// open while results are reviewed, but a hit takes you to the editor.
struct ProjectSearchSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var wholeWord = false
    @State private var results: [ProjectSearchHit] = []
    @State private var hasSearched = false
    @State private var isReplacing = false
    @State private var resultNote: String?
    @State private var searchTask: Task<Void, Never>?

    private var options: ProjectSearchOptions {
        ProjectSearchOptions(caseSensitive: caseSensitive, wholeWord: wholeWord)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHead(title: "Find in Project", subtitle: "Every text file in the working copy") {
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.ui(10, .medium))
                    .foregroundStyle(Theme.leaf)
            }

            Rule()

            fields
            Rule()
            resultsView
            Rule()
            footer
        }
        .frame(width: 660, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if query.isEmpty { query = "" }
            search()
        }
        .onChange(of: caseSensitive) { _ in search() }
        .onChange(of: wholeWord) { _ in search() }
        .onDisappear { searchTask?.cancel() }
    }

    private var fields: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Text to find", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Typeface.mono(12))
                    .onSubmit { search() }
                    .onChange(of: query) { _ in scheduleSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .help("Match case")
                Toggle("Word", isOn: $wholeWord)
                    .toggleStyle(.button)
                    .help("Whole words only")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack(spacing: 7) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.plain)
                    .font(Theme.Typeface.mono(12))
                Button(isReplacing ? "Replacing…" : "Replace All") {
                    replaceAll()
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .disabled(query.isEmpty || results.isEmpty || isReplacing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var resultsView: some View {
        if results.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: hasSearched ? "checkmark.seal" : "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(hasSearched ? "No matches" : "Type to search")
                    .font(Theme.Typeface.display(14, .medium))
                Text(hasSearched
                     ? "Nothing in this project contains “\(query)”."
                     : "Matches appear here with their file and line.")
                    .font(Theme.Typeface.ui(10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { hit in
                        Button {
                            state.revealSearchHit(hit)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text("\(hit.path):\(hit.line)")
                                    .font(Theme.Typeface.mono(9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 170, alignment: .leading)
                                preview(hit)
                                    .font(Theme.Typeface.mono(10.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.Metric.gutter)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rule()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func preview(_ hit: ProjectSearchHit) -> Text {
        var text = AttributedString(hit.preview)
        if hit.previewRange.length > 0,
           let range = Range(hit.previewRange, in: hit.preview),
           let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].foregroundColor = Theme.leaf
            text[lower..<upper].backgroundColor = Theme.leaf.opacity(0.14)
        }
        return Text(text)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let resultNote {
                Text(resultNote)
                    .font(Theme.Typeface.ui(10))
                    .foregroundStyle(.secondary)
            } else if hasSearched {
                Text(results.isEmpty
                     ? "No matches"
                     : "\(results.count)\(results.count == ProjectSearch.maxHits ? "+" : "") match\(results.count == 1 ? "" : "es")")
                    .font(Theme.Typeface.ui(10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("⇧⌘F")
                .font(Theme.Typeface.mono(9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 8)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let captured = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, query == captured else { return }
            search()
        }
    }

    private func search() {
        let captured = query
        let options = self.options
        results = state.searchProject(query: captured, options: options)
        hasSearched = !captured.trimmingCharacters(in: .whitespaces).isEmpty
        resultNote = nil
    }

    private func replaceAll() {
        isReplacing = true
        let capturedQuery = query
        let capturedReplacement = replacement
        let capturedOptions = options
        Task {
            let count = await state.replaceAllProject(
                query: capturedQuery, with: capturedReplacement, options: capturedOptions
            )
            isReplacing = false
            resultNote = count == 0 ? "Nothing was replaced" : "Replaced \(count) match\(count == 1 ? "" : "es")"
            results = state.searchProject(query: capturedQuery, options: capturedOptions)
            if count > 0 { dismiss() }
        }
    }
}

// MARK: - History

/// Revisions captured when a file reached Overleaf, with a line diff against
/// what is on screen now.
struct HistorySheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: HistorySnapshot?

    private var snapshots: [HistorySnapshot] { state.historyForOpenFile }

    var body: some View {
        VStack(spacing: 0) {
            PaneHead(
                title: "Version History",
                subtitle: state.openPath.map { "\($0) · local snapshots" } ?? "No file open"
            ) {
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.ui(10, .medium))
                    .foregroundStyle(Theme.leaf)
            }
            Rule()

            if snapshots.isEmpty {
                EmptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No versions yet",
                    detail: "A snapshot is kept each time this file is saved to Overleaf. Saving the document once is enough to start the history."
                )
            } else {
                HStack(spacing: 0) {
                    list
                    Rule(vertical: true)
                    detail
                }
            }
        }
        .frame(width: 780, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selected = snapshots.first }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(snapshots) { snapshot in
                    Button {
                        selected = snapshot
                    } label: {
                        HStack(spacing: 7) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppState.historyDateFormatter.string(from: snapshot.savedAt))
                                    .font(Theme.Typeface.ui(10.5, selected?.id == snapshot.id ? .semibold : .regular))
                                Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.bytes), countStyle: .file))
                                    .font(Theme.Typeface.mono(9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selected?.id == snapshot.id ? Theme.leaf.opacity(0.13) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let selected, let old = state.historyContents(selected) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Against the current file")
                        .font(Theme.Typeface.ui(10, .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore This Version") {
                        state.restoreHistory(selected)
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Rule()
                diffView(old: old)
            }
        } else {
            EmptyState(
                icon: "doc.questionmark",
                title: "Snapshot unavailable",
                detail: "The saved copy could not be read from disk."
            )
        }
    }

    @ViewBuilder
    private func diffView(old: String) -> some View {
        if let rows = LineDiff.rows(old: old, new: state.editorText) {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            Text(row.oldLine.map(String.init) ?? "")
                                .frame(width: 30, alignment: .trailing)
                                .foregroundStyle(.tertiary)
                            Text(row.newLine.map(String.init) ?? "")
                                .frame(width: 30, alignment: .trailing)
                                .foregroundStyle(.tertiary)
                            Text(marker(for: row.kind))
                                .frame(width: 9)
                                .foregroundStyle(tint(for: row.kind))
                            Text(row.text.isEmpty ? " " : row.text)
                                .foregroundStyle(row.kind == .same ? Color.primary : tint(for: row.kind))
                        }
                        .font(Theme.Typeface.mono(10))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(tint(for: row.kind).opacity(row.kind == .same ? 0 : 0.07))
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            EmptyState(
                icon: "text.alignleft",
                title: "Too large to diff",
                detail: "This file has more lines than the side-by-side view handles. Restore the version or compare it in an editor."
            )
        }
    }

    private func marker(for kind: DiffRow.Kind) -> String {
        switch kind {
        case .same: return ""
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func tint(for kind: DiffRow.Kind) -> Color {
        switch kind {
        case .same: return .primary
        case .added: return Theme.leaf
        case .removed: return Theme.danger
        }
    }
}

// MARK: - File operation sheets

struct RenameSheet: View {
    @EnvironmentObject private var state: AppState
    let request: FileNameRequest
    @State private var name: String
    @FocusState private var focused: Bool

    init(request: FileNameRequest) {
        self.request = request
        _name = State(initialValue: request.currentName)
    }

    var body: some View {
        OperationSheet(
            title: "Rename \(request.isFolder ? "Folder" : "File")",
            detail: "The name changes on Overleaf and in the working copy. Its path updates in open tabs."
        ) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typeface.ui(12))
                .focused($focused)
                .onSubmit(submit)
            if request.isFolder {
                Text("Moving a folder also moves everything inside it.")
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Cancel") { state.renameRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button("Rename") { submit() }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let value = name
        Task { await state.rename(request, to: value) }
    }
}

struct MoveSheet: View {
    @EnvironmentObject private var state: AppState
    let request: FileMoveRequest
    @State private var folder = ""

    private var destinations: [String] {
        state.folderPaths.filter { path in
            guard request.isFolder else { return true }
            // A folder cannot be moved inside itself.
            return path != request.path && !path.hasPrefix(request.path + "/")
        }
    }

    var body: some View {
        OperationSheet(
            title: "Move \(request.isFolder ? "Folder" : "File")",
            detail: "“\(request.name)” is moved on Overleaf and in the working copy."
        ) {
            Picker("Destination", selection: $folder) {
                Text("Project root").tag("")
                ForEach(destinations, id: \.self) { path in
                    Text(path).tag(path)
                }
            }
            .pickerStyle(.menu)
            .font(Theme.Typeface.ui(11))
        } actions: {
            Button("Cancel") { state.moveRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button("Move") { submit() }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func submit() {
        let destination = folder
        Task { await state.move(request, to: destination) }
    }
}

struct DeleteFileSheet: View {
    @EnvironmentObject private var state: AppState
    let request: FileDeleteRequest

    var body: some View {
        OperationSheet(
            title: "Delete \(request.isFolder ? "Folder" : "File")",
            detail: request.isFolder
                ? "“\(request.name)” and everything inside it will be removed from Overleaf and this Mac. This cannot be undone."
                : "“\(request.name)” will be removed from Overleaf and this Mac. This cannot be undone."
        ) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .font(.system(size: 11))
                Text("Other collaborators will lose this \(request.isFolder ? "folder" : "file") too.")
                    .font(Theme.Typeface.ui(10.5))
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Cancel") { state.deleteRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button("Delete") {
                let captured = request
                Task { await state.delete(captured) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct NewFolderSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var name = "figures"
    @FocusState private var focused: Bool

    private var parent: String { state.newFolderParent }

    var body: some View {
        OperationSheet(
            title: "New Folder",
            detail: parent.isEmpty
                ? "It is created in the project root."
                : "It is created inside \(parent)."
        ) {
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typeface.ui(12))
                .focused($focused)
                .onSubmit(submit)
        } actions: {
            Button("Cancel") { state.isShowingNewFolderSheet = false }
                .keyboardShortcut(.cancelAction)
            Button("Create") { submit() }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let captured = name
        let destination = parent
        Task { await state.createFolder(named: captured, in: destination) }
    }
}

/// Shared chrome for the small file-operation dialogs.
private struct OperationSheet<Content: View, Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typeface.display(16, .semibold))
                Text(detail)
                    .font(Theme.Typeface.ui(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 13)

            Rule()

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(18)

            Rule()

            HStack(spacing: 8) {
                Spacer()
                actions
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
