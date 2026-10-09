import AppKit

/// The transparent host expands to enclose the rotated glass instrument.
final class RulerView: NSView {
    private let glass = NSGlassEffectView()
    private let markings = RulerMarkingsView()
    private(set) var geometry = RulerGeometry()
    private var gesture: Gesture?
    private var dragCursor: NSCursor?
    fileprivate var isInteracting = false

    private struct Gesture {
        var startMouse: CGPoint
        var center: CGPoint
        var initial: RulerGeometry
        var resizeEnd: CGFloat? // -1 = left; +1 = right; nil = rotation
        var lastPointerAngle: CGFloat
        var rotationDelta: CGFloat = 0
        var snap = RulerAngleSnap()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.style = .clear
        glass.cornerRadius = RulerGeometry.cornerRadius
        glass.contentView = markings
        markings.owner = self
        addSubview(glass)
        layoutInstrument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the actual instrument participates in AppKit hit testing.
        let local = markings.convert(point, from: superview)
        return markings.bounds.contains(local) ? markings : nil
    }

    func resetGeometry() {
        geometry = RulerGeometry()
        applyGeometry(center: screenCenter)
    }

    private var screenCenter: CGPoint {
        guard let window else { return .zero }
        return CGPoint(x: window.frame.midX, y: window.frame.midY)
    }

    private func layoutInstrument() {
        // Reset the transform before changing size; ticks must never stretch.
        glass.frameCenterRotation = 0
        glass.frame = NSRect(x: (bounds.width - geometry.width) / 2,
                             y: (bounds.height - RulerGeometry.height) / 2,
                             width: geometry.width, height: RulerGeometry.height)
        glass.bounds = NSRect(origin: .zero, size: NSSize(width: geometry.width, height: RulerGeometry.height))
        markings.frame = glass.bounds
        markings.bounds = glass.bounds
        markings.geometry = geometry
        glass.frameCenterRotation = geometry.angle
        markings.needsDisplay = true
        window?.invalidateCursorRects(for: markings)
    }

    private func applyGeometry(center: CGPoint) {
        let size = geometry.enclosingSize
        window?.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                width: size.width, height: size.height), display: false)
        layoutInstrument()
        window?.invalidateShadow()
        needsDisplay = true
    }

    fileprivate func begin(_ event: NSEvent, location: CGPoint) {
        isInteracting = true
        markings.clearMeasurementHover()
        let rotating = event.modifierFlags.contains(.option)
        markings.isRotating = rotating
        let end: CGFloat? = location.x < 18 ? -1 : (location.x > geometry.width - 18 ? 1 : nil)
        guard rotating || end != nil else {
            window?.performDrag(with: event)
            isInteracting = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let center = screenCenter
        gesture = Gesture(startMouse: mouse, center: center, initial: geometry,
                          resizeEnd: rotating ? nil : end,
                          lastPointerAngle: atan2(mouse.y - center.y, mouse.x - center.x))
        let cursor = rotating ? RulerCursors.rotate : RulerCursors.resize(angle: geometry.angle)
        dragCursor = cursor
        window?.disableCursorRects()
        cursor.push()
    }

    fileprivate func update(_ event: NSEvent) {
        guard var gesture else { return }
        dragCursor?.set()
        let mouse = NSEvent.mouseLocation
        if let end = gesture.resizeEnd {
            let change = gesture.initial.resized(
                delta: CGPoint(x: mouse.x - gesture.startMouse.x, y: mouse.y - gesture.startMouse.y), end: end)
            geometry = change.geometry
            applyGeometry(center: CGPoint(x: gesture.center.x + change.centerOffset.x,
                                          y: gesture.center.y + change.centerOffset.y))
        } else {
            let dx = mouse.x - gesture.center.x
            let dy = mouse.y - gesture.center.y
            // Avoid unstable angular jumps when the pointer crosses the pivot.
            guard hypot(dx, dy) >= 12 else { return }
            let pointerAngle = atan2(dy, dx)
            let delta = pointerAngle - gesture.lastPointerAngle
            gesture.rotationDelta += atan2(sin(delta), cos(delta)) * 180 / .pi
            gesture.lastPointerAngle = pointerAngle
            let previousTarget = gesture.snap.target
            let resolved = gesture.snap.resolve(
                gesture.initial.angle + gesture.rotationDelta,
                force: event.modifierFlags.contains(.shift))
            if let target = gesture.snap.target, target != previousTarget {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            self.gesture = gesture
            geometry.angle = RulerGeometry.signedAngle(resolved)
            applyGeometry(center: gesture.center)
        }
        dragCursor?.set()
    }

    fileprivate func end() {
        isInteracting = false
        markings.isRotating = false
        guard gesture != nil else { return }
        gesture = nil
        dragCursor = nil
        NSCursor.pop()
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: markings)
        NSCursor.arrow.set()
    }

    func cancelInteraction() {
        end()
        markings.clearMeasurementHover()
    }
}

private final class RulerMarkingsView: NSView {
    weak var owner: RulerView?
    var geometry = RulerGeometry() {
        didSet {
            clearMeasurementHover()
            setAccessibilityLabel("Ruler, \(Int(geometry.length)) points, \(geometry.angleText) degrees")
        }
    }

    private var hoverArea: NSTrackingArea?
    private var hoveredPoint: CGFloat?
    var isRotating = false {
        didSet { if oldValue != isRotating { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // Track drawing feedback even when another app is active. This does not
        // change the system cursor or activate the ruler's panel.
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateMeasurementHover(event) }
    override func mouseMoved(with event: NSEvent) { updateMeasurementHover(event) }
    override func mouseExited(with event: NSEvent) { clearMeasurementHover() }

    private func updateMeasurementHover(_ event: NSEvent) {
        guard owner?.isInteracting == false, NSEvent.pressedMouseButtons == 0,
              window?.isVisible == true else {
            clearMeasurementHover()
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let value = geometry.hoveredPoint(at: local)
        guard value != hoveredPoint else { return }
        hoveredPoint = value
        needsDisplay = true
    }

    func clearMeasurementHover() {
        guard hoveredPoint != nil else { return }
        hoveredPoint = nil
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        toolTip = "Drag to move · Drag either end to resize · Option-drag to rotate · Snaps near 45° increments · Shift forces snapping"
        setAccessibilityHelp(toolTip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.begin(event, location: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { owner?.update(event) }
    override func mouseUp(with event: NSEvent) { owner?.end() }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: 18, dy: 0), cursor: .openHand)
        let resizeCursor = RulerCursors.resize(angle: geometry.angle)
        addCursorRect(NSRect(x: 0, y: 0, width: 18, height: bounds.height), cursor: resizeCursor)
        addCursorRect(NSRect(x: bounds.width - 18, y: 0, width: 18, height: bounds.height), cursor: resizeCursor)
    }

    private func drawEdgeHighlight() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // A single fine reflection, inset to stay inside the native glass.
        // Keep its light direction fixed on screen as the instrument rotates.
        let edge = bounds.insetBy(dx: 0.65, dy: 0.65)
        let radius = RulerGeometry.cornerRadius - 0.65
        let lightAngle = (125 - geometry.angle) * .pi / 180
        let direction = CGPoint(x: cos(lightAngle), y: sin(lightAngle))
        let reach = abs(direction.x) * edge.width / 2 + abs(direction.y) * edge.height / 2
        let center = CGPoint(x: edge.midX, y: edge.midY)

        context.saveGState()
        defer { context.restoreGState() }

        context.addPath(CGPath(roundedRect: edge, cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
        context.setLineWidth(0.75)
        context.replacePathWithStrokedPath()
        context.clip()

        let colors = [NSColor.white.withAlphaComponent(0.035).cgColor,
                      NSColor.white.withAlphaComponent(0.10).cgColor,
                      NSColor.white.withAlphaComponent(0.38).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 0.55, 1]) else { return }

        context.drawLinearGradient(gradient,
            start: CGPoint(x: center.x - direction.x * reach, y: center.y - direction.y * reach),
            end: CGPoint(x: center.x + direction.x * reach, y: center.y + direction.y * reach),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func drawSurfaceOptics() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let angle = (125 - geometry.angle) * .pi / 180
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let reach = abs(direction.x) * bounds.width / 2 + abs(direction.y) * bounds.height / 2
        let start = CGPoint(x: center.x - direction.x * reach, y: center.y - direction.y * reach)
        let end = CGPoint(x: center.x + direction.x * reach, y: center.y + direction.y * reach)

        func gradient(_ colors: [NSColor], locations: [CGFloat]) {
            guard let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors.map { $0.cgColor } as CFArray, locations: locations) else { return }

            context.drawLinearGradient(fill, start: start, end: end,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // A broad reflection across the face; no blur, capture, or animation loop.
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8),
                              cornerWidth: RulerGeometry.cornerRadius - 0.8, cornerHeight: RulerGeometry.cornerRadius - 0.8, transform: nil))
        context.clip()
        gradient([.white.withAlphaComponent(0), .white.withAlphaComponent(0),
                  .white.withAlphaComponent(0.055), .white.withAlphaComponent(0)],
                 locations: [0, 0.28, 0.62, 1])
        context.restoreGState()

        // Adjacent filled bands approximate a continuous falloff without the
        // gaps of concentric strokes. The lit side has a wider, softer shoulder.
        let step: CGFloat = 0.25
        for index in 0..<16 {
            let inset = 0.9 + CGFloat(index) * step
            let depth = CGFloat(index) * step
            let outer = bounds.insetBy(dx: inset, dy: inset)
            let inner = outer.insetBy(dx: step, dy: step)
            let radius = max(0, RulerGeometry.cornerRadius - inset)

            context.saveGState()
            context.addPath(CGPath(roundedRect: outer, cornerWidth: radius,
                                  cornerHeight: radius, transform: nil))
            context.addPath(CGPath(roundedRect: inner, cornerWidth: max(0, radius - step),
                                  cornerHeight: max(0, radius - step), transform: nil))
            context.clip(using: .evenOdd)
            let shaded = 0.025 * exp(-depth / 0.65)
            let lit = 0.105 * exp(-depth / 1.35)
            gradient([.white.withAlphaComponent(shaded), .white.withAlphaComponent(lit)],
                     locations: [0, 1])
            context.restoreGState()
        }

        // Small radial glints live only on the corner rims. Their intensity
        // changes continuously with rotation; there is no animated light source.
        for sx: CGFloat in [-1, 1] {
            for sy: CGFloat in [-1, 1] {
                let facing = (sx * direction.x + sy * direction.y) / sqrt(2)
                let strength = pow(max(0, facing), 4) + 0.3 * pow(max(0, -facing), 4)
                let corner = CGPoint(x: sx < 0 ? RulerGeometry.cornerRadius : bounds.width - RulerGeometry.cornerRadius,
                                     y: sy < 0 ? RulerGeometry.cornerRadius : bounds.height - RulerGeometry.cornerRadius)
                let tint = facing >= 0
                    ? NSColor(calibratedRed: 0.68, green: 0.86, blue: 1, alpha: 0.14 * strength)
                    : NSColor(calibratedRed: 1, green: 0.81, blue: 0.68, alpha: 0.14 * strength)

                context.saveGState()
                context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1.05, dy: 1.05),
                                      cornerWidth: RulerGeometry.cornerRadius - 1.05, cornerHeight: RulerGeometry.cornerRadius - 1.05, transform: nil))
                context.setLineWidth(1.3)
                context.replacePathWithStrokedPath()
                context.clip()

                let colors = [NSColor.white.withAlphaComponent(0.19 * strength).cgColor,
                              tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray
                if let glint = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: colors, locations: [0, 0.4, 1]) {
                    context.drawRadialGradient(glint, startCenter: corner, startRadius: 0,
                                               endCenter: corner, endRadius: 22, options: [])
                }
                context.restoreGState()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSurfaceOptics()
        drawEdgeHighlight()

        let ticks = NSBezierPath()
        for value in stride(from: 0, through: Int(geometry.length), by: 5) {
            let x = CGFloat(value) + RulerGeometry.inset
            let major = value % 50 == 0
            let height: CGFloat = major ? 19 : (value % 10 == 0 ? 12 : 7)
            ticks.move(to: NSPoint(x: x, y: bounds.height - 1))
            ticks.line(to: NSPoint(x: x, y: bounds.height - height))
            if major {
                let label = "\(value)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: x - size.width / 2, y: 39), withAttributes: attributes)
            }
        }
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        ticks.lineWidth = 0.75
        ticks.stroke()

        if let hoveredPoint {
            let x = RulerGeometry.inset + hoveredPoint
            let indicator = NSBezierPath()
            indicator.move(to: NSPoint(x: x, y: bounds.height))
            indicator.line(to: NSPoint(x: x, y: 0))
            indicator.lineWidth = 1
            NSColor.systemBlue.setStroke()
            indicator.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        // Preserve the original compact baseline and spacing. Only the angle
        // reserves space for the sign, three integer digits and two fractional digits.
        let prefix = "\(Int(hoveredPoint ?? geometry.length)) pt · " as NSString
        let prefixTemplate = "\(Int(geometry.length)) pt · " as NSString
        let angle = (geometry.angleText + "°") as NSString
        let prefixWidth = prefixTemplate.size(withAttributes: attributes).width
        let angleWidth = [CGFloat(-180), 180].map {
            ((RulerGeometry(angle: $0).angleText + "°") as NSString).size(withAttributes: attributes).width
        }.max() ?? 0
        let origin = (bounds.width - prefixWidth - angleWidth) / 2
        // Reserve the full-length field so shorter hover values do not move
        // the units, separator, or angle readout.
        let prefixOffset = prefixWidth - prefix.size(withAttributes: attributes).width
        let styledPrefix = NSMutableAttributedString(string: prefix as String, attributes: attributes)
        if hoveredPoint != nil {
            // Match the hover line; keep the separator and angle neutral.
            styledPrefix.addAttribute(.foregroundColor, value: NSColor.systemBlue,
                                      range: NSRange(location: 0, length: prefix.length - 3))
        }
        styledPrefix.draw(at: NSPoint(x: origin + prefixOffset, y: 12))
        var angleAttributes = attributes
        if isRotating { angleAttributes[.foregroundColor] = NSColor.systemBlue }
        angle.draw(at: NSPoint(x: origin + prefixWidth, y: 12), withAttributes: angleAttributes)

        // Offset light beside each groove suggests an etched handle. Keep the
        // measurement ticks and labels untouched for maximum legibility.
        let lightAngle = (125 - geometry.angle) * .pi / 180
        let offset = CGPoint(x: -cos(lightAngle) * 0.7, y: -sin(lightAngle) * 0.7)
        let handleHeight: CGFloat = 19
        let bottom = bounds.midY - handleHeight / 2 - offset.y / 2
        let top = bottom + handleHeight

        // Rounded grooves fade gently at both ends, keeping the combined etch
        // centered rather than adding a hard rectangular cap to the handles.
        func drawEtch(width: CGFloat, color: NSColor, offset: CGPoint) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            defer { context.restoreGState() }

            // The path contains only move/line segments; build its stroke mask.
            for x in [CGFloat(7), 11, bounds.width - 11, bounds.width - 7] {
                context.move(to: CGPoint(x: x + offset.x, y: bottom + offset.y))
                context.addLine(to: CGPoint(x: x + offset.x, y: top + offset.y))
            }
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.replacePathWithStrokedPath()
            context.clip()

            let colors = [color.withAlphaComponent(0).cgColor, color.cgColor,
                          color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            guard let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                         locations: [0, 0.12, 0.88, 1]) else { return }
            context.drawLinearGradient(fade, start: CGPoint(x: 0, y: bottom + offset.y),
                end: CGPoint(x: 0, y: top + offset.y), options: [])
        }

        drawEtch(width: 0.75, color: .white.withAlphaComponent(0.28), offset: offset)
        drawEtch(width: 0.8, color: NSColor(calibratedWhite: 0.35, alpha: 0.36), offset: .zero)
    }
}


private enum RulerCursors {
    /// Use the native bidirectional resize cursor nearest the ruler's axis.
    static func resize(angle: CGFloat) -> NSCursor {
        let direction = Int((RulerGeometry.normalizedAngle(angle, snapping: false) / 45).rounded()) % 4
        let positions: [NSCursor.FrameResizePosition] = [.right, .topRight, .top, .topLeft]
        return .frameResize(position: positions[direction], directions: [.inward, .outward])
    }

    // AppKit has no public rotation cursor. Use the native grabbing cursor.
    // Pencil Case must use system cursors only, never custom cursor images.
    static let rotate: NSCursor = .closedHand
}
