import SwiftUI
import PDFKit

/// The compiled page, plus the build log when something goes wrong.
struct BuildPane: View {
    @EnvironmentObject private var state: AppState
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Build view", selection: $showLog) {
                    Text("Page").tag(false)
                    Text("Log").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 124)
                .controlSize(.small)

                Spacer(minLength: 4)
                statusPill
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, 8)

            Rule()

            if showLog {
                logView
            } else if let data = state.pdfData {
                PDFViewer(data: data)
            } else {
                emptyState
            }
        }
        .onChange(of: state.compilerLog) { log in
            // Surface the log automatically when a build goes wrong.
            if !log.isEmpty, state.pdfData == nil { showLog = true }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if state.isCompiling {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                Text("Compiling")
                    .font(Theme.Typeface.ui(9.5, .medium))
                    .foregroundStyle(.secondary)
            }
        } else if state.pdfData != nil {
            pill("Compiled", tint: Theme.leaf, symbol: "checkmark")
        } else if !state.compilerLog.isEmpty {
            pill("Failed", tint: Theme.danger, symbol: "xmark")
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

    private var emptyState: some View {
        EmptyState(
            icon: "doc.text.magnifyingglass",
            title: "Nothing compiled yet",
            detail: "Compiling runs on Overleaf's servers and puts the finished page here."
        ) {
            Button("Compile") {
                Task { await state.saveAndCompile() }
            }
            .buttonStyle(PrimaryButtonStyle(compact: true))
            .disabled(state.selectedProjectId == nil)
        }
    }

    private var logView: some View {
        ScrollView {
            Text(state.compilerLog.isEmpty ? "No build log yet." : state.compilerLog)
                .font(Theme.Typeface.mono(10.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct PDFViewer: NSViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.underPageBackgroundColor
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard context.coordinator.renderedData != data else { return }
        context.coordinator.renderedData = data
        nsView.document = PDFDocument(data: data)
        nsView.autoScales = true
    }

    final class Coordinator {
        var renderedData: Data?
    }
}
