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
    private var eventHandler: EventHandlerRef?

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in RulerController.shared.toggle() }
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
        if status != noErr {
            shortcutError = "⇧⌘R unavailable outside this menu"
        }
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
    }

    func resetPosition() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
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
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        window.contentView = RulerView(frame: initialFrame)
        panel = window
        resetPosition()
    }
}
