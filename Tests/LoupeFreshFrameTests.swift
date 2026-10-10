import AppKit
import CoreVideo

@main
struct FreshFrameTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let renderer = try LoupeRenderer()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 216, height: 216), styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 216, height: 216))
        renderer.view.frame = container.bounds
        container.addSubview(renderer.view)
        container.alphaValue = 0
        window.contentView = container
        var revealCount = 0
        renderer.didRevealFreshFrame = {
            revealCount += 1
            container.alphaValue = 1
        }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        renderer.setActive(true)
        precondition(renderer.view.alphaValue == 0)
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        for _ in 0..<3 {
            renderer.receive(buffer!)
            renderer.setActive(false)
            renderer.clear()
            renderer.setActive(true)
            try await Task.sleep(for: .milliseconds(150))
            precondition(renderer.view.alphaValue == 0, "Old GPU completion revealed a stale desktop")
        }
        renderer.receive(buffer!)
        for _ in 0..<120 {
            if renderer.view.alphaValue == 1 { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        precondition(renderer.view.alphaValue == 1, "A single fresh frame must reveal a static desktop")
        precondition(revealCount == 1 && container.alphaValue == 1)
        renderer.receive(buffer!)
        try await Task.sleep(for: .milliseconds(100))
        precondition(revealCount == 1, "Normal frames must not repeat the initial reveal")
        renderer.setActive(false)
        renderer.clear()
        precondition(renderer.view.alphaValue == 0)
        print("PASS: initial hidden lens, stale in-flight completions rejected, one fresh frame reveals, clear hides immediately")
    }
}
