import AppKit
import Carbon
import Combine

@MainActor
final class RulerController: ObservableObject {
    static let shared = RulerController()

    @Published private(set) var isVisible = false
    @Published private(set) var shortcutError: String?
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var markerHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x50434C52 else { return OSStatus(eventNotHandledErr) }
            let id = identifier.id
            Task { @MainActor in
                if id == 1 { RulerController.shared.toggle() }
                if id == 2 { MarkerController.shared.toggle() }
                if id == 3 { MarkerController.shared.setDrawing(false) }
                if id == 4 { MarkerController.shared.undoStroke() }
                if id == 5 { MarkerController.shared.redoStroke() }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        guard handlerStatus == noErr else {
            shortcutError = "Global shortcut unavailable"
            return
        }
        let identifier = EventHotKeyID(signature: 0x50434C52, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey
        )
        let markerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_M), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x50434C52, id: 2),
            GetApplicationEventTarget(), 0, &markerHotKey
        )
        if markerStatus != noErr { shortcutError = "⇧⌘M unavailable outside this menu" }
        if status != noErr {
            shortcutError = "⇧⌘R unavailable outside this menu"
        }
    }

    var markingExclusionPath: CGPath? {
        guard isVisible else { return nil }
        return (panel?.contentView as? RulerView)?.markingExclusionPath
    }

    var markingGuides: [MarkerGuide] {
        guard isVisible else { return [] }
        return (panel?.contentView as? RulerView)?.markingGuides ?? []
    }

    func pauseForMarking() {
        (panel?.contentView as? RulerView)?.cancelInteraction()
    }

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible {
            if panel == nil { makePanel() }
            if let panel, !NSScreen.screens.contains(where: {
                $0.visibleFrame.intersects(panel.frame)
            }) { resetPosition() }
            panel?.orderFrontRegardless()
        } else {
            // Keep the panel alive so its position survives hiding.
            (panel?.contentView as? RulerView)?.cancelInteraction()
            panel?.orderOut(nil)
        }
        isVisible = visible
        MarkerController.shared.rulerDidChange()
    }

    func resetPosition() {
        (panel?.contentView as? RulerView)?.cancelInteraction()
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
        MarkerController.shared.rulerDidChange()
    }

    func resetSizeAndAngle() {
        (panel?.contentView as? RulerView)?.resetGeometry()
        resetPosition()
    }

    private func makePanel() {
        let initialFrame = NSRect(origin: .zero, size: RulerGeometry().enclosingSize)
        let window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.title = "Pencil Case Ruler"
        window.isOpaque = false
        window.backgroundColor = .clear
        // Native glass already defines its edge; avoid an additional dark window shadow.
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        window.contentView = RulerView(frame: initialFrame)
        panel = window
        resetPosition()
    }
}
