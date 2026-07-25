import Foundation

/// An edge endpoint in one row: which lane it occupies and which branch-line
/// color it belongs to. Colors follow branch *lines*, not lane columns —
/// when a lane is freed and reused by another branch, the new branch gets a
/// fresh color (same approach as VS Code Git Graph).
struct GraphEdge: Hashable {
    let lane: Int
    let color: Int
}

/// One row of the commit graph. Coordinates are lane indices (column numbers).
///
/// Rendering model per row (top edge → center → bottom edge):
///   - `passThrough`: lanes that run straight through this row (unrelated to the dot)
///   - `mergeSources`: lanes at the TOP edge that terminate into this commit's dot
///     (children lines arriving here; EMPTY for branch tips — nothing above connects)
///   - `parentLanes`: lanes at the BOTTOM edge leaving this commit's dot toward parents
struct GraphRow: Identifiable {
    let commit: Commit
    let column: Int
    let columnColor: Int
    let passThrough: [GraphEdge]
    let mergeSources: [GraphEdge]
    let parentLanes: [GraphEdge]
    /// Total number of lanes in use at this row (for sizing).
    let laneCount: Int

    var id: String { commit.hash }
}

enum GraphLayout {
    /// Assign lanes to commits given in topological order (children before parents).
    static func layout(commits: [Commit]) -> [GraphRow] {
        var lanes: [String?] = []   // lanes[i] == hash that lane i expects next
        var laneColors: [Int] = []  // branch-line color currently flowing in lane i
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func allocateLane(expecting hash: String?, color: Int) -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) {
                lanes[free] = hash
                laneColors[free] = color
                return free
            }
            lanes.append(hash)
            laneColors.append(color)
            return lanes.count - 1
        }

        for commit in commits {
            // Lanes waiting for this commit (children already drawn above).
            let matching = lanes.indices.filter { lanes[$0] == commit.hash }

            let column: Int
            let columnColor: Int
            if let first = matching.first {
                column = first
                columnColor = laneColors[first]
            } else {
                // Branch tip: takes a free lane and starts a new branch line.
                columnColor = nextColor
                nextColor += 1
                column = allocateLane(expecting: nil, color: columnColor)
            }

            // Top edge: only children lines arrive at the dot. Tips get none —
            // drawing a stub from the top edge here was a bug.
            let mergeSources = matching.map { GraphEdge(lane: $0, color: laneColors[$0]) }
            let passThrough = lanes.indices
                .filter { lanes[$0] != nil && !matching.contains($0) }
                .map { GraphEdge(lane: $0, color: laneColors[$0]) }

            // Release all lanes that terminated here.
            for i in matching { lanes[i] = nil }

            // Bottom edge: connect the dot to each parent's lane.
            var parentLanes: [GraphEdge] = []
            for (idx, parent) in commit.parents.enumerated() {
                if idx == 0 {
                    // First parent keeps the commit's own lane and color —
                    // keeps the main line straight.
                    lanes[column] = parent
                    laneColors[column] = columnColor
                    parentLanes.append(GraphEdge(lane: column, color: columnColor))
                } else if let existing = lanes.firstIndex(of: parent) {
                    // Another drawn commit already expects this parent —
                    // merge into that line, using ITS color.
                    parentLanes.append(GraphEdge(lane: existing, color: laneColors[existing]))
                } else {
                    // New branch line for a not-yet-seen parent.
                    let color = nextColor
                    nextColor += 1
                    let lane = allocateLane(expecting: parent, color: color)
                    parentLanes.append(GraphEdge(lane: lane, color: color))
                }
            }

            let laneCount = max(
                lanes.count,
                column + 1,
                (passThrough.map(\.lane).max() ?? -1) + 1,
                (mergeSources.map(\.lane).max() ?? -1) + 1,
                (parentLanes.map(\.lane).max() ?? -1) + 1
            )

            rows.append(GraphRow(
                commit: commit,
                column: column,
                columnColor: columnColor,
                passThrough: passThrough,
                mergeSources: mergeSources,
                parentLanes: parentLanes,
                laneCount: laneCount
            ))
        }

        return rows
    }

    /// The widest lane count across all rows (drives graph column width).
    static func maxLanes(of rows: [GraphRow]) -> Int {
        rows.map(\.laneCount).max() ?? 1
    }
}
