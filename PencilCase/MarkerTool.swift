import AppKit

struct MarkerTool: Identifiable {
    let id: Int
    var color: NSColor
    let width: Double
    let opacity: CGFloat
    var name: String { width <= 3 ? "Pencil" : width < 10 ? "Marker" : "Highlighter" }

    static let defaults = [
        MarkerTool(id: 0, color: MarkerColor.presets[0].color, width: 2, opacity: 1),
        MarkerTool(id: 1, color: MarkerColor.presets[1].color, width: 6, opacity: 1),
        MarkerTool(id: 2, color: MarkerColor.presets[3].color, width: 16, opacity: 0.45)
    ]
}

/// Axis-aligned windows enclose rotated artwork; AppKit view frames never rotate.
nonisolated enum MarkerGeometry {
    static let spawnAngles: [CGFloat] = [-18, 9, -8]

    static func size(angle: CGFloat) -> CGSize {
        let radians = angle * .pi / 180
        return CGSize(width: ceil(abs(cos(radians)) * 66 + abs(sin(radians)) * 210),
                      height: ceil(abs(sin(radians)) * 66 + abs(cos(radians)) * 210))
    }

    static func localPoint(_ point: CGPoint, size: CGSize, angle: CGFloat) -> CGPoint {
        let radians = -angle * .pi / 180
        let x = point.x - size.width / 2
        let y = point.y - size.height / 2
        return CGPoint(x: x * cos(radians) - y * sin(radians) + 33,
                       y: x * sin(radians) + y * cos(radians) + 105)
    }

    static func spawnFrames(in screen: CGRect) -> [CGRect] {
        let sizes = spawnAngles.map { size(angle: $0) }
        let gap: CGFloat = 22
        let totalWidth = sizes.reduce(0) { $0 + $1.width } + gap * 2
        var x = max(screen.minX, min(screen.midX + 120, screen.maxX - totalWidth - 24))
        let offsets: [CGFloat] = [10, -18, 22]
        return sizes.enumerated().map { index, size in
            let y = max(screen.minY, min(screen.midY - size.height / 2 + offsets[index], screen.maxY - size.height))
            let result = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + gap
            return result
        }
    }
}
