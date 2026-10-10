import AppKit
import Combine
import MetalKit

@MainActor
final class LoupeController: ObservableObject {
    static let shared = LoupeController()
    @Published private(set) var isVisible = false
    @Published private(set) var error: String?
    private var panel: NSPanel?
    private var loupe: LoupeView?
    private let capture = LoupeCapture()
    private var task: Task<Void, Never>?
    private var screenID: UInt32?
    private var observer: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var spaceRecoveryTask: Task<Void, Never>?
    private var isRecoveringSpace = false

    private init() {
        capture.receive = { [weak self] buffer in
            guard let self, self.isVisible, !self.isRecoveringSpace, self.panel?.isOnActiveSpace == true else { return }
            self.loupe?.status = nil
            self.loupe?.renderer.receive(buffer)
        }
        capture.failed = { [weak self] message in self?.showError(message) }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryCapture() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isVisible { self.updateActiveSpace() }
            }
        }

    }

    func toggle() { setVisible(!isVisible) }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible {
            do {
                if panel == nil { try makePanel() }
                isVisible = true
                if let panel, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                    resetPosition()
                }
                panel?.contentView?.alphaValue = 0
                panel?.orderFrontRegardless()
                updateActiveSpace(afterTransition: false)
            } catch { showError(error.localizedDescription) }
        } else {
            isVisible = false
            spaceRecoveryTask?.cancel()
            spaceRecoveryTask = nil
            isRecoveringSpace = false
            task?.cancel()
            task = nil
            capture.stop()
            screenID = nil
            loupe?.cancelInteraction()
            loupe?.renderer.setActive(false)
            loupe?.renderer.clear()
            panel?.orderOut(nil)
        }
    }

    private func updateActiveSpace(afterTransition: Bool = true) {
        spaceRecoveryTask?.cancel()
        task?.cancel()
        capture.stop()
        screenID = nil
        isRecoveringSpace = true
        loupe?.cancelInteraction()
        loupe?.renderer.setActive(false)
        loupe?.renderer.clear()
        panel?.contentView?.alphaValue = 0
        // Never carry a captured desktop image across a Space transition.
        // Reveal the complete instrument together, already magnifying its backdrop.
        guard panel?.isOnActiveSpace == true else {
            isRecoveringSpace = false
            spaceRecoveryTask = nil
            return
        }

        spaceRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await capture.waitForStop()

            // Space notifications can arrive during the desktop animation.
            // Debounce repeated transitions without blocking the input thread.
            if afterTransition {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
            guard !Task.isCancelled, isVisible, panel?.isOnActiveSpace == true else { return }

            loupe?.renderer.setActive(true)
            isRecoveringSpace = false
            spaceRecoveryTask = nil
            updatePosition()
        }
    }

    func retryCapture() {
        guard isVisible else { return }
        screenID = nil
        resetPositionIfNeeded()
        updatePosition()
    }

    private func resetPositionIfNeeded() {
        if let panel, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { resetPosition() }
    }

    func resetPosition() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let panel, let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
    }

    func updatePosition() {
        guard isVisible, !isRecoveringSpace, let panel, panel.isOnActiveSpace, let loupe else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        loupe.renderer.centerUV = SIMD2(Float((center.x - screen.frame.minX) / screen.frame.width),
                                       Float((screen.frame.maxY - center.y) / screen.frame.height))
        loupe.renderer.inverseScreenSize = SIMD2(Float(1 / screen.frame.width), Float(1 / screen.frame.height))
        if screenID != id {
            screenID = id
            task?.cancel()
            capture.stop()
            loupe.status = nil
            error = nil
            task = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                do {
                    try await capture.start(screen: screen)
                } catch {
                    guard !Task.isCancelled, self.isVisible, self.screenID == id else { return }
                    showError(error.localizedDescription)
                }
            }
        } else { loupe.renderer.requestDraw() }
    }

    private func showError(_ message: String) {
        error = message
        loupe?.renderer.clear()
        loupe?.status = "Loupe unavailable\nSee Pencil Case menu"
        if isVisible, panel?.isOnActiveSpace == true { panel?.contentView?.alphaValue = 1 }
    }

    private func makePanel() throws {
        let view = try LoupeView(loupeFrame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let container = LoupeContainerView(frame: CGRect(x: 0, y: 0, width: 348, height: 348))
        view.frame.origin = CGPoint(x: 24, y: 24)
        container.addSubview(view)
        let window = NSPanel(contentRect: container.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Pencil Case Loupe"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Keep the lens above the drawing surface so it remains interactive,
        // but beneath the ruler and marker.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllApplications]
        window.contentView = container
        loupe = view
        panel = window
        view.renderer.didRevealFreshFrame = { [weak self] in
            guard let self, self.isVisible, !self.isRecoveringSpace,
                  self.panel?.isOnActiveSpace == true else { return }
            self.panel?.contentView?.alphaValue = 1
        }
        resetPosition()
    }
}

/// Transparent padding for the loupe shadow must not intercept pointer events.
@MainActor
private final class LoupeContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
