import SwiftUI

/// Equal-width columns, as many as fit, wrapping onto more rows: what
/// `LazyVGrid` does with one adaptive column, for a handful of items that
/// are all on screen anyway. Each item is built and measured once.
///
/// Home's row of buttons uses it. (A deck's tiles stay in a `LazyVGrid`:
/// there, only building the tiles in view is the cheaper way round.)
struct ColumnsLayout: Layout {
    /// The narrowest a column may be; this decides how many fit.
    var minimum: CGFloat
    /// The widest a column may grow to fill the row.
    var maximum: CGFloat = .infinity
    var spacing: CGFloat
    /// Put everything on one row whenever it fits at the minimum width.
    var oneRowIfFits = false

    struct Cache {
        var width: CGFloat = -1
        var columns = 1
        var columnWidth: CGFloat = 0
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        let count = subviews.count
        var columns = max(1, Int((width + spacing) / (minimum + spacing)))
        if oneRowIfFits, columns >= count { columns = max(1, count) }
        let columnWidth = max(0, min(maximum, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
        var heights: [CGFloat] = []
        var index = 0
        while index < count {
            let row = subviews[index..<min(index + columns, count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0)
            index += columns
        }
        cache = Cache(width: width, columns: columns, columnWidth: columnWidth, rowHeights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // Asked for its ideal width (no width offered): one row at the minimum width.
        let ideal = CGFloat(subviews.count) * minimum + CGFloat(max(0, subviews.count - 1)) * spacing
        let width = proposal.width.map { $0.isFinite ? $0 : ideal } ?? ideal
        measure(width: width, subviews: subviews, cache: &cache)
        let height = cache.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, cache.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in cache.rowHeights.enumerated() {
            for column in 0..<cache.columns {
                let index = row * cache.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (cache.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: cache.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}
