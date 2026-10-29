import SwiftUI

/// Asks what to keep when both this Mac and Overleaf changed the same lines.
///
/// Nothing is uploaded until a choice is made here, so dismissing the sheet is
/// always safe: the local file stays exactly as it was.
struct MergeConflictSheet: View {
    @EnvironmentObject private var state: AppState
    let merge: PendingMerge

    @State private var useTheirs: [Bool]

    init(merge: PendingMerge) {
        self.merge = merge
        let count: Int
        if case let .text(conflicts) = merge.kind {
            count = conflicts.count
        } else {
            count = 0
        }
        _useTheirs = State(initialValue: Array(repeating: false, count: count))
    }

    private var conflicts: [LineMerge.Conflict] {
        if case let .text(conflicts) = merge.kind { return conflicts }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rule()

            if merge.isBinary {
                binaryBody
            } else {
                conflictList
            }

            Rule()
            footer
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 420, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text("Changes to merge in \(merge.path)")
                    .font(Theme.Typeface.display(14))
            }
            Text(merge.isBinary
                 ? "This file was changed both here and on Overleaf, and it cannot be merged line by line."
                 : "Someone saved this file on Overleaf after your last sync. Both sets of edits are still here — choose what to keep for each region.")
                .font(Theme.Typeface.ui(10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var conflictList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if conflicts.isEmpty {
                    Text("The whole file conflicts. “Keep Mine” keeps your copy; “Use Overleaf’s” takes theirs.")
                        .font(Theme.Typeface.ui(11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ForEach(Array(conflicts.enumerated()), id: \.offset) { index, conflict in
                    region(index: index, conflict: conflict)
                }
            }
            .padding(18)
        }
    }

    private func region(index: Int, conflict: LineMerge.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Region \(index + 1)")
                    .font(Theme.Typeface.ui(10.5, .semibold))
                Text("both sides changed the same lines")
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Picker("Keep", selection: binding(for: index)) {
                    Text("Mine").tag(false)
                    Text("Overleaf").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 10) {
                column(title: "Yours", text: conflict.mine, tint: Theme.leaf, isChosen: !useTheirs[index])
                column(title: "Overleaf", text: conflict.theirs, tint: Theme.warning, isChosen: useTheirs[index])
            }
        }
    }

    private func column(title: String, text: String, tint: Color, isChosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isChosen ? tint : Color.clear)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(Theme.Typeface.ui(9, .semibold))
                    .foregroundStyle(isChosen ? .primary : .secondary)
            }
            ScrollView {
                Text(text.isEmpty ? "(nothing)" : text)
                    .font(Theme.Typeface.mono(10))
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isChosen ? tint.opacity(0.35) : Theme.rule, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var binaryBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep your local copy, or take the one saved on Overleaf. The other version is discarded.")
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.secondary)
            if let local = merge.localData, let remote = merge.remoteData {
                HStack(spacing: 18) {
                    Label("\(local.count) bytes here", systemImage: "desktopcomputer")
                    Label("\(remote.count) bytes on Overleaf", systemImage: "cloud")
                }
                .font(Theme.Typeface.mono(10))
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !state.pendingMerges.isEmpty {
                Text(state.pendingMerges.count > 1
                     ? "\(state.pendingMerges.count) files need a decision"
                     : "1 file needs a decision")
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()

            Button("Later") { state.dismissMergeSheet() }
                .keyboardShortcut(.cancelAction)

            Button("Keep Mine") {
                state.resolveMerge(merge, choosingTheirs: nil)
            }

            if merge.isBinary {
                Button("Use Overleaf’s") {
                    state.resolveMerge(merge, choosingTheirs: [])
                }
            } else {
                Button("Merge & Save") {
                    state.resolveMerge(merge, choosingTheirs: useTheirs)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { index < useTheirs.count ? useTheirs[index] : false },
            set: { value in
                guard index < useTheirs.count else { return }
                useTheirs[index] = value
            }
        )
    }
}
