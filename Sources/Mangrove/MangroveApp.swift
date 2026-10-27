import AppKit
import SwiftUI

@main
struct MangroveApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Mangrove") {
            RootView()
                .environmentObject(state)
                // Four columns need room to read: below this the source and the
                // page start feeling cramped, so the window refuses to be smaller.
                // The restored frame is clamped up to it automatically.
                .frame(minWidth: 1240, minHeight: 740)
                .task { await state.restoreSession() }
        }
        .commands {
            // Overleaf projects are not local documents, so drop New/Document items.
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Project") {
                Button("Save File") {
                    Task { await state.saveCurrentFile() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.isDirty)

                Button("Save & Compile") {
                    Task { await state.saveAndCompile() }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(state.selectedProjectId == nil)

                Button("Copy File Contents") {
                    state.copyCurrentFileToPasteboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(state.openPath == nil)

                Button("Reload from Overleaf") {
                    Task { await state.reloadProject() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.selectedProjectId == nil)

                Divider()

                Toggle("Draft Compile", isOn: $state.draftMode)

                Divider()

                Button("Sign Out") { state.signOut() }
                    .disabled(!state.isSignedIn)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.isSignedIn {
                MainView()
            } else {
                SignInView()
            }
        }
        .tint(Theme.leaf)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let busy = state.busyMessage {
                    BusyBanner(message: busy)
                }
                if let error = state.errorMessage {
                    NoticeBanner(message: error, isError: true) {
                        state.dismissError()
                    }
                }
            }
            .padding(.bottom, 22)
            .padding(.horizontal, 22)
            .animation(.easeOut(duration: 0.16), value: state.errorMessage)
        }
    }
}

/// Quiet progress note for work that has no place in the window otherwise,
/// such as uploading a file.
struct BusyBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).scaleEffect(0.8)
            Text(message)
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 9, y: 3)
    }
}
