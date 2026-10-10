import AppKit
import QuartzCore

/// Shadow only: no fill, stroke, or darkening inside the translucent instrument.
@MainActor
final class InstrumentShadow: CALayer {
    private let cutout = CAShapeLayer()

    override init() {
        super.init()
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.13
        shadowRadius = 9
        shadowOffset = CGSize(width: 0, height: -4)
        cutout.fillRule = .evenOdd
        mask = cutout
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(bounds: CGRect, silhouette: CGPath, caster: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = bounds.insetBy(dx: -24, dy: -24)
        var translation = CGAffineTransform(translationX: 24, y: 24)
        shadowPath = caster.copy(using: &translation)
        cutout.frame = self.bounds
        let outside = CGMutablePath()
        outside.addRect(self.bounds)
        outside.addPath(silhouette, transform: translation)
        cutout.path = outside
        CATransaction.commit()
    }

    static func draw(_ silhouettes: [NSBezierPath], in bounds: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let caster = NSBezierPath()
        for silhouette in silhouettes {
            let outside = NSBezierPath(rect: bounds.insetBy(dx: -24, dy: -24))
            outside.append(silhouette)
            outside.windingRule = .evenOdd
            outside.addClip()
            caster.append(silhouette)
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.13)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()
        NSColor.black.setFill()
        caster.fill()
    }
}
