import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class MarkerController: NSObject, ObservableObject {
    static let shared = MarkerController()

    @Published private(set) var tools = MarkerTool.defaults
    @Published private(set) var selectedToolID = 0
    private var customColorToolID = 0

    var inkColor: NSColor { tools[selectedToolID].color }
    var strokeWidth: Double { tools[selectedToolID].width }

    func selectTool(_ id: Int) {
        guard tools.indices.contains(id), id != selectedToolID else { return }
        finishStroke()
        selectedToolID = id
        redrawTools()
    }

    func activateTip(_ id: Int) {
        let wasActive = selectedToolID == id && isDrawing
        selectTool(id)
        setDrawing(!wasActive)
    }

    private func redrawTools() {
        for (id, panel) in markerPanels.enumerated() {
            panel.contentView?.needsDisplay = true
            panel.contentView?.setAccessibilityLabel("\(tools[id].name) \(id + 1)")
        }
    }

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

    private var markerPanels: [NSPanel] = []
    private var markerPanel: NSPanel? {
        markerPanels.indices.contains(selectedToolID) ? markerPanels[selectedToolID] : nil
    }

    private var canvases: [MarkerCanvasPanel] = []
    private var strokes: [MarkerStroke] = []
    private var undoneStrokes: [MarkerStroke] = []
    private var current: MarkerStroke?
    private var guide: MarkerGuide?
    private var lifetime = DrawingPreferences.shared.lifetime
    private var preferenceSubscription: AnyCancellable?
    private var expiryTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    private var previousRulerBounds = CGRect.null

    private override init() {
        super.init()
        preferenceSubscription = DrawingPreferences.shared.$automatic
            .combineLatest(DrawingPreferences.shared.$seconds)
            .dropFirst()
            .sink { [weak self] automatic, seconds in
                guard let self else { return }
                self.lifetime = InkLifetime(automatic: automatic, seconds: Double(seconds))
                // Preferences apply to existing ink too, using its completion time.
                let damage = self.strokes.reduce(CGRect.null) { $0.union($1.bounds) }
                self.expireStrokes()
                self.refresh(damage: damage)
            }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.markerPanel?.isOnActiveSpace != true {
                    self.setDrawing(false)
                    self.colorPopover?.close()
                    self.markerPanels.forEach { ($0.contentView as? MarkerView)?.cancelInteraction() }
                }
            }
        }
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

    func selectColor(_ color: NSColor, for toolID: Int? = nil) {
        // Resolve once so a stroke does not change with appearance or later selection.
        tools[toolID ?? selectedToolID].color = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1)
        redrawTools()
    }

    func isSelected(_ color: NSColor, for toolID: Int? = nil) -> Bool {
        guard let a = tools[toolID ?? selectedToolID].color.usingColorSpace(.sRGB), let b = color.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.001
            && abs(a.greenComponent - b.greenComponent) < 0.001
            && abs(a.blueComponent - b.blueComponent) < 0.001
    }

    func showColorPalette(from view: MarkerView) {
        let toolID = view.toolID
        view.stopMotion()
        colorPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MarkerColorPalette(marker: self, toolID: toolID))
        colorPopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    func choosePaletteColor(_ color: NSColor, for toolID: Int) {
        selectColor(color, for: toolID)
        colorPopover?.close()
    }

    func showCustomColor(for toolID: Int? = nil) {
        customColorToolID = toolID ?? selectedToolID
        colorPopover?.close()
        // Release the desktop input surface while interacting with the native picker.
        setDrawing(false)
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = tools[customColorToolID].color
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        selectColor(sender.color, for: customColorToolID)
    }

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        if visible {
            if markerPanels.isEmpty { makeMarkers() }
            ensureMarkerOnScreen()
            markerPanels.forEach { $0.orderFrontRegardless() }
        } else {
            colorPopover?.close()
            setDrawing(false)
            markerPanels.forEach {
                ($0.contentView as? MarkerView)?.cancelInteraction()
                $0.orderOut(nil)
            }
        }
        isVisible = visible
    }

    func setDrawing(_ enabled: Bool) {
        guard enabled != isDrawing else { return }
        if enabled {
            setVisible(true)
            guard markerPanel?.isOnActiveSpace == true else { return }
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
            escapeShortcutError = status == noErr ? nil : "Global Escape unavailable; click the active marker tip to stop drawing"
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
        releaseUnusedCanvases()
        redrawTools()
    }

    func undoStroke() {
        // Treat an in-progress gesture as the latest stroke too.
        finishStroke()
        guard let stroke = strokes.popLast() else { return }
        undoneStrokes.append(stroke)
        // Bound retained geometry even during a long drawing session.
        if undoneStrokes.count > 100 { undoneStrokes.removeFirst() }
        scheduleExpiry()
        refresh(damage: stroke.bounds)
    }

    func redoStroke() {
        guard current == nil, let stroke = undoneStrokes.popLast() else { return }
        stroke.finished = ProcessInfo.processInfo.systemUptime
        strokes.append(stroke)
        if canvases.isEmpty { rebuildCanvases() }
        scheduleExpiry()
        refresh(damage: stroke.bounds)
    }

    func clearMarkings() {
        let damage = strokes.reduce(current?.bounds ?? .null) { $0.union($1.bounds) }
        current = nil
        guide = nil
        strokes.removeAll()
        undoneStrokes.removeAll()
        expiryTimer?.invalidate()
        expiryTimer = nil
        refresh(damage: damage)
    }

    func beginStroke(at point: CGPoint) {
        guard isDrawing else { return }
        guide = RulerController.shared.markingGuides.min { $0.distance(to: point) < $1.distance(to: point) }
        if let candidate = guide, candidate.distance(to: point) > 12 { guide = nil }
        let exclusion = RulerController.shared.markingExclusionPath
        previousRulerBounds = exclusion?.boundingBoxOfPath ?? .null
        let stroke = MarkerStroke(point: guide?.strokePoint(point, width: CGFloat(strokeWidth)) ?? point,
                                  color: inkColor, width: CGFloat(strokeWidth),
                                  opacity: tools[selectedToolID].opacity, excludedRuler: exclusion)
        current = stroke
        refresh(damage: stroke.bounds)
    }

    func continueStroke(at point: CGPoint) {
        guard let stroke = current else { return }
        let point = guide?.strokePoint(point, width: stroke.width) ?? point
        guard hypot(point.x - stroke.last.x, point.y - stroke.last.y) >= 0.5 else { return }
        let damage = stroke.append(point, guided: guide != nil)
        refresh(damage: damage)
    }

    func finishStroke() {
        guard let stroke = current else { return }
        stroke.finish(at: ProcessInfo.processInfo.systemUptime)
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
        guard let delay = lifetime.nextUpdate(age: age) else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireStrokes() }
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func expireStrokes() {
        let now = ProcessInfo.processInfo.systemUptime
        let damage = strokes.reduce(CGRect.null) { result, stroke in
            now - (stroke.finished ?? now) >= lifetime.seconds ? result.union(stroke.bounds) : result
        }
        strokes.removeAll { lifetime.expired(age: now - ($0.finished ?? now)) }
        refresh(damage: damage)
        scheduleExpiry()
    }

    private func refresh(damage: CGRect = .null) {
        let visibleInk = !strokes.isEmpty || current != nil
        if canUndo != visibleInk { canUndo = visibleInk }
        let redoAvailable = current == nil && !undoneStrokes.isEmpty
        if canRedo != redoAvailable { canRedo = redoAvailable }
        if hasMarkings != visibleInk { hasMarkings = visibleInk }
        let inkBounds = strokes.map(\.bounds) + (current.map { [$0.bounds] } ?? [])
        for panel in canvases {
            if let view = panel.contentView as? MarkerCanvasView {
                view.updateInkRegions(inkBounds)
                invalidate(damage, in: view)
            }
            if hasMarkings && !panel.isVisible { panel.orderFrontRegardless() }
            if !hasMarkings && !isDrawing { panel.orderOut(nil) }
        }
        releaseUnusedCanvases()
    }

    private func releaseUnusedCanvases() {
        guard !isDrawing, !hasMarkings else { return }
        canvases.forEach { $0.orderOut(nil); $0.contentView = nil }
        canvases.removeAll()
    }

    private func invalidate(_ screenRect: CGRect, in view: NSView) {
        guard !screenRect.isNull, let window = view.window else { return }
        let local = view.convert(window.convertFromScreen(screenRect), from: nil).intersection(view.bounds)
        guard !local.isNull, !local.isEmpty else { return }
        (view as? MarkerCanvasView)?.invalidateInk(in: local.integral.intersection(view.bounds))
    }

    func rulerDidChange() {
        let bounds = RulerController.shared.markingExclusionPath?.boundingBoxOfPath ?? .null
        let damage = previousRulerBounds.union(bounds).insetBy(dx: -2, dy: -2)
        previousRulerBounds = bounds
        guard hasMarkings, !damage.isNull else { return }
        for panel in canvases {
            guard let view = panel.contentView else { continue }
            for stroke in strokes { invalidate(stroke.bounds.intersection(damage), in: view) }
            if let current { invalidate(current.bounds.intersection(damage), in: view) }
        }
    }

    func drawInk(in view: NSView, dirtyRect: CGRect? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext, let window = view.window else { return }
        let dirty = (dirtyRect ?? view.bounds).intersection(view.bounds)
        guard !dirty.isNull, !dirty.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirty)
        // Repaint all intersecting strokes in their original order, rather than
        // painting new translucent ink onto an already composited canvas.
        context.clear(dirty)
        let origin = view.convert(window.convertPoint(fromScreen: .zero), from: nil)
        context.translateBy(x: origin.x, y: origin.y)
        let screenBounds = view.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let screenDirty = dirty.offsetBy(dx: -origin.x, dy: -origin.y)
        let now = ProcessInfo.processInfo.systemUptime
        let ruler = RulerController.shared.markingExclusionPath
        for stroke in strokes where stroke.bounds.intersects(screenDirty) {
            stroke.draw(in: context, at: now, canvasBounds: screenBounds, ruler: ruler, lifetime: lifetime)
        }
        if let current, current.bounds.intersects(screenDirty) {
            current.draw(in: context, at: now, canvasBounds: screenBounds, ruler: ruler, lifetime: lifetime)
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
            // Instruments remain directly interactive while drawing mode is active.
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllApplications]
            let view = MarkerCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            view.updateInkRegions(strokes.map(\.bounds) + (current.map { [$0.bounds] } ?? []))
            if hasMarkings { panel.orderFrontRegardless() }
            return panel
        }
    }

    private func makeMarkers() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let frames = MarkerGeometry.spawnFrames(in: frame)
        markerPanels = tools.indices.map { id in
            let panel = NSPanel(contentRect: frames[id], styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Pencil Case Drawing Tool \(id + 1)"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
            panel.collectionBehavior = [.canJoinAllApplications]
            panel.contentView = MarkerView(frame: CGRect(origin: .zero, size: frames[id].size), toolID: id)
            return panel
        }
    }

    private func ensureMarkerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let frames = MarkerGeometry.spawnFrames(in: screen.visibleFrame)
        for (id, panel) in markerPanels.enumerated() {
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                panel.setFrameOrigin(frames[id].origin)
            }
        }
    }

}

private final class MarkerCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class MarkerCanvasView: NSView {
    private var tiles: [MarkerInkTile: MarkerInkTileView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        // This full-screen view receives input, but never rasterizes a full-screen
        // bitmap. Only the small ink subviews allocate drawable backing surfaces.
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func updateInkRegions(_ regions: [CGRect]) {
        guard let window else { return }
        let localRegions = regions.map { convert(window.convertFromScreen($0), from: nil) }
        let required = MarkerInkTile.covering(localRegions, in: bounds)
        for key in Set(tiles.keys).subtracting(required) {
            tiles.removeValue(forKey: key)?.removeFromSuperview()
        }
        for key in required where tiles[key] == nil {
            let tile = MarkerInkTileView(frame: key.frame.intersection(bounds))
            tile.wantsLayer = true
            addSubview(tile)
            tiles[key] = tile
            tile.needsDisplay = true
        }
    }

    func invalidateInk(in rect: CGRect) {
        for tile in tiles.values {
            let intersection = rect.intersection(tile.frame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            tile.setNeedsDisplay(convert(intersection, to: tile))
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        if MarkerController.shared.isDrawing { addCursorRect(bounds, cursor: .crosshair) }
    }
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

/// Transparent to hit testing: the desktop input view keeps ownership of drags,
/// including when a stroke crosses tile boundaries.
private final class MarkerInkTileView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        MarkerController.shared.drawInk(in: self, dirtyRect: dirtyRect)
    }
}
