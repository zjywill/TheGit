import CoreGraphics

/// Geometry for a row of variable-width tabs being dragged around.
/// Pure arithmetic, kept out of the view so it can be tested: the slot maths
/// is the part of a reorder that goes subtly wrong, and it goes wrong in
/// ways that are miserable to spot by dragging things with a mouse.
enum TabStrip {
    /// Centre of every slot, measured from the strip's leading edge.
    static func centers(widths: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        result.reserveCapacity(widths.count)
        var x: CGFloat = 0
        for width in widths {
            result.append(x + width / 2)
            x += width + spacing
        }
        return result
    }

    /// Which slot a tab currently in `current` belongs in while it is being
    /// held with its centre at `x`.
    ///
    /// A neighbour gives way only once the held tab is past that
    /// neighbour's own centre — not its near edge. That's what makes
    /// dragging past a much wider tab take the whole width of it instead of
    /// swapping the moment they touch, and it's why a tab never oscillates:
    /// after the swap the held tab sits where the neighbour was, which is
    /// on the far side of the line it just crossed.
    static func slot(holding x: CGFloat, current: Int, centers: [CGFloat]) -> Int {
        guard centers.indices.contains(current) else { return current }
        var target = current
        if x > centers[current] {
            while target + 1 < centers.count, x > centers[target + 1] { target += 1 }
        } else {
            while target - 1 >= 0, x < centers[target - 1] { target -= 1 }
        }
        return target
    }
}
