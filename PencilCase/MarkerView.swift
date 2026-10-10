import AppKit

/// A small physical instrument. Only its tip switches modes; the barrel moves it.
final class MarkerView: NSView {
    private var startMouse: CGPoint?
    private var startOrigin = CGPoint.zero
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    private var timer: Timer?
    private var motion: RulerMomentum?
    private var motionOrigin = CGPoint.zero
    private var limits = CGRect.zero
    private var lastTime: TimeInterval = 0
    private var started: TimeInterval = 0
    private var tipPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityLabel("Marker")
        setAccessibilityHelp("Click the tip to draw. Right-click for colors. Escape exits drawing. Drag the barrel to move or throw.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: 14, y: 8, width: 38, height: 145), cursor: .openHand)
        addCursorRect(CGRect(x: 14, y: 153, width: 38, height: 49), cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = MarkerController.shared.isDrawing
        let color = MarkerController.shared.inkColor
        let barrel = NSBezierPath(roundedRect: CGRect(x: 17, y: 12, width: 32, height: 146), xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = CGSize(width: 1, height: -2)
        shadow.set()
        NSColor.white.setFill()
        barrel.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [NSColor(white: 0.78, alpha: 1), .white, NSColor(white: 0.94, alpha: 1), NSColor(white: 0.73, alpha: 1)])?.draw(in: barrel, angle: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        barrel.lineWidth = 0.6
        barrel.stroke()

        let nib = NSBezierPath()
        nib.move(to: CGPoint(x: 20, y: 156))
        nib.line(to: CGPoint(x: 29, y: 192))
        nib.curve(to: CGPoint(x: 37, y: 192), controlPoint1: CGPoint(x: 30, y: 198), controlPoint2: CGPoint(x: 36, y: 198))
        nib.line(to: CGPoint(x: 46, y: 156))
        nib.close()
        NSGradient(colors: [color, color.blended(withFraction: 0.32, of: .white) ?? color, color])?.draw(in: nib, angle: 0)

        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 17, y: 151, width: 32, height: 9), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(rect: CGRect(x: 17, y: 119, width: 32, height: 7)).fill()

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
        tipPressed = convert(event.locationInWindow, from: nil).y >= 151
        if tipPressed { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        samples = [(NSEvent.mouseLocation, event.timestamp)]
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse else { return }
        let point = NSEvent.mouseLocation
        window?.setFrameOrigin(CGPoint(x: startOrigin.x + point.x - startMouse.x, y: startOrigin.y + point.y - startMouse.y))
        samples.append((point, event.timestamp))
        samples.removeAll { event.timestamp - $0.time > 0.09 }
    }

    override func mouseUp(with event: NSEvent) {
        if tipPressed {
            tipPressed = false
            if convert(event.locationInWindow, from: nil).y >= 151 {
                MarkerController.shared.setDrawing(!MarkerController.shared.isDrawing)
            }
            return
        }
        guard startMouse != nil else { return }
        startMouse = nil
        NSCursor.pop()
        startThrow()
        samples.removeAll()
    }

    func cancelInteraction() {
        stopMotion()
        if startMouse != nil { NSCursor.pop() }
        startMouse = nil
        tipPressed = false
        samples.removeAll()
    }

    override func accessibilityPerformPress() -> Bool {
        MarkerController.shared.setDrawing(!MarkerController.shared.isDrawing)
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
        motionOrigin = window.frame.origin
        motion = RulerMomentum(velocity: velocity, surface: .marker)
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
        motionOrigin = motion.step(origin: motionOrigin, size: window.frame.size, limits: limits, dt: dt)
        window.setFrameOrigin(motionOrigin)
        self.motion = motion
        if motion.isStopped { stopMotion() }
    }
}
