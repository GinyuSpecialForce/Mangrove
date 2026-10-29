import AppKit
import SwiftUI

/// Visual system for the app.
///
/// The subject is typesetting, so the interface borrows the conventions of a
/// well-set page: generous margins, hairline rules instead of boxes, a serif for
/// editorial moments, and monospace for anything that is source code. Green is
/// reserved for signal — selection, compiling, success — never decoration.
enum Theme {

    static let leaf = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.29, green: 0.78, blue: 0.46, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.47, blue: 0.23, alpha: 1)
    })

    static let leafMuted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.30, green: 0.55, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.75, blue: 0.66, alpha: 1)
    })

    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    /// The single hairline used to divide panes.
    static let rule = Color(nsColor: .separatorColor).opacity(0.7)

    enum Metric {
        static let gutter: CGFloat = 14
        static let rowSpacing: CGFloat = 3
        static let corner: CGFloat = 7
    }

    enum Typeface {
        /// Editorial voice: project and page titles.
        static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .serif)
        }
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }
}

// MARK: - Marks and rules

/// The mangrove glyph, drawn from the same geometry as `Scripts/make-icon.swift`:
/// a clustered crown on arching prop roots, standing in shallow water. Keeping
/// it in SwiftUI means the sidebar mark stays crisp outside an app bundle, where
/// the icns is unavailable.
struct MangroveMark: View {
    var body: some View {
        Canvas { context, size in
            let S = min(size.width, size.height)

            // The icon is authored bottom-up, the way CoreGraphics draws; this
            // flips its coordinates into SwiftUI's top-down space.
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: S * x, y: S * (1 - y))
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: S * x, y: S * (1 - y - height), width: S * width, height: S * height)
            }

            var canopy = Path()
            canopy.addEllipse(in: rect(0.235, 0.545, 0.530, 0.155))
            canopy.addEllipse(in: rect(0.245, 0.585, 0.175, 0.165))
            canopy.addEllipse(in: rect(0.360, 0.625, 0.195, 0.190))
            canopy.addEllipse(in: rect(0.480, 0.635, 0.190, 0.190))
            canopy.addEllipse(in: rect(0.595, 0.610, 0.175, 0.175))
            canopy.addEllipse(in: rect(0.660, 0.575, 0.120, 0.140))
            canopy.addEllipse(in: rect(0.225, 0.555, 0.190, 0.120))

            context.drawLayer { layer in
                layer.addFilter(.shadow(
                    color: Color.black.opacity(0.30),
                    radius: S * 0.014,
                    x: 0,
                    y: S * 0.007
                ))
                layer.fill(
                    canopy,
                    with: .linearGradient(
                        Gradient(colors: [
                            .white,
                            Color(red: 222 / 255, green: 242 / 255, blue: 230 / 255),
                        ]),
                        startPoint: CGPoint(x: 0, y: S * 0.21),
                        endPoint: CGPoint(x: 0, y: S * 0.46)
                    )
                )
            }

            var trunk = Path()
            trunk.move(to: point(0.470, 0.570))
            trunk.addLine(to: point(0.530, 0.570))
            trunk.addCurve(
                to: point(0.545, 0.455),
                control1: point(0.530, 0.525),
                control2: point(0.538, 0.485)
            )
            trunk.addLine(to: point(0.455, 0.455))
            trunk.addCurve(
                to: point(0.470, 0.570),
                control1: point(0.462, 0.485),
                control2: point(0.470, 0.525)
            )
            trunk.closeSubpath()
            context.fill(trunk, with: .color(.white))

            var waterline = Path()
            waterline.move(to: point(0.235, 0.272))
            waterline.addLine(to: point(0.765, 0.272))
            context.stroke(
                waterline,
                with: .color(Color(red: 198 / 255, green: 236 / 255, blue: 219 / 255).opacity(0.26)),
                style: StrokeStyle(lineWidth: max(0.5, S * 0.006), lineCap: .round)
            )

            var roots = Path()
            roots.move(to: point(0.466, 0.470))
            roots.addCurve(
                to: point(0.305, 0.272),
                control1: point(0.430, 0.465),
                control2: point(0.310, 0.390)
            )
            roots.move(to: point(0.534, 0.470))
            roots.addCurve(
                to: point(0.695, 0.272),
                control1: point(0.570, 0.465),
                control2: point(0.690, 0.390)
            )
            roots.move(to: point(0.484, 0.458))
            roots.addCurve(
                to: point(0.412, 0.262),
                control1: point(0.462, 0.430),
                control2: point(0.412, 0.335)
            )
            roots.move(to: point(0.516, 0.458))
            roots.addCurve(
                to: point(0.588, 0.262),
                control1: point(0.538, 0.430),
                control2: point(0.588, 0.335)
            )
            context.stroke(
                roots,
                with: .color(.white),
                style: StrokeStyle(lineWidth: max(0.5, S * 0.038), lineCap: .round)
            )

            var centreRoot = Path()
            centreRoot.move(to: point(0.500, 0.455))
            centreRoot.addCurve(
                to: point(0.500, 0.252),
                control1: point(0.508, 0.400),
                control2: point(0.492, 0.320)
            )
            context.stroke(
                centreRoot,
                with: .color(.white),
                style: StrokeStyle(lineWidth: max(0.5, S * 0.034), lineCap: .round)
            )

            for ripple in [
                (y: CGFloat(0.248), width: CGFloat(0.380), alpha: CGFloat(0.32)),
                (y: CGFloat(0.216), width: CGFloat(0.270), alpha: CGFloat(0.24)),
                (y: CGFloat(0.188), width: CGFloat(0.160), alpha: CGFloat(0.18)),
            ] {
                var line = Path()
                line.move(to: point(0.5 - ripple.width / 2, ripple.y))
                line.addLine(to: point(0.5 + ripple.width / 2, ripple.y))
                context.stroke(
                    line,
                    with: .color(Color(red: 198 / 255, green: 236 / 255, blue: 219 / 255)
                        .opacity(ripple.alpha)),
                    style: StrokeStyle(lineWidth: max(0.5, S * 0.007), lineCap: .round)
                )
            }
        }
    }
}

/// The app mark: the tidal-green tile with the white mangrove, as in the icon.
struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.173, green: 0.612, blue: 0.455),
                            Color(red: 0.063, green: 0.408, blue: 0.294),
                            Color(red: 0.027, green: 0.212, blue: 0.176)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: max(0.5, size * 0.014))
                )

            MangroveMark()
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(size > 40 ? 0.20 : 0.14), radius: size * 0.07, y: size * 0.02)
    }
}

/// A hairline divider that matches the pane separators.
struct Rule: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(
                width: vertical ? 1 : nil,
                height: vertical ? nil : 1
            )
    }
}

// MARK: - Small pieces

/// Filled button in the mark's green. Used instead of `borderedProminent` so
/// the primary action always carries the brand colour and its own type scale.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
        return configuration.label
            .font(Theme.Typeface.ui(compact ? 11 : 12, .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 4 : 7)
            .background(shape.fill(Theme.leaf).opacity(configuration.isPressed ? 0.82 : 1))
            .contentShape(shape)
    }
}

/// Quiet metadata pill, e.g. "Read write" for a shared project.
struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(Theme.Typeface.ui(9, .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

/// Section heading used at the top of every pane.
struct PaneHead<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typeface.ui(12, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typeface.ui(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }
}

extension PaneHead where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Search field used in the project list.
struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search projects"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typeface.ui(11))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.bottom, 8)
    }
}

/// Transient, non-blocking message. Failures stay until dismissed.
struct NoticeBanner: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isError ? Theme.warning : Theme.leaf)
                .padding(.top, 1)
            Text(message)
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}

/// Centered empty state, used whenever a pane has nothing to show yet.
struct EmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.Typeface.display(15, .medium))
            Text(detail)
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            actions.padding(.top, 3)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(icon: String, title: String, detail: String) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// A small spinner drawn with SwiftUI shapes.
///
/// The system `ProgressView` is backed by `NSProgressIndicator`, and when SwiftUI
/// measures one inside a macOS toolbar the layout traits it reports are not
/// valid, which traps the process. Drawing the arc keeps the toolbar's layout
/// entirely in SwiftUI.
struct TinySpinner: View {
    var size: CGFloat = 11
    var tint: Color = Theme.leaf
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                .linear(duration: 0.85).repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear { isSpinning = true }
    }
}

/// Progress line shown while a project downloads.
struct LoadingPane: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(Theme.Typeface.ui(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
