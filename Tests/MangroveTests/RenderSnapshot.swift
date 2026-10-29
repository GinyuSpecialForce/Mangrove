import AppKit
import SwiftUI
import XCTest
@testable import Mangrove


/// Renders the main window offscreen so the layout and syntax colours can be
/// reviewed without a live session. Opt-in, and it writes PNGs into `.work/`:
///
///     MANGROVE_RENDER_SNAPSHOTS=1 swift test --filter RenderSnapshot
@MainActor
final class RenderSnapshot: XCTestCase {

    private let sample = #"""
    % SGF-Paper_SIURO.tex
    \documentclass[11pt]{article}
    \usepackage{amsmath}
    \usepackage{hyperref}

    \title{Safe Gradient Flow}
    \author{A. Author}

    \begin{document}
    \maketitle
    \section{Introduction}

    The method begins with a direction that decreases the
    objective and modifies that direction when needed to
    satisfy inequalities. Control-barrier functions provide
    differential inequalities that restrict the allowed motion
    and guarantee preservation of a safe set under suitable
    assumptions, as shown in \cite{allibhoy2024}.

    Inline math such as $\alpha + \beta \le \gamma$ sits in the
    running text, while display math does not:

    \begin{equation}
      \dot{x} = f(x) + g(x)u, \qquad h(x) \ge 0
    \end{equation}

    \subsection{Contributions}

    \begin{itemize}
      \item A continuous-time formulation.
      \item A geometric model of the satellite path, 50\% faster.
    \end{itemize}

    \bibliographystyle{plain}
    \bibliography{refs}
    \end{document}
    """#

    func testRenderMainWindow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        state.isSignedIn = true
        state.projects = [
            OverleafProject(
                id: "p2",
                name: "Distributed Function Computation through Safe Gradient Flow",
                accessLevel: "readAndWrite"
            ),
            OverleafProject(id: "p1", name: "SGF_SIURO", accessLevel: "owner"),
        ]
        state.selectedProjectId = "p1"
        state.fileTree = [
            FileNode(path: "figures", name: "figures", isDirectory: true, children: [
                FileNode(path: "figures/path.pdf", name: "path.pdf", isDirectory: false, children: []),
            ]),
            FileNode(path: "SGF-Paper_SIURO.tex", name: "SGF-Paper_SIURO.tex", isDirectory: false, children: []),
            FileNode(path: "README.txt", name: "README.txt", isDirectory: false, children: []),
            FileNode(path: "SGF-Paper_SIURO.pdf", name: "SGF-Paper_SIURO.pdf", isDirectory: false, children: []),
        ]
        state.openPath = "SGF-Paper_SIURO.tex"
        state.editorText = sample
        state.isDirty = true
        // Two open files so the tab strip, including the active dirty marker, is
        // part of the layout check.
        state.openDocuments = [
            OpenDocument(path: "SGF-Paper_SIURO.tex", text: sample, savedText: sample, isDirty: true),
            OpenDocument(path: "README.txt", text: "Project notes", savedText: "Project notes", isDirty: false),
        ]

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(
                MainView().environmentObject(state),
                // The size the window opens at on a 1440x900 display.
                size: NSSize(width: 1360, height: 700),
                appearance: NSAppearance(named: appearance),
                to: ".work/layout-\(name).png"
            )
        }
    }

    /// The whole window in visual mode: checks the mode picker, the page width
    /// inside the split, and that the sidebar still has room.
    func testRenderMainWindowVisual() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        state.isSignedIn = true
        state.projects = [
            OverleafProject(
                id: "p2",
                name: "Distributed Function Computation through Safe Gradient Flow",
                accessLevel: "readAndWrite"
            ),
            OverleafProject(id: "p1", name: "SGF_SIURO", accessLevel: "owner"),
        ]
        state.selectedProjectId = "p1"
        state.fileTree = [
            FileNode(path: "figures", name: "figures", isDirectory: true, children: [
                FileNode(path: "figures/path.pdf", name: "path.pdf", isDirectory: false, children: []),
            ]),
            FileNode(path: "SGF-Paper_SIURO.tex", name: "SGF-Paper_SIURO.tex", isDirectory: false, children: []),
            FileNode(path: "README.txt", name: "README.txt", isDirectory: false, children: []),
            FileNode(path: "SGF-Paper_SIURO.pdf", name: "SGF-Paper_SIURO.pdf", isDirectory: false, children: []),
        ]
        state.openPath = "SGF-Paper_SIURO.tex"
        state.editorText = sample
        state.editorMode = .visual
        state.isDirty = true
        state.openDocuments = [
            OpenDocument(path: "SGF-Paper_SIURO.tex", text: sample, savedText: sample, isDirty: true),
        ]

        try render(
            MainView().environmentObject(state),
            size: NSSize(width: 1360, height: 800),
            appearance: NSAppearance(named: .aqua),
            to: ".work/layout-visual.png"
        )
    }

    /// The front door: rendered so the README's sign-in image shows the name the
    /// app actually uses.
    func testRenderSignIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        try render(
            SignInView().environmentObject(state),
            size: NSSize(width: 900, height: 700),
            appearance: NSAppearance(named: .aqua),
            to: ".work/sign-in.png"
        )
    }

    func testRenderMergeSheet() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let base = "The method begins with a direction\nthat decreases the objective.\n"
        let mine = "The method begins with a direction\nthat decreases the loss quickly.\n"
        let theirs = "The method begins with a search direction\nthat decreases the objective.\n"
        guard case let .conflicted(_, conflicts) = LineMerge.merge(mine: mine, base: base, theirs: theirs) else {
            return XCTFail("fixture must conflict")
        }
        let merge = PendingMerge(
            path: "sections/method.tex",
            mine: mine, base: base, theirs: theirs,
            kind: .text(conflicts),
            localData: Data(mine.utf8), remoteData: Data(theirs.utf8)
        )

        let state = AppState()
        try render(
            MergeConflictSheet(merge: merge).environmentObject(state),
            size: NSSize(width: 720, height: 560),
            appearance: NSAppearance(named: .aqua),
            to: ".work/merge-sheet.png"
        )
    }

    func testRenderOfflineStatusBar() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        state.isOnline = false
        state.pendingSyncCount = 3
        state.unsavedFiles = ["main.tex", "sections/intro.tex", "refs.bib"]
        state.pendingCompile = true
        state.statusMessage = "Saved locally — 3 files will sync automatically"

        try render(
            VStack(spacing: 0) {
                Color(nsColor: .windowBackgroundColor).frame(height: 34)
                StatusBar().environmentObject(state)
            },
            size: NSSize(width: 900, height: 60),
            appearance: NSAppearance(named: .aqua),
            to: ".work/status-offline.png"
        )
    }

    /// The whole window cannot be forced into dark appearance faithfully offscreen,
    /// but a single view can — so this is the honest dark-mode check for the editor.
    func testRenderEditorDark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        var text = sample
        let editor = ZStack {
            Color(nsColor: .windowBackgroundColor)
            SourceEditor(text: Binding(get: { text }, set: { text = $0 }))
        }
        try render(
            editor,
            size: NSSize(width: 720, height: 520),
            appearance: NSAppearance(named: .darkAqua),
            to: ".work/editor-dark.png"
        )
    }

    /// The formatted page, in both appearances. The visual layout is the part
    /// that cannot be asserted, so it is rendered and inspected.
    func testRenderVisualEditor() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        state.isSignedIn = true
        var text = sample
        let editor = VisualEditor(text: Binding(get: { text }, set: { text = $0 }))
            .environmentObject(state)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(
                editor,
                size: NSSize(width: 880, height: 1100),
                appearance: NSAppearance(named: appearance),
                to: ".work/visual-\(name).png"
            )
        }
    }

    func testRenderBuildProblems() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        state.isSignedIn = true
        state.lastBuildFailed = true
        state.buildSource = .overleaf
        state.buildDiagnostics = [
            BuildDiagnostic(
                severity: .error,
                message: "Undefined control sequence.",
                file: "SGF-Paper_SIURO.tex",
                line: 23,
                detail: "\\badcommand"
            ),
            BuildDiagnostic(
                severity: .error,
                message: "Missing $ inserted.",
                file: "SGF-Paper_SIURO.tex",
                line: 61,
                detail: "x_1"
            ),
            BuildDiagnostic(
                severity: .warning,
                message: "Citation `smith2020' on page 1 undefined on input line 42.",
                file: "SGF-Paper_SIURO.tex",
                line: 42
            ),
        ]

        try render(
            BuildPane(initialTab: .problems).environmentObject(state),
            size: NSSize(width: 540, height: 640),
            appearance: NSAppearance(named: .aqua),
            to: ".work/problems.png"
        )
    }

    /// The new project tools are sheets, so they cannot be reached from the main
    /// window snapshot. Render them once to make sure their chrome lays out.
    func testRenderProjectTools() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_RENDER_SNAPSHOTS"] == "1")

        let state = AppState()
        state.isSignedIn = true
        state.openPath = "SGF-Paper_SIURO.tex"
        state.editorText = sample
        state.editorMode = .code

        try render(
            ProjectSearchSheet().environmentObject(state),
            size: NSSize(width: 660, height: 500),
            appearance: NSAppearance(named: .aqua),
            to: ".work/project-search.png"
        )
        try render(
            HistorySheet().environmentObject(state),
            size: NSSize(width: 780, height: 540),
            appearance: NSAppearance(named: .aqua),
            to: ".work/history.png"
        )
        try render(
            RenameSheet(request: FileNameRequest(path: "sections/method.tex", isFolder: false))
                .environmentObject(state),
            size: NSSize(width: 420, height: 240),
            appearance: NSAppearance(named: .aqua),
            to: ".work/rename.png"
        )
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance?, to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()

        // Let SwiftUI settle its layout and materials before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not create a bitmap for \(path)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(path)")
            return
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try png.write(to: url)
        window.contentView = nil
    }
}
