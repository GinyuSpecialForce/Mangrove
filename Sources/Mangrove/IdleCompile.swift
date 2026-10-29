import Foundation

/// The rules for compiling after a pause in typing.
///
/// A compile is deliberately not started when the page is hidden, while a merge
/// is undecided, or when there is no way to build (offline with no local TeX).
/// Keeping the decision in one pure function makes the quiet behavior testable.
enum IdleCompilePolicy {
    /// Long enough that ordinary pauses do not spend a compile, short enough that
    /// the page feels connected to the source.
    static let delay: UInt64 = 20_000_000_000

    static func shouldCompile(
        enabled: Bool,
        hasProject: Bool,
        needsCompile: Bool,
        isCompiling: Bool,
        isOpeningProject: Bool,
        hasPendingMerges: Bool,
        pageVisible: Bool,
        isOnline: Bool,
        localTeXAvailable: Bool
    ) -> Bool {
        guard enabled, hasProject, needsCompile, pageVisible,
              !isCompiling, !isOpeningProject, !hasPendingMerges else {
            return false
        }
        return isOnline || localTeXAvailable
    }
}
