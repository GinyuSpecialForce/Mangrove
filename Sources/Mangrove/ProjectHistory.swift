import Foundation

/// One revision of one file, captured when it reached Overleaf.
struct HistorySnapshot: Identifiable, Codable, Equatable {
    let id: String
    let path: String
    let savedAt: Date
    let bytes: Int
    /// File name inside the history directory.
    let fileName: String
}

/// A small, local safety net: every successful upload leaves the uploaded text
/// behind, so a bad edit can be compared and restored even when Overleaf's own
/// history is not reachable through the routes this app uses.
///
/// Snapshots are per project and per path, capped so a long-lived project cannot
/// grow without bound. Nothing here is uploaded.
final class ProjectHistory {

    let root: URL
    private let indexURL: URL
    private var snapshots: [HistorySnapshot]
    private let maxPerFile: Int

    init(root: URL, maxPerFile: Int = 25) {
        self.root = root
        self.indexURL = root.appendingPathComponent("index.json")
        self.maxPerFile = maxPerFile
        let stored = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([HistorySnapshot].self, from: $0) }
        self.snapshots = stored ?? []
    }

    func snapshots(for path: String) -> [HistorySnapshot] {
        snapshots.filter { $0.path == path }.sorted { $0.savedAt > $1.savedAt }
    }

    /// Records a revision unless it is byte-identical to the newest one.
    @discardableResult
    func record(path: String, text: String, savedAt: Date = Date()) -> HistorySnapshot? {
        guard let data = text.data(using: .utf8), data.count <= 2 * 1024 * 1024 else { return nil }
        if let newest = snapshots(for: path).first,
           let existing = self.contents(of: newest),
           existing == text {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = UUID().uuidString
        let fileName = "\(stamp(formatter, savedAt))-\(id.prefix(8)).txt"

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return nil
        }

        let snapshot = HistorySnapshot(
            id: id, path: path, savedAt: savedAt, bytes: data.count, fileName: fileName
        )
        snapshots.append(snapshot)
        prune(path: path)
        persist()
        return snapshot
    }

    func contents(of snapshot: HistorySnapshot) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(snapshot.fileName)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func stamp(_ formatter: DateFormatter, _ date: Date) -> String {
        formatter.string(from: date)
    }

    private func prune(path: String) {
        let forPath = snapshots.filter { $0.path == path }.sorted { $0.savedAt > $1.savedAt }
        guard forPath.count > maxPerFile else { return }
        let doomed = forPath.dropFirst(maxPerFile)
        for snapshot in doomed {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(snapshot.fileName))
        }
        let ids = Set(doomed.map(\.id))
        snapshots.removeAll { ids.contains($0.id) }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

}

// MARK: - Line diff

struct DiffRow: Identifiable {
    enum Kind { case same, added, removed }

    let id = UUID()
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

enum LineDiff {

    /// Line-based longest-common-subsequence diff, capped so a pathological file
    /// cannot freeze the UI. Callers show a plain message when nil is returned.
    static func rows(old: String, new: String, limit: Int = 800) -> [DiffRow]? {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        guard oldLines.count <= limit, newLines.count <= limit else { return nil }

        let n = oldLines.count
        let m = newLines.count
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1

        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        table[i * width + j] = table[(i + 1) * width + j + 1] + 1
                    } else {
                        table[i * width + j] = max(
                            table[(i + 1) * width + j],
                            table[i * width + j + 1]
                        )
                    }
                }
            }
        }

        var rows: [DiffRow] = []
        rows.reserveCapacity(n + m)
        var i = 0
        var j = 0
        while i < n, j < m {
            if oldLines[i] == newLines[j] {
                rows.append(DiffRow(kind: .same, text: oldLines[i], oldLine: i + 1, newLine: j + 1))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                rows.append(DiffRow(kind: .removed, text: oldLines[i], oldLine: i + 1, newLine: nil))
                i += 1
            } else {
                rows.append(DiffRow(kind: .added, text: newLines[j], oldLine: nil, newLine: j + 1))
                j += 1
            }
        }
        while i < n {
            rows.append(DiffRow(kind: .removed, text: oldLines[i], oldLine: i + 1, newLine: nil))
            i += 1
        }
        while j < m {
            rows.append(DiffRow(kind: .added, text: newLines[j], oldLine: nil, newLine: j + 1))
            j += 1
        }
        return rows
    }
}
