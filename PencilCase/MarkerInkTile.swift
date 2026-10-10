import Foundation
import CoreGraphics

/// Logical-point tiles retain native backing resolution on every display.
nonisolated struct MarkerInkTile: Hashable {
    static let size: CGFloat = 256
    let column: Int
    let row: Int

    var frame: CGRect {
        CGRect(x: CGFloat(column) * Self.size, y: CGFloat(row) * Self.size,
               width: Self.size, height: Self.size)
    }

    static func covering(_ regions: [CGRect], in bounds: CGRect) -> Set<Self> {
        var result = Set<Self>()
        for region in regions {
            let rect = region.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let firstColumn = Int(floor(rect.minX / size))
            let lastColumn = Int(ceil(rect.maxX / size)) - 1
            let firstRow = Int(floor(rect.minY / size))
            let lastRow = Int(ceil(rect.maxY / size)) - 1
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    result.insert(Self(column: column, row: row))
                }
            }
        }
        return result
    }
}
