import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class MarkerController: NSObject, ObservableObject {
    static let shared = MarkerController()

    @Published private(set) var inkColor: NSColor = MarkerColor.presets[0].color
    @Published var strokeWidth: Double = 3
    private var colorPopover: NSPopover?
    private var escapeHotKey: EventHotKeyRef?
    private var undoHotKey: EventHotKeyRef?
    private var redoHotKey: EventHotKeyRef?
    @Published private(set) var historyShortcutError: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var escapeShortcutError: String?

    @Published private(set) var isVisible = false
    @Published private(set) var isDrawing = false
    @Published private(set) var hasMarkings = false

    private var markerPanel: NSPanel?
    private var canvases: [MarkerCanvasPanel] = []
    private var strokes: [Stroke] = []
    private var undoneStrokes: [Stroke] = []
    private var current: Stroke?
    private var guide: MarkerGuide?
    private var expiryTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    private struct Stroke {
        var points: [CGPoint]
        var color: NSColor
        var width: CGFloat
        var excludedRuler: CGPath?
        var finished: TimeInterval?
    }

    private override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setDrawing(false)
                self.rebuildCanvases()
                if self.isVisible { self.ensureMarkerOnScreen() }
            }
        }
    }

    func selectColor(_ color: NSColor) {
        // Resolve once so a stroke does not change with appearance or later selection.
        inkColor = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1)
        markerPanel?.contentView?.needsDisplay = true
    }

    func isSelected(_ color: NSColor) -> Bool {
        guard let a = inkColor.usingColorSpace(.sRGB), let b = color.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.001
            && abs(a.greenComponent - b.greenComponent) < 0.001
            && abs(a.blueComponent - b.blueComponent) < 0.001
    }

    func showColorPalette(from view: NSView) {
        (markerPanel?.contentView as? MarkerView)?.stopMotion()
        colorPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MarkerColorPalette(marker: self))
        colorPopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    func choosePaletteColor(_ color: NSColor) {
        selectColor(color)
        colorPopover?.close()
    }

    func showCustomColor() {
        colorPopover?.close()
        // Release the desktop input surface while interacting with the native picker.
        setDrawing(false)
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = inkColor
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        selectColor(sender.color)
    }

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        if visible {
            if markerPanel == nil { makeMarker() }
            ensureMarkerOnScreen()
            markerPanel?.orderFrontRegardless()
        } else {
            colorPopover?.close()
            setDrawing(false)
            (markerPanel?.contentView as? MarkerView)?.cancelInteraction()
            markerPanel?.orderOut(nil)
        }
        isVisible = visible
    }

    func setDrawing(_ enabled: Bool) {
        guard enabled != isDrawing else { return }
        if enabled {
            setVisible(true)
            (markerPanel?.contentView as? MarkerView)?.stopMotion()
            RulerController.shared.pauseForMarking()
            if canvases.isEmpty { rebuildCanvases() }
        } else {
            finishStroke()
        }

        isDrawing = enabled
        if enabled {
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x50434C52, id: 3),
                GetApplicationEventTarget(), 0, &escapeHotKey
            )
            escapeShortcutError = status == noErr ? nil : "Global Escape unavailable; turn off Draw on Screen in the menu"
            let undoStatus = RegisterEventHotKey(
                UInt32(kVK_ANSI_Z), UInt32(cmdKey), EventHotKeyID(signature: 0x50434C52, id: 4),
                GetApplicationEventTarget(), 0, &undoHotKey
            )
            let redoStatus = RegisterEventHotKey(
                UInt32(kVK_ANSI_Z), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x50434C52, id: 5),
                GetApplicationEventTarget(), 0, &redoHotKey
            )
            historyShortcutError = undoStatus == noErr && redoStatus == noErr
                ? nil : "Undo/redo shortcut unavailable; use the menu commands"
        } else {
            if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
            if let undoHotKey { UnregisterEventHotKey(undoHotKey) }
            if let redoHotKey { UnregisterEventHotKey(redoHotKey) }
            undoHotKey = nil
            redoHotKey = nil
            historyShortcutError = nil
            escapeHotKey = nil
            escapeShortcutError = nil
        }
        for panel in canvases {
            panel.ignoresMouseEvents = !enabled
            if enabled || hasMarkings { panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
            if let view = panel.contentView {
                panel.invalidateCursorRects(for: view)
            }
        }
        if enabled {
            let panel = canvases.first { $0.frame.contains(NSEvent.mouseLocation) } ?? canvases.first
            panel?.makeKey()
            panel?.makeFirstResponder(panel?.contentView)
        } else {
            canvases.forEach { $0.resignKey() }
            NSCursor.arrow.set()
        }
        markerPanel?.contentView?.needsDisplay = true
    }

    func undoStroke() {
        // Treat an in-progress gesture as the latest stroke too.
        finishStroke()
        guard let stroke = strokes.popLast() else { return }
        undoneStrokes.append(stroke)
        // Bound retained geometry even during a long drawing session.
        if undoneStrokes.count > 100 { undoneStrokes.removeFirst() }
        scheduleExpiry()
        refresh()
    }

    func redoStroke() {
        guard current == nil, var stroke = undoneStrokes.popLast() else { return }
        stroke.finished = ProcessInfo.processInfo.systemUptime
        strokes.append(stroke)
        if canvases.isEmpty { rebuildCanvases() }
        scheduleExpiry()
        refresh()
    }

    func clearMarkings() {
        current = nil
        guide = nil
        strokes.removeAll()
        undoneStrokes.removeAll()
        expiryTimer?.invalidate()
        expiryTimer = nil
        refresh()
    }

    func beginStroke(at point: CGPoint) {
        guard isDrawing else { return }
        guide = RulerController.shared.markingGuides.min { $0.distance(to: point) < $1.distance(to: point) }
        if let candidate = guide, candidate.distance(to: point) > 12 { guide = nil }
        current = Stroke(points: [guide?.project(point) ?? point], color: inkColor, width: CGFloat(strokeWidth),
                         excludedRuler: RulerController.shared.markingExclusionPath)
        refresh()
    }

    func continueStroke(at point: CGPoint) {
        guard var stroke = current else { return }
        let point = guide?.project(point) ?? point
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.5 { return }
        if guide != nil, stroke.points.count == 2 { stroke.points[1] = point }
        else { stroke.points.append(point) }
        current = stroke
        refresh()
    }

    func finishStroke() {
        guard var stroke = current else { return }
        stroke.finished = ProcessInfo.processInfo.systemUptime
        strokes.append(stroke)
        undoneStrokes.removeAll()
        current = nil
        guide = nil
        scheduleExpiry()
        refresh()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let oldest = strokes.first?.finished else { return }
        let age = ProcessInfo.processInfo.systemUptime - oldest
        // Sleep while the ink is static; redraw only during its half-second fade.
        let delay = age < 30 ? 30 - age : 1 / 30.0
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireStrokes() }
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func expireStrokes() {
        let now = ProcessInfo.processInfo.systemUptime
        strokes.removeAll { now - ($0.finished ?? now) >= 30.5 }
        refresh()
        scheduleExpiry()
    }

    private func refresh() {
        let visibleInk = !strokes.isEmpty || current != nil
        if canUndo != visibleInk { canUndo = visibleInk }
        let redoAvailable = current == nil && !undoneStrokes.isEmpty
        if canRedo != redoAvailable { canRedo = redoAvailable }
        if hasMarkings != visibleInk { hasMarkings = visibleInk }
        for panel in canvases {
            panel.contentView?.needsDisplay = true
            if hasMarkings && !panel.isVisible { panel.orderFrontRegardless() }
            if !hasMarkings && !isDrawing { panel.orderOut(nil) }
        }
    }

    func rulerDidChange() {
        guard hasMarkings else { return }
        canvases.forEach { $0.contentView?.needsDisplay = true }
    }

    func drawInk(in view: NSView) {
        guard let context = NSGraphicsContext.current?.cgContext, let window = view.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let currentRuler = RulerController.shared.markingExclusionPath
        for stroke in strokes + (current.map { [$0] } ?? []) {
            guard let first = stroke.points.first else { continue }
            context.saveGState()
            defer { context.restoreGState() }

            // Retain the original cutout so moving the ruler never reveals hidden ink.
            // Also protect its current surface when it moves across older strokes.
            let origin = view.convert(window.convertPoint(fromScreen: .zero), from: nil)
            var transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            for exclusion in [stroke.excludedRuler, currentRuler].compactMap({ $0 }) {
                if let localPath = exclusion.copy(using: &transform) {
                    context.beginPath()
                    context.addRect(view.bounds.insetBy(dx: -1, dy: -1))
                    context.addPath(localPath)
                    context.clip(using: .evenOdd)
                }
            }

            let age = stroke.finished.map { now - $0 } ?? 0
            let alpha = max(0, min(1, (30.5 - age) / 0.5))
            context.setStrokeColor(stroke.color.withAlphaComponent(alpha).cgColor)
            context.setFillColor(stroke.color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(stroke.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            func local(_ point: CGPoint) -> CGPoint {
                view.convert(window.convertPoint(fromScreen: point), from: nil)
            }
            if stroke.points.count == 1 {
                let p = local(first)
                context.fillEllipse(in: CGRect(x: p.x - stroke.width / 2, y: p.y - stroke.width / 2, width: stroke.width, height: stroke.width))
            } else {
                context.beginPath()
                context.move(to: local(first))
                for point in stroke.points.dropFirst() { context.addLine(to: local(point)) }
                context.strokePath()
            }
        }
    }

    private func rebuildCanvases() {
        canvases.forEach { $0.orderOut(nil) }
        canvases = NSScreen.screens.map { screen in
            let panel = MarkerCanvasPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Pencil Case Markings"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
            panel.contentView = MarkerCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
            if hasMarkings { panel.orderFrontRegardless() }
            return panel
        }
    }

    private func makeMarker() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 66, height: 210), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pencil Case Marker"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        panel.contentView = MarkerView(frame: CGRect(origin: .zero, size: panel.frame.size))
        markerPanel = panel
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX + 260, y: frame.midY - 100))
        }
    }

    private func ensureMarkerOnScreen() {
        guard let panel = markerPanel,
              !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }),
              let frame = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: frame.midX, y: frame.midY))
    }
}

private final class MarkerCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class MarkerCanvasView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        if MarkerController.shared.isDrawing { addCursorRect(bounds, cursor: .crosshair) }
    }
    override func draw(_ dirtyRect: NSRect) { MarkerController.shared.drawInk(in: self) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        MarkerController.shared.beginStroke(at: NSEvent.mouseLocation)
    }
    override func mouseDragged(with event: NSEvent) {
        MarkerController.shared.continueStroke(at: NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) { MarkerController.shared.finishStroke() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { MarkerController.shared.setDrawing(false) }
        else { super.keyDown(with: event) }
    }
}
