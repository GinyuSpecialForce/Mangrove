import AppKit
import PDFKit
import SwiftUI

/// The compiled page, the problems the compiler reported, and the raw log.
///
/// A failed build used to bury its errors in a wall of TeX log; the Problems tab
/// is the useful surface. The log stays one click away for the cases the parser
/// cannot classify.
struct BuildPane: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: BuildTab

    init(initialTab: BuildTab = .page) {
        _tab = State(initialValue: initialTab)
    }

    private var buildDiagnostics: [BuildDiagnostic] {
        state.buildDiagnostics.orderedForDisplay()
    }

    private var lintDiagnostics: [BuildDiagnostic] {
        state.lintDiagnostics.orderedForDisplay()
    }

    private var allDiagnostics: [BuildDiagnostic] {
        buildDiagnostics + lintDiagnostics
    }

    private var hasPDF: Bool { state.pdfData != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(BuildTab.allCases, id: \.rawValue) { item in
                    tabButton(item)
                }
                Spacer(minLength: 4)
                if hasPDF, state.syncTeXAvailable {
                    Button {
                        state.revealInPDF()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.leaf)
                    }
                    .buttonStyle(.plain)
                    .help("Show the caret's line on the page (⇧⌘J)")
                }
                if hasPDF {
                    exportButton
                }
                statusPill
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Rule()

            switch tab {
            case .page:
                pageView
            case .problems:
                problemsView
            case .log:
                logView
            }
        }
        .onChange(of: state.buildRevision) { _ in
            // An automatic build updates the page without pulling the reader
            // away from the tab they chose.
            guard !state.lastBuildWasAutomatic else { return }
            // A finished build should land on the most useful tab: the page if
            // it worked, otherwise the problems (or the log, if nothing could
            // be parsed out of it).
            if state.lastBuildFailed {
                tab = state.buildDiagnostics.isEmpty ? .log : .problems
            } else if hasPDF {
                tab = .page
            }
        }
        .onChange(of: state.compilerLog) { log in
            // A build issued from elsewhere (a queued compile finishing, say)
            // still gets the same treatment, unless it was automatic.
            guard !log.isEmpty, !state.lastBuildWasAutomatic else { return }
            if state.lastBuildFailed {
                tab = state.buildDiagnostics.isEmpty ? .log : .problems
            }
        }
        .onChange(of: state.pdfFocus) { focus in
            guard focus != nil else { return }
            tab = .page
        }
    }

    // MARK: - Tabs

    private func tabButton(_ item: BuildTab) -> some View {
        let isActive = tab == item
        let count = item == .problems ? allDiagnostics.count : 0
        let tint: Color = allDiagnostics.errorCount > 0 ? Theme.danger : Theme.warning

        return Button {
            tab = item
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(item.title)
                    .font(Theme.Typeface.ui(10, .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Typeface.mono(8.5, .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(tint.opacity(0.14)))
                }
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item == .problems ? "Compiler errors, warnings and writing checks" : item.title)
    }

    /// The page can leave the app. It sits beside the build status, where a
    /// finished build is reported.
    private var exportButton: some View {
        Button {
            state.exportPDF()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 9, weight: .semibold))
                Text("Export PDF")
                    .font(Theme.Typeface.ui(10, .medium))
            }
            .foregroundStyle(Theme.leaf)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.leaf.opacity(0.10))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Save the compiled PDF to disk (⇧⌘E)")
    }

    @ViewBuilder
    private var statusPill: some View {
        if state.isCompiling {
            HStack(spacing: 5) {
                TinySpinner(size: 10)
                Text("Compiling")
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(.secondary)
            }
        } else if state.lastBuildFailed {
            pill("Failed", tint: Theme.danger, symbol: "xmark")
        } else if state.pdfData != nil {
            let text = state.lastBuildWasAutomatic
                ? (state.buildSource == .local ? "Auto-compiled locally" : "Auto-compiled")
                : (state.buildSource == .local ? "Compiled locally" : "Compiled")
            pill(text, tint: Theme.leaf, symbol: "checkmark")
        } else if state.pendingCompile {
            pill("Queued", tint: Theme.warning, symbol: "clock")
        }
    }

    private func pill(_ text: String, tint: Color, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 7, weight: .bold))
            Text(text).font(Theme.Typeface.ui(9.5, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: - Page

    @ViewBuilder
    private var pageView: some View {
        if let data = state.pdfData {
            PDFViewer(
                data: data,
                focus: state.pdfFocus,
                onInverseSearch: { page, x, y in
                    state.jumpFromPDF(page: page, x: x, y: y)
                }
            )
            .overlay(alignment: .bottomTrailing) {
                if state.syncTeXAvailable {
                    Text("Double-click to jump to source")
                        .font(Theme.Typeface.ui(9, .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        } else {
            EmptyState(
                icon: "doc.text.magnifyingglass",
                title: state.pendingCompile ? "Compile queued" : "Nothing compiled yet",
                detail: emptyDetail
            ) {
                if !state.pendingCompile {
                    Button("Compile") {
                        Task { await state.saveAndCompile() }
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(state.selectedProjectId == nil)
                }
            }
        }
    }

    private var emptyDetail: String {
        if state.pendingCompile {
            return state.localTeXAvailable
                ? "The connection is down; the queued build will run on Overleaf as soon as it returns."
                : "The connection is down and no local LaTeX is installed. The build will run on Overleaf when the connection returns."
        }
        if !state.isOnline {
            return state.localTeXAvailable
                ? "You're offline, so compiling runs on this Mac with the installed LaTeX toolchain."
                : "You're offline and no local LaTeX was found. Install BasicTeX or MacTeX to compile offline; otherwise the build is queued."
        }
        return "Compiling runs on Overleaf's servers and puts the finished page here."
    }

    // MARK: - Problems

    @ViewBuilder
    private var problemsView: some View {
        if allDiagnostics.isEmpty {
            if state.isCompiling {
                VStack(spacing: 9) {
                    TinySpinner(size: 18)
                    Text("Compiling…")
                        .font(Theme.Typeface.ui(11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.lastBuildFailed {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: "No parsed errors",
                    detail: "The build failed, but the log did not contain an error this tab recognises. The raw log may explain it."
                ) {
                    Button("Show log") { tab = .log }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                }
            } else if hasPDF {
                EmptyState(
                    icon: "checkmark.seal",
                    title: "No problems",
                    detail: state.buildSource == .local
                        ? "The local build finished without errors or warnings."
                        : "Overleaf compiled this project without errors or warnings."
                )
            } else {
                EmptyState(
                    icon: "hammer",
                    title: "No build yet",
                    detail: "Compile the project to see its errors and warnings here, next to the page."
                ) {
                    Button("Compile") {
                        Task { await state.saveAndCompile() }
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(state.selectedProjectId == nil)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    summary
                    Rule()
                    ForEach(buildDiagnostics) { diagnostic in
                        DiagnosticRow(diagnostic: diagnostic) {
                            state.revealDiagnostic(diagnostic)
                        }
                        Rule()
                    }
                    if !lintDiagnostics.isEmpty {
                        if !buildDiagnostics.isEmpty { Rule() }
                        lintHeader
                        ForEach(lintDiagnostics) { diagnostic in
                            DiagnosticRow(diagnostic: diagnostic) {
                                state.revealDiagnostic(diagnostic)
                            }
                            Rule()
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            if allDiagnostics.errorCount > 0 {
                countLabel("\(allDiagnostics.errorCount)", "error", tint: Theme.danger)
            } else {
                countLabel("0", "errors", tint: Theme.leaf)
            }
            if allDiagnostics.warningCount > 0 {
                countLabel("\(allDiagnostics.warningCount)", "warning", tint: Theme.warning)
            }
            if state.lastBuildFailed, buildDiagnostics.isEmpty {
                Button("Build failed — show log") { tab = .log }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(Theme.danger)
            }
            Spacer()
            if state.isCompiling {
                TinySpinner(size: 9)
            } else if state.buildSource == .local {
                Text("local build")
                    .font(Theme.Typeface.ui(9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 8)
    }

    private var lintHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("Writing checks")
                .font(Theme.Typeface.ui(10, .medium))
            Text("\(lintDiagnostics.count)")
                .font(Theme.Typeface.mono(8.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("as you type")
                .font(Theme.Typeface.ui(9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025))
    }

    private func countLabel(_ count: String, _ noun: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(count)
                .font(Theme.Typeface.mono(10, .semibold))
                .foregroundStyle(tint)
            Text(count == "1" ? noun : noun + "s")
                .font(Theme.Typeface.ui(9.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Log

    private var logView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(state.compilerLog.isEmpty ? "No build log" : "\(logLineCount) lines")
                    .font(Theme.Typeface.ui(9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.compilerLog.isEmpty {
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(state.compilerLog, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(Theme.leaf)
                    .help("Copy the entire log")
                }
                if state.lastBuildFailed, !state.buildDiagnostics.isEmpty {
                    Button("Problems") { tab = .problems }
                        .buttonStyle(.plain)
                        .font(Theme.Typeface.ui(9.5, .medium))
                        .foregroundStyle(Theme.leaf)
                }
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, 6)

            Rule()

            ScrollView([.vertical, .horizontal]) {
                Text(state.compilerLog.isEmpty ? "No build log yet." : state.compilerLog)
                    .font(Theme.Typeface.mono(10))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var logLineCount: Int {
        state.compilerLog.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

}

enum BuildTab: String, CaseIterable {
    case page, problems, log

    var title: String {
        switch self {
        case .page: return "PDF"
        case .problems: return "Problems"
        case .log: return "Log"
        }
    }

    var symbol: String {
        switch self {
        case .page: return "doc.richtext"
        case .problems: return "exclamationmark.triangle"
        case .log: return "text.alignleft"
        }
    }
}

/// One compiler problem: where it happened, and what the compiler said.
private struct DiagnosticRow: View {
    let diagnostic: BuildDiagnostic
    let onOpen: () -> Void
    @State private var isHovering = false

    private var tint: Color {
        diagnostic.severity == .error ? Theme.danger : Theme.warning
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: diagnostic.severity == .error
                      ? "xmark.octagon.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnostic.message)
                        .font(Theme.Typeface.mono(10.5))
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let location = diagnostic.location {
                            Text(location)
                                .font(Theme.Typeface.mono(9))
                                .foregroundStyle(tint.opacity(0.95))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let detail = diagnostic.detail {
                            Text(detail)
                                .font(Theme.Typeface.mono(9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(diagnostic.file == nil
              ? "Show this line"
              : "Open \(diagnostic.location ?? "the problem") in the source")
    }
}

/// A PDFKit view with two-way SyncTeX: double-click a word to reach its source,
/// and a focus request scrolls to a source line's place on the page.
struct PDFViewer: NSViewRepresentable {
    let data: Data
    var focus: PDFFocus? = nil
    var onInverseSearch: ((Int, Double, Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = SyncPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.underPageBackgroundColor
        view.onDoubleClick = { [weak view, weak coordinator = context.coordinator] point in
            guard let view, let coordinator, let page = view.page(for: point, nearest: true),
                  let document = view.document else { return }
            let pagePoint = view.convert(point, to: page)
            let bounds = page.bounds(for: .mediaBox)
            let index = document.index(for: page) + 1
            // SyncTeX measures from the page's top-left; PDFKit from bottom-left.
            coordinator.onInverseSearch?(index, pagePoint.x, bounds.maxY - pagePoint.y)
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.onInverseSearch = onInverseSearch
        if context.coordinator.renderedData != data {
            let restored = context.coordinator.capture(from: nsView)
            context.coordinator.renderedData = data
            nsView.document = PDFDocument(data: data)
            context.coordinator.restore(restored, in: nsView)
            context.coordinator.lastFocus = nil
        }
        if let focus, focus != context.coordinator.lastFocus,
           let page = nsView.document?.page(at: focus.page - 1) {
            context.coordinator.lastFocus = focus
            let bounds = page.bounds(for: .mediaBox)
            let point = CGPoint(x: focus.x, y: bounds.maxY - focus.y)
            nsView.go(to: PDFDestination(page: page, at: point))
        }
    }

    final class Coordinator {
        struct ViewState {
            let pageIndex: Int
            let pagePoint: CGPoint
            let scale: CGFloat
            let autoScales: Bool
        }

        var renderedData: Data?
        var lastFocus: PDFFocus?
        var onInverseSearch: ((Int, Double, Double) -> Void)?

        /// The top-left of the visible page, so a rebuilt PDF opens where the
        /// reader was rather than jumping back to page one.
        func capture(from view: PDFView) -> ViewState? {
            guard let document = view.document,
                  let page = view.currentPage,
                  view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            let topLeft = CGPoint(x: view.bounds.minX, y: view.bounds.maxY)
            let point = view.convert(topLeft, to: page)
            return ViewState(
                pageIndex: index,
                pagePoint: point,
                scale: view.scaleFactor,
                autoScales: view.autoScales
            )
        }

        func restore(_ state: ViewState?, in view: PDFView) {
            guard let state, let document = view.document, document.pageCount > 0 else {
                view.autoScales = true
                return
            }
            let index = min(max(state.pageIndex, 0), document.pageCount - 1)
            guard let page = document.page(at: index) else {
                view.autoScales = true
                return
            }
            let bounds = page.bounds(for: .mediaBox)
            let point = CGPoint(
                x: min(max(state.pagePoint.x, bounds.minX), bounds.maxX),
                y: min(max(state.pagePoint.y, bounds.minY), bounds.maxY)
            )
            view.autoScales = state.autoScales
            view.layoutDocumentView()
            view.go(to: PDFDestination(page: page, at: point))
            if !state.autoScales {
                view.scaleFactor = state.scale
            }
        }
    }
}

/// `PDFView` handles double-clicks itself (text selection), so the jump is
/// offered only for that gesture and normal dragging/selection is untouched.
final class SyncPDFView: PDFView {
    var onDoubleClick: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick(convert(event.locationInWindow, from: nil))
            return
        }
        super.mouseDown(with: event)
    }
}
