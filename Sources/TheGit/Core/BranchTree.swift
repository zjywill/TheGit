import Foundation

/// A node in the sidebar branch tree: either a folder (grouping a `/`
/// prefix, git-flow style: feature/, hotfix/, release/…) or a leaf branch.
struct BranchNode: Identifiable {
    let id: String
    let name: String
    let branch: Branch?
    /// nil for leaves — OutlineGroup treats nil children as a leaf row.
    var children: [BranchNode]?
}

enum BranchTree {
    /// Build a folder tree from branch names split on "/".
    static func build(_ branches: [Branch], path: (Branch) -> String, idPrefix: String = "") -> [BranchNode] {
        let pairs = branches.map { (path($0).split(separator: "/").map(String.init), $0) }
        return build(pairs: pairs, prefix: idPrefix)
    }

    /// Remote branches grouped as remote → folders → leaves.
    static func remoteTree(_ branches: [Branch]) -> [BranchNode] {
        var byRemote: [String: [Branch]] = [:]
        var order: [String] = []
        for branch in branches {
            guard case .remote(let remote) = branch.kind else { continue }
            if byRemote[remote] == nil { order.append(remote) }
            byRemote[remote, default: []].append(branch)
        }
        return order.map { remote in
            BranchNode(
                id: "remote:\(remote)",
                name: remote,
                branch: nil,
                children: build(byRemote[remote]!, path: \.shortName, idPrefix: "remote:\(remote)/")
            )
        }
    }

    private static func build(pairs: [([String], Branch)], prefix: String) -> [BranchNode] {
        var leaves: [BranchNode] = []
        var groups: [String: [([String], Branch)]] = [:]
        var order: [String] = []

        for (segments, branch) in pairs {
            if segments.count <= 1 {
                leaves.append(BranchNode(
                    id: prefix + branch.id,
                    name: segments.first ?? branch.name,
                    branch: branch,
                    children: nil
                ))
            } else {
                let head = segments[0]
                if groups[head] == nil { order.append(head) }
                groups[head, default: []].append((Array(segments.dropFirst()), branch))
            }
        }

        let folders = order.map { head in
            BranchNode(
                id: prefix + head + "/",
                name: head,
                branch: nil,
                children: build(pairs: groups[head]!, prefix: prefix + head + "/")
            )
        }

        return (folders + leaves).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
