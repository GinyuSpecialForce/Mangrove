import Foundation

/// Three-way line merge, the same shape `diff3` and `git merge` produce.
///
/// The client never holds a formal document model — a file is plain `.tex` text
/// and Overleaf's upload route replaces it wholesale. So when someone else has
/// saved the same file since our last sync, the only safe way to keep both sets
/// of edits is to merge them against their common ancestor:
///
///     mine   the file in the working copy
///     base   the remote version we last saw
///     theirs the remote version now
///
/// Changes to different regions combine cleanly. Changes to the *same* region
/// become a conflict the user resolves, rather than a silent overwrite.
enum LineMerge {

    /// One region both sides changed differently.
    struct Conflict: Equatable {
        let base: String
        let mine: String
        let theirs: String
    }

    enum Outcome: Equatable {
        case clean(String)
        /// `text` is the merge with every conflict resolved in favour of mine,
        /// so callers have something usable if the user keeps their version.
        case conflicted(text: String, conflicts: [Conflict])
    }

    private enum Part: Equatable {
        case common(String)
        case mine(String)
        case theirs(String)
        case conflict(Conflict)
    }

    // MARK: - Public

    static func merge(mine: String, base: String, theirs: String) -> Outcome {
        let parts = parts(mine: split(mine), base: split(base), theirs: split(theirs))
        let conflicts = parts.compactMap { part -> Conflict? in
            if case let .conflict(conflict) = part { return conflict }
            return nil
        }
        let text = join(parts, choosingTheirs: Array(repeating: false, count: conflicts.count))
        return conflicts.isEmpty ? .clean(text) : .conflicted(text: text, conflicts: conflicts)
    }

    /// Rebuilds the merge with one choice per conflict: true takes the remote
    /// side, false keeps the local side.
    static func resolve(mine: String, base: String, theirs: String, choosingTheirs choices: [Bool]) -> String {
        join(parts(mine: split(mine), base: split(base), theirs: split(theirs)), choosingTheirs: choices)
    }

    // MARK: - Lines

    /// Keeps each line's terminator on the line, so joining is concatenation
    /// and a missing final newline survives the merge like any other edit.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                let end = text.index(after: index)
                lines.append(String(text[start..<end]))
                start = end
            }
            index = text.index(after: index)
        }
        if start < text.endIndex {
            lines.append(String(text[start..<text.endIndex]))
        }
        return lines
    }

    private static func join(_ parts: [Part], choosingTheirs choices: [Bool]) -> String {
        var result = ""
        var conflictIndex = 0
        for part in parts {
            switch part {
            case let .common(text), let .mine(text), let .theirs(text):
                result += text
            case let .conflict(conflict):
                let useTheirs = conflictIndex < choices.count ? choices[conflictIndex] : false
                result += useTheirs ? conflict.theirs : conflict.mine
                conflictIndex += 1
            }
        }
        return result
    }

    // MARK: - Matching

    /// Line indices shared by `base` and `other`, computed by the standard
    /// library's Myers diff.
    static func matches(base: [String], other: [String]) -> [Int: Int] {
        let difference = other.difference(from: base)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var pairs: [Int: Int] = [:]
        var b = 0
        var o = 0
        while b < base.count, o < other.count {
            if removed.contains(b) {
                b += 1
                continue
            }
            if inserted.contains(o) {
                o += 1
                continue
            }
            pairs[b] = o
            b += 1
            o += 1
        }
        return pairs
    }

    // MARK: - diff3

    private static func parts(mine: [String], base: [String], theirs: [String]) -> [Part] {
        let mineMatches = matches(base: base, other: mine)
        let theirsMatches = matches(base: base, other: theirs)

        var parts: [Part] = []
        var i = 0   // base
        var j = 0   // mine
        var k = 0   // theirs

        func append(_ part: Part) {
            if case let .common(text) = part, text.isEmpty { return }
            parts.append(part)
        }

        func emit(baseRange: Range<Int>, mineRange: Range<Int>, theirsRange: Range<Int>) {
            let baseText = base[baseRange].joined()
            let mineText = mine[mineRange].joined()
            let theirsText = theirs[theirsRange].joined()

            if mineText == theirsText {
                append(.common(mineText))
            } else if mineText == baseText {
                append(.theirs(theirsText))
            } else if theirsText == baseText {
                append(.mine(mineText))
            } else {
                append(.conflict(Conflict(base: baseText, mine: mineText, theirs: theirsText)))
            }
        }

        while true {
            // A run of lines all three versions agree on.
            while i < base.count, j < mine.count, k < theirs.count,
                  mine[j] == base[i], theirs[k] == base[i] {
                append(.common(base[i]))
                i += 1
                j += 1
                k += 1
            }

            if i >= base.count, j >= mine.count, k >= theirs.count { break }

            // The next line both sides still share; everything before it is a
            // region one or both sides rewrote.
            var sync: (base: Int, mine: Int, theirs: Int)?
            var candidate = i
            while candidate < base.count {
                if let m = mineMatches[candidate], let t = theirsMatches[candidate],
                   m >= j, t >= k {
                    sync = (candidate, m, t)
                    break
                }
                candidate += 1
            }

            guard let sync else {
                if i < base.count || j < mine.count || k < theirs.count {
                    emit(baseRange: i..<base.count, mineRange: j..<mine.count, theirsRange: k..<theirs.count)
                }
                break
            }

            if sync.base > i || sync.mine > j || sync.theirs > k {
                emit(baseRange: i..<sync.base, mineRange: j..<sync.mine, theirsRange: k..<sync.theirs)
            }
            i = sync.base
            j = sync.mine
            k = sync.theirs
        }

        return parts
    }
}

// MARK: - Deciding what a file needs

/// What to do with one path when the working copy, the last remote version and
/// the current remote version are compared.
enum SyncPlanner {

    enum Action: Equatable {
        /// All three agree, or only the baseline is missing on one side.
        case unchanged
        /// Only the local copy changed (including a brand new local file).
        case uploadLocal
        /// Only the remote copy changed, or the remote file is new/removed.
        case adoptRemote
        /// Both sides changed text: merge them.
        case merge(mine: String, base: String, theirs: String)
        /// Both sides changed, and it cannot be merged line by line.
        case conflict
    }

    static func action(local: Data?, base: Data?, remote: Data?, isText: Bool) -> Action {
        if local == remote { return .unchanged }
        // Nothing changed remotely, so the local copy is safe to upload.
        if remote == base { return .uploadLocal }
        // Nothing changed locally, so the remote copy wins cleanly.
        if local == base { return .adoptRemote }

        if isText,
           let mine = decode(local), let ancestor = decode(base), let theirs = decode(remote) {
            return .merge(mine: mine, base: ancestor, theirs: theirs)
        }
        return .conflict
    }

    /// `nil` means "no such file"; a non-text or non-UTF-8 file also fails to
    /// decode. Both are handled by the caller's `.conflict` case, so the
    /// difference only matters inside this function.
    private static func decode(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - A pending conflict

/// A file the user has to decide about. Held in memory only: the local copy is
/// never modified until the decision is made.
struct PendingMerge: Identifiable {
    enum Kind: Equatable {
        case text([LineMerge.Conflict])
        case binary
    }

    let id = UUID()
    let path: String
    let mine: String
    let base: String
    let theirs: String
    let kind: Kind
    let localData: Data?
    let remoteData: Data?

    var isBinary: Bool {
        if case .binary = kind { return true }
        return false
    }
}

// MARK: - Connectivity

/// Whether a failure means "Overleaf is unreachable right now" rather than
/// "Overleaf said no". The first is worth keeping work locally and retrying;
/// the second has to be shown to the user.
enum Connectivity {
    static func isOffline(_ error: Error) -> Bool {
        if case MangroveError.offline = error { return true }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
                 .internationalRoamingOff, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return isOffline(URLError(URLError.Code(rawValue: nsError.code)))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isOffline(underlying)
        }
        return false
    }
}
