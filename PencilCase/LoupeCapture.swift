import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import OSLog

/// One stream while the loupe is visible. Frames stay in IOSurfaces; no image copies or history.
@MainActor
final class LoupeCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lifecycle = CaptureLifecycle<SCStream>(
        start: { try await $0.startCapture() },
        stop: { try await $0.stopCapture() }
    )
    private let logger = Logger(subsystem: "PencilCase", category: "LoupeCapture")
    var receive: ((CVPixelBuffer) -> Void)?
    var failed: ((String) -> Void)?

    override init() {
        super.init()
        lifecycle.failed = { [weak self] error in
            guard let self else { return }
            let message = "Could not stop loupe capture: \(error.localizedDescription)"
            self.logger.error("\(message, privacy: .public)")
            self.failed?(message)
        }
    }

    func start(screen: NSScreen) async throws {
        try await lifecycle.start { [self] in
            try await makeStream(screen: screen)
        }
    }

    private func makeStream(screen: NSScreen) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }),
              let application = content.applications.first(where: {
                  $0.processID == ProcessInfo.processInfo.processIdentifier
              }) else {
            throw NSError(domain: "Loupe", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Pencil Case or its display is not available for capture. Try Show Loupe again."])
        }

        // Exclude the entire process, including windows created after capture starts.
        // Do not silently fall back to capturing our own glass or the loupe itself.
        let filter = SCContentFilter(display: display, excludingApplications: [application], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        // Preserve display pixels for small text. Three capture surfaces, plus a
        // bounded GPU queue, replace the old screenshot/reprocessing pipeline.
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureResolution = .best
        let candidate = SCStream(filter: filter, configuration: configuration, delegate: self)
        try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        return candidate
    }

    func stop() { lifecycle.stop() }

    func waitForStop() async { await lifecycle.waitForStop() }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // This callback was explicitly registered on the main queue.
        MainActor.assumeIsolated {
            guard stream === self.lifecycle.active, outputType == .screen, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
                  let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            receive?(buffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.lifecycle.didEnd(stream) else { return }
            self.logger.error("Capture ended: \(message, privacy: .public)")
            self.failed?(message)
        }
    }
}
