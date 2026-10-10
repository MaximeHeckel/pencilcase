import CoreGraphics

/// A ruler edge in desktop coordinates. Lock the selected edge for one stroke.
struct MarkerGuide {
    let start: CGPoint
    let end: CGPoint

    func project(_ point: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return start }

        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return CGPoint(x: start.x + dx * t, y: start.y + dy * t)
    }

    func distance(to point: CGPoint) -> CGFloat {
        let projected = project(point)
        return hypot(point.x - projected.x, point.y - projected.y)
    }
}
