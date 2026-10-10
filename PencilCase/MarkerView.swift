import AppKit

/// A small physical instrument. Only its tip switches modes; the barrel moves it.
final class MarkerView: NSView {
    let toolID: Int
    private var angle: CGFloat
    private var rotating = false
    private var initialAngle: CGFloat = 0
    private var lastPointerAngle: CGFloat = 0
    private var rotationDelta: CGFloat = 0
    private var rotationCenter = CGPoint.zero
    private var snap = RulerAngleSnap()
    private var startMouse: CGPoint?
    private var startOrigin = CGPoint.zero
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    private var timer: Timer?
    private var motion: InstrumentMomentum?
    private var throwGrabOffset = CGPoint.zero
    private var limits = CGRect.zero
    private var lastTime: TimeInterval = 0
    private var started: TimeInterval = 0
    private var tipPressed = false

    init(frame frameRect: NSRect, toolID: Int) {
        self.toolID = toolID
        angle = MarkerGeometry.spawnAngles[toolID]
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityLabel("Drawing tool \(toolID + 1)")
        setAccessibilityHelp("Click the tip to draw. Right-click for colors. Escape exits drawing. Drag the barrel to move or throw. Option-drag to rotate; Shift to snap.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func toolPoint(_ event: NSEvent) -> CGPoint {
        MarkerGeometry.localPoint(convert(event.locationInWindow, from: nil), size: bounds.size, angle: angle)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let controller = MarkerController.shared
        let tool = controller.tools[toolID]
        let active = controller.isDrawing && controller.selectedToolID == toolID
        let color = tool.color
        let broad = tool.width >= 10
        let thin = tool.width <= 3
        let bodyWidth: CGFloat = thin ? 20 : broad ? 42 : 32
        let left = 33 - bodyWidth / 2

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -33, yBy: -105)
        transform.concat()
        let barrel = NSBezierPath(roundedRect: CGRect(x: left, y: 12, width: bodyWidth, height: 146), xRadius: 9, yRadius: 9)
        let nib = NSBezierPath()
        if broad {
            nib.move(to: CGPoint(x: left + 4, y: 156))
            nib.line(to: CGPoint(x: left + 7, y: 185))
            nib.line(to: CGPoint(x: left + bodyWidth - 7, y: 194))
            nib.line(to: CGPoint(x: left + bodyWidth - 4, y: 156))
        } else {
            nib.move(to: CGPoint(x: left + 3, y: 156))
            nib.line(to: CGPoint(x: thin ? 32 : 29, y: 192))
            nib.line(to: CGPoint(x: thin ? 34 : 37, y: 192))
            nib.line(to: CGPoint(x: left + bodyWidth - 3, y: 156))
        }
        nib.close()
        InstrumentShadow.draw([barrel, nib], in: CGRect(x: -24, y: -24, width: 114, height: 258))

        NSGradient(colors: [NSColor(white: 0.78, alpha: 1), .white, NSColor(white: 0.94, alpha: 1), NSColor(white: 0.73, alpha: 1)])?.draw(in: barrel, angle: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        barrel.lineWidth = 0.6
        barrel.stroke()

        NSGradient(colors: [color, color.blended(withFraction: 0.32, of: .white) ?? color, color])?.draw(in: nib, angle: 0)

        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: left, y: 151, width: bodyWidth, height: 9), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(rect: CGRect(x: left, y: 119, width: bodyWidth, height: 7)).fill()

        let grip = NSBezierPath()
        for y in stride(from: 42, through: 90, by: 4) {
            grip.move(to: CGPoint(x: 25, y: y))
            grip.line(to: CGPoint(x: 41, y: y))
        }
        NSColor.black.withAlphaComponent(0.06).setStroke()
        grip.lineWidth = 0.5
        grip.stroke()

        (active ? color : NSColor(white: 0.6, alpha: 1)).setFill()
        NSBezierPath(ovalIn: CGRect(x: 30, y: 27, width: 6, height: 6)).fill()
        if active {
            let ring = NSBezierPath(ovalIn: CGRect(x: 26, y: 23, width: 14, height: 14))
            color.withAlphaComponent(0.35).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MarkerController.shared.showColorPalette(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            MarkerController.shared.showColorPalette(from: self)
            return
        }
        stopMotion()
        rotating = event.modifierFlags.contains(.option)
        tipPressed = !rotating && toolPoint(event).y >= 151
        if tipPressed { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        rotationCenter = CGPoint(x: startOrigin.x + bounds.midX, y: startOrigin.y + bounds.midY)
        throwGrabOffset = CGPoint(x: NSEvent.mouseLocation.x - rotationCenter.x, y: NSEvent.mouseLocation.y - rotationCenter.y)
        initialAngle = angle
        rotationDelta = 0
        snap = RulerAngleSnap()
        lastPointerAngle = atan2(NSEvent.mouseLocation.y - rotationCenter.y, NSEvent.mouseLocation.x - rotationCenter.x)
        samples = [(NSEvent.mouseLocation, event.timestamp)]
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse else { return }
        let point = NSEvent.mouseLocation
        if rotating {
            let dx = point.x - rotationCenter.x
            let dy = point.y - rotationCenter.y
            guard hypot(dx, dy) >= 12 else { return }
            let pointer = atan2(dy, dx)
            let delta = pointer - lastPointerAngle
            rotationDelta += atan2(sin(delta), cos(delta)) * 180 / .pi
            lastPointerAngle = pointer
            let previousTarget = snap.target
            angle = RulerGeometry.signedAngle(snap.resolve(initialAngle + rotationDelta, force: event.modifierFlags.contains(.shift)))
            if let target = snap.target, target != previousTarget {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            }
            let size = MarkerGeometry.size(angle: angle)
            window?.setFrame(CGRect(x: rotationCenter.x - size.width / 2, y: rotationCenter.y - size.height / 2,
                                   width: size.width, height: size.height), display: false)
            needsDisplay = true
            return
        }
        window?.setFrameOrigin(CGPoint(x: startOrigin.x + point.x - startMouse.x, y: startOrigin.y + point.y - startMouse.y))
        samples.append((point, event.timestamp))
        samples.removeAll { event.timestamp - $0.time > 0.09 }
    }

    override func mouseUp(with event: NSEvent) {
        if tipPressed {
            tipPressed = false
            if toolPoint(event).y >= 151 {
                MarkerController.shared.activateTip(toolID)
            }
            return
        }
        guard startMouse != nil else { return }
        startMouse = nil
        NSCursor.pop()
        if !rotating { startThrow() }
        rotating = false
        samples.removeAll()
    }

    func cancelInteraction() {
        stopMotion()
        if startMouse != nil { NSCursor.pop() }
        startMouse = nil
        tipPressed = false
        rotating = false
        samples.removeAll()
    }

    override func accessibilityPerformPress() -> Bool {
        MarkerController.shared.activateTip(toolID)
        return true
    }

    func stopMotion() {
        timer?.invalidate()
        timer = nil
        motion = nil
    }

    private func startThrow() {
        guard UserDefaults.standard.object(forKey: "rulerMomentumEnabled") as? Bool ?? true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window,
              let velocity = RulerMomentum.releaseVelocity(samples: samples,
                  now: ProcessInfo.processInfo.systemUptime) else { return }

        let screen = NSScreen.screens.max {
            let a = $0.visibleFrame.intersection(window.frame)
            let b = $1.visibleFrame.intersection(window.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        guard let screen else { return }
        limits = screen.visibleFrame
        let bodyWidth: CGFloat = toolID == 0 ? 20 : toolID == 1 ? 32 : 42
        motion = InstrumentMomentum(center: CGPoint(x: window.frame.midX, y: window.frame.midY),
                                    angle: angle * .pi / 180, velocity: velocity, grabOffset: throwGrabOffset,
                                    size: CGSize(width: bodyWidth, height: 186), surface: .marker)
        started = ProcessInfo.processInfo.systemUptime
        lastTime = started
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advance() {
        guard var motion, let window, window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              UserDefaults.standard.object(forKey: "rulerMomentumEnabled") as? Bool ?? true else { stopMotion(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTime
        guard dt < 0.1, now - started < 4 else { stopMotion(); return }
        lastTime = now
        motion.step(limits: limits, dt: dt)
        angle = RulerGeometry.signedAngle(motion.angle * 180 / .pi)
        let size = MarkerGeometry.size(angle: angle)
        window.setFrame(CGRect(x: motion.center.x - size.width / 2, y: motion.center.y - size.height / 2,
                               width: size.width, height: size.height), display: false)
        needsDisplay = true
        self.motion = motion
        if motion.isStopped { stopMotion() }
    }
}
