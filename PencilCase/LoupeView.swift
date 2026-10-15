import AppKit
import MetalKit
import QuartzCore

@MainActor
final class LoupeView: NSView {
    static let levels = LoupeScale.levels
    private let softShadow = InstrumentShadow()
    private let ringGlass = NSGlassEffectView()
    private let dialOverlay = LoupeDialOverlay()
    let renderer: LoupeRenderer
    var status: String? = nil { didSet { if oldValue != status { dialOverlay.needsDisplay = true } } }
    private var dial = 3.0
    private var draggingDial = false
    private var lastAngle: CGFloat = 0
    private var startMouse: CGPoint?
    private var startOrigin = CGPoint.zero
    private var cursorPushed = false
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    private var timer: Timer?
    private var motion: RulerMomentum?
    private var motionOrigin = CGPoint.zero
    private var limits = CGRect.zero
    private var lastTime: TimeInterval = 0
    private var started: TimeInterval = 0
    private lazy var tickPlayer = LoupeTickPlayer()
    private var bevelImage: NSImage?
    private var bevelScale: CGFloat = 0
    private let labelText: [(normal: NSAttributedString, selected: NSAttributedString)] =
        LoupeScale.levels.map { level in
            let text = "\(level.formatted(.number.precision(.fractionLength(0...2))))×"
            let normal = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 0.8)
            ])
            let selected = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)
            ])
            return (normal, selected)
        }

    init(loupeFrame frame: CGRect) throws {
        renderer = try LoupeRenderer()
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(softShadow)
        softShadow.update(bounds: bounds,
                          silhouette: CGPath(ellipseIn: bounds.insetBy(dx: 5, dy: 5), transform: nil),
                          caster: CGPath(ellipseIn: bounds.insetBy(dx: 9, dy: 9), transform: nil))
        ringGlass.frame = bounds.insetBy(dx: 5, dy: 5)
        InstrumentGlass.configure(ringGlass, cornerRadius: 145)
        ringGlass.wantsLayer = true

        let mask = CAShapeLayer()
        mask.frame = ringGlass.bounds
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: ringGlass.bounds)
        // Extend glass two points beneath the lens's antialiased edge so
        // independently composited masks cannot reveal a sharp desktop seam.
        ringPath.addEllipse(in: CGRect(x: 39, y: 39, width: 212, height: 212))
        mask.path = ringPath
        mask.fillRule = .evenOdd
        ringGlass.layer?.mask = mask
        addSubview(ringGlass)

        renderer.view.frame = CGRect(x: 42, y: 42, width: 216, height: 216)
        addSubview(renderer.view)
        dialOverlay.frame = bounds
        dialOverlay.owner = self
        addSubview(dialOverlay)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Loupe magnification")
        setAccessibilityHelp("Drag the center to move or throw. Drag the ring to change magnification.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMaskScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMaskScale()
    }

    private func updateMaskScale() {
        let scale = window?.backingScaleFactor ?? 2
        ringGlass.layer?.mask?.contentsScale = scale
        if bevelScale != scale {
            bevelScale = scale
            bevelImage = LoupeRingBevel.image(size: bounds.size, scale: scale)
            dialOverlay.needsDisplay = true
        }
        renderer.requestDraw()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - 150, p.y - 150) <= 146 ? self : nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    fileprivate func drawDial(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        ring.appendOval(in: CGRect(x: 42, y: 42, width: 216, height: 216))
        ring.windingRule = .evenOdd
        NSColor.white.withAlphaComponent(InstrumentGlass.acrylicOverlayOpacity).setFill()
        ring.fill()
        bevelImage?.draw(in: bounds)
        NSColor(calibratedWhite: 0.65, alpha: 0.5).setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 5.5, dy: 5.5)).stroke()
        let ticks = NSBezierPath()
        for tick in 0..<90 {
            let position = Double(tick) / Double(LoupeScale.subdivisions)
            let a = CGFloat(LoupeScale.angle(at: position, dial: dial))
            let long = tick % LoupeScale.subdivisions == 0 && position <= Double(Self.levels.count - 1)
            ticks.move(to: CGPoint(x: 150 + cos(a) * 141, y: 150 + sin(a) * 141))
            ticks.line(to: CGPoint(x: 150 + cos(a) * (long ? 135 : 138), y: 150 + sin(a) * (long ? 135 : 138)))
        }
        NSColor(calibratedWhite: 0.16, alpha: 0.8).setStroke()
        ticks.lineWidth = 0.7
        ticks.stroke()
        for i in Self.levels.indices {
            let a = CGFloat(LoupeScale.angle(at: Double(i), dial: dial))
            let isAtTick = abs(Double(i) - dial) < 0.025
            let text = isAtTick ? labelText[i].selected : labelText[i].normal
            let size = text.size()
            text.draw(at: CGPoint(x: 150 + cos(a) * 124 - size.width / 2,
                                  y: 150 + sin(a) * 124 - size.height / 2))
        }
        // Fixed index inside the rail, between the lens edge and the zoom label.
        let pointer = NSBezierPath(ovalIn: CGRect(x: 147.5, y: 260.5, width: 5, height: 5))
        NSColor(calibratedWhite: 0.16, alpha: 0.85).setFill()
        pointer.fill()

        if let status {
            NSColor(white: 0.13, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 42, y: 42, width: 216, height: 216)).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (status as NSString).draw(in: CGRect(x: 58, y: 123, width: 184, height: 54), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph])
        }
    }

    override func mouseDown(with event: NSEvent) {
        stopMotion()
        samples.removeAll()
        let p = convert(event.locationInWindow, from: nil)
        draggingDial = hypot(p.x - 150, p.y - 150) >= 108
        if draggingDial && (UserDefaults.standard.object(forKey: "loupeTickSound") as? Bool ?? true) {
            tickPlayer.prepare()
        }
        lastAngle = atan2(p.y - 150, p.x - 150)
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        if !draggingDial { samples = [(NSEvent.mouseLocation, event.timestamp)] }
        NSCursor.closedHand.push()
        cursorPushed = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startMouse else { return }
        if draggingDial {
            let p = convert(event.locationInWindow, from: nil)
            let angle = atan2(p.y - 150, p.x - 150)
            let difference = angle - lastAngle
            let delta = atan2(sin(difference), cos(difference))
            lastAngle = angle
            // Drag clockwise to increase magnification.
            setDial(dial - Double(delta * 180 / .pi) / LoupeScale.degreesPerLevel)
        } else {
            let p = NSEvent.mouseLocation
            window?.setFrameOrigin(CGPoint(x: startOrigin.x + p.x - startMouse.x, y: startOrigin.y + p.y - startMouse.y))
            samples.append((p, event.timestamp))
            samples.removeAll { event.timestamp - $0.time > 0.09 }
            LoupeController.shared.updatePosition()
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard startMouse != nil else { return }
        startMouse = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        if !draggingDial { startThrow() }
        samples.removeAll()
    }
    func cancelInteraction() {
        stopMotion()
        samples.removeAll()
        startMouse = nil
        dialOverlay.needsDisplay = true
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
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
        motion = RulerMomentum(velocity: velocity, surface: .ruler)
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
        LoupeController.shared.updatePosition()
        if motion.isStopped { stopMotion() }
    }

    override func accessibilityValue() -> Any? {
        "\(LoupeScale.zoom(at: dial).formatted(.number.precision(.fractionLength(0...2)))) times"
    }

    override func accessibilityPerformIncrement() -> Bool { step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }
    private func step(_ delta: Int) {
        let next = delta > 0 ? floor(dial) + 1 : ceil(dial) - 1
        setDial(next)
    }

    private func setDial(_ position: Double) {
        let next = LoupeScale.clamp(position)
        guard next != dial else { return }

        let crossedTick = LoupeScale.crossesTick(from: dial, to: next)
        dial = next
        let zoom = LoupeScale.zoom(at: dial)
        renderer.zoom = Float(zoom)
        renderer.requestDraw()
        dialOverlay.needsDisplay = true

        // Feedback belongs to the engraved marks, not the midpoints between them.
        // Coalesce fast crossings into one immediate tick rather than queueing audio.
        guard crossedTick else { return }
        if UserDefaults.standard.object(forKey: "loupeTickSound") as? Bool ?? true {
            tickPlayer.play()
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

}

@MainActor
private final class LoupeDialOverlay: NSView {
    weak var owner: LoupeView?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawDial(dirtyRect) }
}
