import AppKit

/// Geometry stays in desktop coordinates. Only the active stroke is mutable;
/// finishing freezes a vector path that can be reused by every canvas and redo.
@MainActor
final class MarkerStroke {
    let first: CGPoint
    private(set) var last: CGPoint
    private(set) var pointCount = 1
    let color: NSColor
    let width: CGFloat
    let opacity: CGFloat
    let excludedRuler: CGPath?
    var finished: TimeInterval?
    private var activePath = CGMutablePath()
    private var frozenPath: CGPath?
    private var pointBounds: CGRect

    var path: CGPath { frozenPath ?? activePath }
    var bounds: CGRect { pointBounds.insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2) }

    init(point: CGPoint, color: NSColor, width: CGFloat, opacity: CGFloat, excludedRuler: CGPath?) {
        first = point
        last = point
        self.color = color
        self.width = width
        self.opacity = opacity
        self.excludedRuler = excludedRuler
        pointBounds = CGRect(origin: point, size: .zero)
        activePath.move(to: point)
    }

    /// Includes the old cap/join and new segment. Guided lines can retract, so
    /// their old extent must also be erased.
    func append(_ point: CGPoint, guided: Bool) -> CGRect {
        precondition(frozenPath == nil)
        let damage: CGRect
        if guided {
            let oldBounds = bounds
            activePath = CGMutablePath()
            activePath.move(to: first)
            activePath.addLine(to: point)
            pointBounds = Self.segmentBounds(first, point)
            damage = oldBounds.union(bounds)
            pointCount = 2
        } else {
            damage = Self.segmentBounds(last, point).insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
            activePath.addLine(to: point)
            pointBounds = pointBounds.union(CGRect(origin: point, size: .zero))
            pointCount += 1
        }
        last = point
        return damage
    }

    func finish(at time: TimeInterval) {
        frozenPath = activePath.copy()
        activePath = CGMutablePath()
        finished = time
    }

    private static func segmentBounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func draw(in context: CGContext, at time: TimeInterval, canvasBounds: CGRect, ruler: CGPath?, lifetime: InkLifetime = InkLifetime()) {
        context.saveGState()
        defer { context.restoreGState() }

        for exclusion in [excludedRuler, ruler].compactMap({ $0 }) {
            context.beginPath()
            context.addRect(canvasBounds.insetBy(dx: -1, dy: -1))
            context.addPath(exclusion)
            context.clip(using: .evenOdd)
        }

        let age = finished.map { time - $0 } ?? 0
        let alpha = opacity * lifetime.opacity(age: age)
        let ink = color.withAlphaComponent(alpha).cgColor
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if pointCount == 1 {
            context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
        } else {
            context.addPath(path)
            context.strokePath()
        }
    }
}
