import Foundation

/// Decides where files picked from disk land in a project.
///
/// Overleaf's upload route takes one file at a time, and a name repeated inside
/// one selection would make the second copy overwrite the first in the working
/// copy before either is sent. Names are therefore made unique the way Finder
/// does it: `figure.png`, `figure 2.png`.
enum FileImport {

    /// Overleaf allows 50 MB per file. Catching it here gives a clearer message
    /// than a failed upload would.
    static let maxBytes = 50 * 1024 * 1024

    struct Item: Equatable {
        let source: URL
        let name: String
        let relativePath: String
    }

    struct Skip: Equatable {
        let name: String
        let reason: String
    }

    struct Plan: Equatable {
        var items: [Item] = []
        var skipped: [Skip] = []
    }

    static func plan(urls: [URL], folder: String, maxBytes: Int = maxBytes) -> Plan {
        var plan = Plan()
        var taken: Set<String> = []
        let manager = FileManager.default

        for url in urls {
            let name = url.lastPathComponent
            guard !name.isEmpty, name != "/" else {
                plan.skipped.append(Skip(name: url.path, reason: "has no file name"))
                continue
            }

            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                plan.skipped.append(Skip(name: name, reason: "could not be found"))
                continue
            }
            if isDirectory.boolValue {
                plan.skipped.append(Skip(name: name, reason: "is a folder — choose individual files"))
                continue
            }

            let attributes = try? manager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBytes {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
                plan.skipped.append(Skip(name: name, reason: "is larger than \(limit)"))
                continue
            }

            let unique = uniqueName(name, avoiding: taken)
            taken.insert(unique)
            plan.items.append(Item(
                source: url,
                name: unique,
                relativePath: relativePath(for: unique, in: folder)
            ))
        }

        return plan
    }

    static func relativePath(for name: String, in folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? name : "\(trimmed)/\(name)"
    }

    /// `figure.png` → `figure 2.png` when `figure.png` is already taken.
    static func uniqueName(_ name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let path = name as NSString
        let extensionName = path.pathExtension
        let stem = path.deletingPathExtension
        var index = 2
        while true {
            let candidate = extensionName.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionName)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }
}
