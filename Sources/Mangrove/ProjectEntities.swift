import Foundation

/// One document, uploaded file or folder in Overleaf's own tree.
///
/// The working copy is keyed by relative path, but Overleaf's write routes are
/// keyed by entity id. Ids only arrive through the realtime `joinProjectResponse`,
/// so the tree is parsed once there and kept alongside the join.
struct ProjectEntity: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case doc
        case file
        case folder
    }

    let id: String
    let name: String
    let kind: Kind
    /// Path relative to the project root. The root folder itself is "".
    let path: String
    let parentFolderId: String?
}

struct ProjectEntityTree: Equatable {
    let rootFolderId: String?
    let entities: [ProjectEntity]

    var folders: [ProjectEntity] {
        entities.filter { $0.kind == .folder }.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    func entity(at path: String) -> ProjectEntity? {
        entities.first { $0.path == path }
    }

    func folder(at path: String) -> ProjectEntity? {
        entities.first { $0.kind == .folder && $0.path == path }
    }

    /// Folders that can receive a file: the root, then every folder in path order.
    var destinations: [ProjectEntity] {
        [root].compactMap { $0 } + folders
    }

    var root: ProjectEntity? {
        guard let rootFolderId else { return nil }
        return ProjectEntity(
            id: rootFolderId, name: "Project", kind: .folder, path: "", parentFolderId: nil
        )
    }

    /// Whether `path` is inside `folderPath`. The root (`""`) contains everything.
    static func isInside(_ path: String, folder folderPath: String) -> Bool {
        folderPath.isEmpty || path == folderPath || path.hasPrefix(folderPath + "/")
    }
}

enum ProjectEntityTreeParser {

    static func tree(fromJoinPayload payload: [String: Any]) -> ProjectEntityTree? {
        guard let project = payload["project"] as? [String: Any],
              let roots = project["rootFolder"] as? [[String: Any]],
              let root = roots.first,
              let rootId = root["_id"] as? String, !rootId.isEmpty else { return nil }
        var entities: [ProjectEntity] = []
        walk(root, parentPath: "", parentFolderId: nil, rootId: rootId, into: &entities)
        // The root folder is represented by `root` in `destinations`, not as an
        // ordinary row, so do not duplicate it here.
        entities.removeAll { $0.id == rootId && $0.kind == .folder }
        return ProjectEntityTree(rootFolderId: rootId, entities: entities)
    }

    private static func walk(
        _ node: [String: Any],
        parentPath: String,
        parentFolderId: String?,
        rootId: String,
        into entities: inout [ProjectEntity]
    ) {
        let nodeId = node["_id"] as? String ?? ""
        let folderName = node["name"] as? String ?? ""
        let isRoot = nodeId == rootId
        let currentPath = isRoot ? "" : join(parentPath, folderName)

        if !isRoot, !nodeId.isEmpty {
            entities.append(ProjectEntity(
                id: nodeId, name: folderName, kind: .folder,
                path: currentPath, parentFolderId: parentFolderId
            ))
        }

        let currentFolderId = nodeId.isEmpty ? parentFolderId : nodeId

        for doc in node["docs"] as? [[String: Any]] ?? [] {
            guard let id = doc["_id"] as? String,
                  let name = doc["name"] as? String, !id.isEmpty else { continue }
            entities.append(ProjectEntity(
                id: id, name: name, kind: .doc,
                path: join(currentPath, name), parentFolderId: currentFolderId
            ))
        }
        for file in node["fileRefs"] as? [[String: Any]] ?? [] {
            guard let id = file["_id"] as? String,
                  let name = file["name"] as? String, !id.isEmpty else { continue }
            entities.append(ProjectEntity(
                id: id, name: name, kind: .file,
                path: join(currentPath, name), parentFolderId: currentFolderId
            ))
        }
        for folder in node["folders"] as? [[String: Any]] ?? [] {
            walk(
                folder, parentPath: currentPath,
                parentFolderId: currentFolderId, rootId: rootId, into: &entities
            )
        }
    }

    private static func join(_ path: String, _ name: String) -> String {
        path.isEmpty ? name : "\(path)/\(name)"
    }
}
