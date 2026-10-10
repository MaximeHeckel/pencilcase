import AppKit
import QuartzCore

/// The transparent host expands to enclose the rotated glass instrument.
final class RulerView: NSView {
    private let instrument = NSView()
    private var instrumentCenter = CGPoint.zero
    private var hoverArea: NSTrackingArea?
    private let glass = NSGlassEffectView()
    private let markings = RulerMarkingsView()
    private(set) var geometry = RulerGeometry()
    private var gesture: Gesture?
    private var drawingAlongEdge = false
    private var rotationEnvelope = false
    private var motionTimer: Timer?
    private var motion: RulerMomentum?
    private var motionLimits = CGRect.zero
    private var motionOrigin = CGPoint.zero
    private var lastMotionTime: TimeInterval = 0
    private var motionStarted: TimeInterval = 0
    private var dragSamples: [(point: CGPoint, time: TimeInterval)] = []
    private var dragCursor: NSCursor?
    fileprivate var isInteracting = false

    private struct Gesture {
        var moving: Bool
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
        // The rotated instrument is laid out explicitly below.
        autoresizesSubviews = false
        glass.style = .clear
        // This instrument is pale acrylic even when the surrounding app is dark.
        glass.appearance = NSAppearance(named: .aqua)
        glass.cornerRadius = RulerGeometry.cornerRadius
        glass.contentView = markings
        markings.owner = self
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("Drag the body to move, drag ends to resize, Option-drag to rotate.")
        wantsLayer = true
        layer?.masksToBounds = false
        instrument.wantsLayer = true
        instrument.autoresizesSubviews = false
        addSubview(instrument)
        instrument.addSubview(glass)
        layoutInstrument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func instrumentToHost(_ point: CGPoint) -> CGPoint {
        let x = point.x - geometry.width / 2
        let y = point.y - RulerGeometry.height / 2
        let c = cos(geometry.radians), s = sin(geometry.radians)
        return CGPoint(x: instrumentCenter.x + c * x - s * y,
                       y: instrumentCenter.y + s * x + c * y)
    }

    private func hostToInstrument(_ point: CGPoint) -> CGPoint {
        let x = point.x - instrumentCenter.x, y = point.y - instrumentCenter.y
        let c = cos(geometry.radians), s = sin(geometry.radians)
        return CGPoint(x: geometry.width / 2 + c * x + s * y,
                       y: RulerGeometry.height / 2 - s * x + c * y)
    }

    fileprivate func instrumentPoint(from windowPoint: CGPoint) -> CGPoint {
        hostToInstrument(convert(windowPoint, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = hostToInstrument(convert(point, from: superview))
        return glass.bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { begin(event, location: instrumentPoint(from: event.locationInWindow)) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func mouseUp(with event: NSEvent) { end(allowMomentum: true) }
    override func mouseMoved(with event: NSEvent) { markings.updateMeasurementHover(event) }
    override func mouseEntered(with event: NSEvent) { markings.updateMeasurementHover(event) }
    override func mouseExited(with event: NSEvent) { markings.clearMeasurementHover() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    var markingExclusionPath: CGPath? {
        guard let window else { return nil }
        func screen(_ p: CGPoint) -> CGPoint {
            window.convertPoint(toScreen: convert(instrumentToHost(p), to: nil))
        }
        let origin = screen(.zero), x = screen(CGPoint(x: 1, y: 0)), y = screen(CGPoint(x: 0, y: 1))
        var transform = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                         c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
        return CGPath(roundedRect: glass.bounds, cornerWidth: RulerGeometry.cornerRadius,
                      cornerHeight: RulerGeometry.cornerRadius, transform: nil).copy(using: &transform)
    }

    var markingGuides: [MarkerGuide] {
        guard let window else { return [] }
        func screen(_ p: CGPoint) -> CGPoint {
            window.convertPoint(toScreen: convert(instrumentToHost(p), to: nil))
        }
        return [CGFloat(0), RulerGeometry.height].map { y in
            MarkerGuide(start: screen(CGPoint(x: RulerGeometry.inset, y: y)),
                        end: screen(CGPoint(x: RulerGeometry.inset + geometry.length, y: y)))
        }
    }

    func resetGeometry() {
        cancelInteraction()
        geometry = RulerGeometry()
        applyGeometry(center: screenCenter)
    }

    private var screenCenter: CGPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: convert(instrumentCenter, to: nil))
    }

    private func layoutInstrument(center: CGPoint? = nil) {
        instrumentCenter = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let size = CGSize(width: geometry.width, height: RulerGeometry.height)
        layer?.sublayerTransform = CATransform3DIdentity
        instrument.frame = CGRect(x: instrumentCenter.x - size.width / 2,
                                  y: instrumentCenter.y - size.height / 2, width: size.width, height: size.height)
        instrument.bounds = CGRect(origin: .zero, size: size)
        glass.frame = instrument.bounds
        glass.bounds = instrument.bounds
        markings.frame = glass.bounds
        markings.bounds = glass.bounds
        markings.geometry = geometry
        setAccessibilityLabel("Ruler, \(Int(geometry.length)) points, \(geometry.angleText) degrees")
        // Rotate only the compositor layer. AppKit's layout tree stays axis aligned,
        // avoiding its singular frame conversion at 45-degree diagonal angles.
        // Finish AppKit geometry synchronization before applying our compositor transform.
        layoutSubtreeIfNeeded()
        layer?.sublayerTransform = CATransform3DMakeAffineTransform(rotationTransform)
        markings.needsDisplay = true
        MarkerController.shared.rulerDidChange()
    }

    func moveWindow(to origin: CGPoint) {
        guard let window, origin.x.isFinite, origin.y.isFinite else { return }
        window.setFrameOrigin(origin)
        MarkerController.shared.rulerDidChange()
    }

    private func applyGeometry(center: CGPoint) {
        // Commit the window resize and glass transform together, without implicit
        // material animations between the temporary unrotated and final frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let span = ceil(hypot(geometry.width, RulerGeometry.height)) + 4
        let size = rotationEnvelope ? CGSize(width: span, height: span) : geometry.enclosingSize
        window?.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                width: size.width, height: size.height), display: false, animate: false)

        // AppKit may align the window frame to pixels. Compensate inside it so
        // the rotation pivot / opposite resize endpoint does not wobble.
        let localCenter = window.map { convert($0.convertPoint(fromScreen: center), from: nil) }
        layoutInstrument(center: localCenter)
        needsDisplay = true
    }

    fileprivate func begin(_ event: NSEvent, location: CGPoint) {
        let marker = MarkerController.shared
        let inScale = location.x >= RulerGeometry.inset && location.x <= RulerGeometry.inset + geometry.length
        let inDrawingBand = location.y >= 34 || location.y <= 8
        if marker.isDrawing && inScale && inDrawingBand && !event.modifierFlags.contains(.option) {
            stopMotion()
            markings.clearMeasurementHover()
            let edge = location.y >= 34 ? markingGuides.last : markingGuides.first
            if let edge {
                drawingAlongEdge = true
                isInteracting = true
                NSCursor.crosshair.push()
                marker.beginStroke(at: edge.project(NSEvent.mouseLocation))
                return
            }
        }
        // Ruler gestures consume this drag without changing the selected drawing mode.
        stopMotion()
        isInteracting = true
        dragSamples.removeAll()
        markings.clearMeasurementHover()
        let rotating = event.modifierFlags.contains(.option)
        markings.isRotating = rotating
        let end: CGFloat? = location.x < 18 ? -1 : (location.x > geometry.width - 18 ? 1 : nil)
        markings.isResizing = !rotating && end != nil
        let mouse = NSEvent.mouseLocation
        let center = screenCenter
        gesture = Gesture(moving: !rotating && end == nil, startMouse: mouse, center: center, initial: geometry,
                          resizeEnd: rotating ? nil : end,
                          lastPointerAngle: atan2(mouse.y - center.y, mouse.x - center.x))
        if rotating {
            rotationEnvelope = true
            applyGeometry(center: center)
        }
        if gesture?.moving == true { dragSamples = [(mouse, event.timestamp)] }
        let cursor: NSCursor = rotating ? RulerCursors.rotate : (end == nil ? .closedHand : RulerCursors.resize(angle: geometry.angle))
        dragCursor = cursor
        window?.disableCursorRects()
        cursor.push()
    }

    fileprivate func update(_ event: NSEvent) {
        if drawingAlongEdge {
            NSCursor.crosshair.set()
            MarkerController.shared.continueStroke(at: NSEvent.mouseLocation)
            return
        }
        guard var gesture else { return }
        dragCursor?.set()
        let mouse = NSEvent.mouseLocation
        if gesture.moving {
            let center = CGPoint(x: gesture.center.x + mouse.x - gesture.startMouse.x,
                                 y: gesture.center.y + mouse.y - gesture.startMouse.y)
            if let window {
                moveWindow(to: CGPoint(x: center.x - window.frame.width / 2,
                                              y: center.y - window.frame.height / 2))
            }
            MarkerController.shared.rulerDidChange()
            dragSamples.append((mouse, event.timestamp))
            dragSamples.removeAll { event.timestamp - $0.time > 0.09 }
        } else if let end = gesture.resizeEnd {
            let change = gesture.initial.resized(
                delta: CGPoint(x: mouse.x - gesture.startMouse.x, y: mouse.y - gesture.startMouse.y), end: end)
            guard change.geometry.length != geometry.length else { return }
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
            let angle = RulerGeometry.signedAngle(resolved)
            guard angle != geometry.angle else { return }
            geometry.angle = angle
            updateRotationLayers()
        }
        dragCursor?.set()
    }

    private var rotationTransform: CGAffineTransform {
        let c = cos(geometry.radians), s = sin(geometry.radians)
        let x = instrumentCenter.x, y = instrumentCenter.y
        // Transform the host sublayers, leaving AppKit-owned view transforms alone.
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: x - c * x + s * y, ty: y - s * x - c * y)
    }

    private func updateRotationLayers() {
        // The gesture window already encloses every rotation angle.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeAffineTransform(rotationTransform)
        markings.geometry = geometry
        markings.needsDisplay = true
        MarkerController.shared.rulerDidChange()
        CATransaction.commit()
    }

    fileprivate func end(allowMomentum: Bool = false) {
        if drawingAlongEdge {
            drawingAlongEdge = false
            isInteracting = false
            MarkerController.shared.finishStroke()
            NSCursor.pop()
            return
        }
        if rotationEnvelope {
            rotationEnvelope = false
            applyGeometry(center: screenCenter)
        }
        let wasMoving = gesture?.moving == true
        isInteracting = false
        markings.isRotating = false
        markings.isResizing = false
        guard gesture != nil else { return }
        gesture = nil
        dragCursor = nil
        NSCursor.pop()
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: markings)
        NSCursor.arrow.set()
        if allowMomentum && wasMoving { startMotion() }
        dragSamples.removeAll()
    }

    private var momentumEnabled: Bool {
        (UserDefaults.standard.object(forKey: "rulerMomentumEnabled") as? Bool ?? true)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startMotion() {
        guard momentumEnabled, let window,
              let velocity = RulerMomentum.releaseVelocity(samples: dragSamples,
                  now: ProcessInfo.processInfo.systemUptime) else { return }

        // Keep the throw on the display containing most of the ruler at release.
        guard let screen = NSScreen.screens.max(by: {
            let a = $0.visibleFrame.intersection(window.frame)
            let b = $1.visibleFrame.intersection(window.frame)
            return a.width * a.height < b.width * b.height
        }) else { return }
        motionLimits = screen.visibleFrame
        motionOrigin = window.frame.origin
        motion = RulerMomentum(velocity: velocity, surface: .ruler)
        isInteracting = true
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        motionStarted = lastMotionTime

        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceMotion() }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceMotion() {
        guard gesture == nil, momentumEnabled, let window, window.isVisible, var motion else {
            stopMotion()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastMotionTime
        guard dt < 0.1, now - motionStarted < 4 else {
            stopMotion()
            return
        }
        lastMotionTime = now
        // Never feed AppKit's pixel-aligned frame back into the integrator:
        // fractional movement must accumulate equally on both axes.
        motionOrigin = motion.step(origin: motionOrigin, size: window.frame.size,
                                   limits: motionLimits, dt: dt)
        moveWindow(to: motionOrigin)
        MarkerController.shared.rulerDidChange()
        self.motion = motion
        if motion.isStopped { stopMotion() }
    }

    private func stopMotion() {
        motionTimer?.invalidate()
        motionTimer = nil
        motion = nil
        isInteracting = false
    }

    func cancelInteraction() {
        stopMotion()
        end()
        markings.clearMeasurementHover()
    }
}

private final class RulerMarkingsView: NSView {
    private let interactionBlue = NSColor.systemBlue
    var isResizing = false {
        didSet { if oldValue != isResizing { needsDisplay = true } }
    }

    weak var owner: RulerView?
    var geometry = RulerGeometry() {
        didSet {
            clearMeasurementHover()
            setAccessibilityLabel("Ruler, \(Int(geometry.length)) points, \(geometry.angleText) degrees")
        }
    }

    private var hoveredPoint: CGFloat?
    var isRotating = false {
        didSet { if oldValue != isRotating { needsDisplay = true } }
    }

    fileprivate func updateMeasurementHover(_ event: NSEvent) {
        guard owner?.isInteracting == false, NSEvent.pressedMouseButtons == 0,
              window?.isVisible == true else {
            clearMeasurementHover()
            return
        }
        let local = owner?.instrumentPoint(from: event.locationInWindow) ?? .zero
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

    override var wantsUpdateLayer: Bool { true }

    private var artworkSize = CGSize.zero
    private var artworkScale: CGFloat = 0
    private var artworkAngle: CGFloat?
    private let readoutLayer = CALayer()
    private let hoverLayer = CAShapeLayer()
    private var readoutBitmap: NSBitmapImageRep?

    private func bitmap(size: CGSize, scale: CGFloat) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }

    private func paint(_ bitmap: NSBitmapImageRep, scale: CGFloat, origin: CGPoint = .zero, drawing: () -> Void) {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: -origin.x, y: -origin.y)
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Retain the full-resolution face during rotation. Refresh directional
        // highlights on release, and rebuild immediately for a new length/scale.
        if artworkSize != bounds.size || artworkScale != scale || artworkAngle == nil
            || (!isRotating && artworkAngle != geometry.angle) {
            guard let image = bitmap(size: bounds.size, scale: scale) else { return }
            paint(image, scale: scale) { drawStaticArtwork() }
            layer?.contentsScale = scale
            layer?.contents = image.cgImage
            artworkSize = bounds.size
            artworkScale = scale
            artworkAngle = geometry.angle
        }

        let readoutRect = CGRect(x: bounds.midX - 85, y: 6, width: 170, height: 26)
        if readoutBitmap == nil || readoutBitmap?.pixelsWide != Int(ceil(readoutRect.width * scale)) {
            readoutBitmap = bitmap(size: readoutRect.size, scale: scale)
        }
        if let image = readoutBitmap {
            paint(image, scale: scale, origin: readoutRect.origin) { drawReadout() }
            readoutLayer.frame = readoutRect
            readoutLayer.contentsScale = scale
            readoutLayer.contents = image.cgImage
        }
        if let hoveredPoint {
            let path = CGMutablePath()
            let x = RulerGeometry.inset + hoveredPoint
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
            hoverLayer.path = path
        } else { hoverLayer.path = nil }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(readoutLayer)
        layer?.addSublayer(hoverLayer)
        hoverLayer.strokeColor = interactionBlue.cgColor
        hoverLayer.lineWidth = 1

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("Drag to move · Drag either end to resize · Option-drag to rotate · Snaps near 45° increments · Shift forces snapping")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
                      NSColor.white.withAlphaComponent(0.55).cgColor] as CFArray
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
                  .white.withAlphaComponent(0.07), .white.withAlphaComponent(0)],
                 locations: [0, 0.28, 0.62, 1])
        context.restoreGState()

        // Adjacent filled bands approximate a continuous falloff without the
        // gaps of concentric strokes. The lit side has a wider, softer shoulder.
        let step: CGFloat = 0.25
        for index in 0..<40 {
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
            let shaded = 0.035 * exp(-depth / 1.625)
            let lit = 0.15 * exp(-depth / 3.375)
            gradient([.white.withAlphaComponent(shaded), .white.withAlphaComponent(lit)],
                     locations: [0, 1])

            // Give both long edges a steady reflection beneath the ticks.
            // Keep the side rims and corner glints at their existing intensity.
            let edgeStart = bounds.minX + RulerGeometry.cornerRadius
            let edgeEnd = bounds.maxX - RulerGeometry.cornerRadius
            context.clip(to: CGRect(x: edgeStart, y: bounds.minY,
                                    width: edgeEnd - edgeStart, height: bounds.height))
            let base = NSColor.white.withAlphaComponent(0.10 * exp(-depth / 3.375))
            let colors = [base.withAlphaComponent(0).cgColor, base.cgColor,
                          base.cgColor, base.withAlphaComponent(0).cgColor] as CFArray
            let fade = min(0.1, 10 / (edgeEnd - edgeStart))
            if let reflection = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors, locations: [0, fade, 1 - fade, 1]) {
                context.drawLinearGradient(reflection,
                    start: CGPoint(x: edgeStart, y: bounds.midY),
                    end: CGPoint(x: edgeEnd, y: bounds.midY), options: [])
            }
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
                context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1.6, dy: 1.6),
                                      cornerWidth: RulerGeometry.cornerRadius - 1.6, cornerHeight: RulerGeometry.cornerRadius - 1.6, transform: nil))
                context.setLineWidth(2.4)
                context.replacePathWithStrokedPath()
                context.clip()

                let colors = [NSColor.white.withAlphaComponent(0.28 * strength).cgColor,
                              tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray
                if let glint = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: colors, locations: [0, 0.4, 1]) {
                    context.drawRadialGradient(glint, startCenter: corner, startRadius: 0,
                                               endCenter: corner, endRadius: 30, options: [])
                }
                context.restoreGState()
            }
        }
    }

    private func drawStaticArtwork() {
        // A luminous white body supports charcoal ink over varied desktop content.
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: RulerGeometry.cornerRadius,
                     yRadius: RulerGeometry.cornerRadius).fill()

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
                    .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: x - size.width / 2, y: 39), withAttributes: attributes)
            }
        }
        NSColor(calibratedWhite: 0.16, alpha: 0.8).setStroke()
        ticks.lineWidth = 1.0
        ticks.stroke()

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
        drawEtch(width: 0.8, color: NSColor(calibratedWhite: 0.16, alpha: 0.5), offset: .zero)
    }

    private func drawReadout() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1)
        ]
        // Reserve both pill slots permanently, including the maximum length and
        // signed angle. Activation changes paint only, never text or group layout.
        let padding: CGFloat = 4
        let valueGap: CGFloat = 14
        let points = "\(Int(hoveredPoint ?? geometry.length)) pt" as NSString
        let angle = (geometry.angleText + "°") as NSString
        let pointWidth = ("2000 pt" as NSString).size(withAttributes: attributes).width + padding * 2
        let angleWidth = ["+180.00°", "−180.00°"].map {
            ($0 as NSString).size(withAttributes: attributes).width
        }.max()! + padding * 2
        let slotWidth = max(pointWidth, angleWidth)
        let origin = (bounds.width - slotWidth * 2 - valueGap) / 2
        let pillY: CGFloat = 8
        let pillHeight: CGFloat = 21
        let textY = pillY + (pillHeight - ("0000 pt" as NSString).size(withAttributes: attributes).height) / 2

        func drawValue(_ text: NSString, x: CGFloat, width: CGFloat, active: Bool) {
            let pill = NSRect(x: x, y: pillY, width: width, height: pillHeight)
            var ink = attributes
            let fill = active ? interactionBlue : NSColor(calibratedWhite: 0.78, alpha: 0.40)
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2,
                         yRadius: pill.height / 2).fill()
            if active { ink[.foregroundColor] = NSColor.white }
            let textWidth = text.size(withAttributes: attributes).width
            text.draw(at: NSPoint(x: pill.midX - textWidth / 2, y: textY), withAttributes: ink)
        }

        drawValue(points, x: origin, width: slotWidth, active: hoveredPoint != nil || isResizing)
        let separator = "·" as NSString
        let separatorWidth = separator.size(withAttributes: attributes).width
        separator.draw(at: NSPoint(x: origin + slotWidth + (valueGap - separatorWidth) / 2,
                                   y: textY), withAttributes: attributes)
        drawValue(angle, x: origin + slotWidth + valueGap, width: slotWidth, active: isRotating)

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
