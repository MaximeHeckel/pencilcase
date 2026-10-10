import Foundation
import CoreGraphics

@main struct InkTileTests {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 2880, height: 1620)
        precondition(MarkerInkTile.covering([], in: screen).isEmpty)
        precondition(MarkerInkTile.covering([.null, .zero, CGRect(x: -200, y: 0, width: 100, height: 100)], in: screen).isEmpty)
        let line = CGRect(x: 100, y: 100, width: 1200, height: 20)
        let tiles = MarkerInkTile.covering([line], in: screen)
        precondition(tiles.count == 6)
        precondition(MarkerInkTile.covering([line, line], in: screen) == tiles)
        precondition(MarkerInkTile.covering([CGRect(x: 0, y: 0, width: 256, height: 256)], in: screen).count == 1)
        precondition(MarkerInkTile.covering([CGRect(x: 255, y: 255, width: 2, height: 2)], in: screen).count == 4)
        let edge = CGRect(x: 2850, y: 1590, width: 100, height: 100)
        let edgeTiles = MarkerInkTile.covering([edge], in: screen)
        precondition(edgeTiles.count == 1)
        precondition(edgeTiles.first!.frame.intersection(screen).contains(edge.intersection(screen)))
        for x in stride(from: 0, to: 2880, by: 37) {
            let rect = CGRect(x: x, y: x % 1600, width: 50, height: 20).intersection(screen)
            let covered = MarkerInkTile.covering([rect], in: screen).reduce(CGRect.null) { $0.union($1.frame) }
            precondition(covered.contains(rect))
        }
        let fullBytes = screen.width * screen.height * 4 * 8
        let tileBytes = CGFloat(tiles.count) * 256 * 256 * 4 * 8
        print("PASS: sparse coverage, clipping, exact boundaries, overlaps and empty cleanup; example native 2x RGBA16 surfaces: full \(Int(fullBytes / 1048576)) MiB vs tiles \(Int(tileBytes / 1048576)) MiB (allocation math, not measured footprint).")
    }
}
