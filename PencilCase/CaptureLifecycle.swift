import Foundation

/// Serializes asynchronous capture operations; cancelling a request invalidates
/// its result but never interrupts cleanup or lets a new start overtake a stop.
@MainActor
final class CaptureLifecycle<Stream: AnyObject> {
    private var current: Stream?
    private(set) var active: Stream?
    private var revision = 0
    private var tail: Task<Void, Never>?
    private let startStream: (Stream) async throws -> Void
    private let stopStream: (Stream) async throws -> Void
    var failed: ((Error) -> Void)?

    init(start: @escaping (Stream) async throws -> Void,
         stop: @escaping (Stream) async throws -> Void) {
        startStream = start
        stopStream = stop
    }

    func start(make: @escaping () async throws -> Stream) async throws {
        try Task.checkCancellation()
        revision += 1
        let request = revision
        active = nil
        let predecessor = tail

        let operation = Task { @MainActor in
            await predecessor?.value
            guard request == self.revision else { throw CancellationError() }
            try await self.stopCurrent()
            guard request == self.revision else { throw CancellationError() }

            let candidate = try await make()
            guard request == self.revision else { throw CancellationError() }
            self.current = candidate
            do {
                try await self.startStream(candidate)
            } catch {
                // Startup has completed with failure, so there is no running
                // stream to stop. Retrying must not stop a never-started stream.
                if self.current === candidate { self.current = nil }
                throw error
            }

            guard request == self.revision else {
                try await self.stopCurrent()
                throw CancellationError()
            }
            guard self.current === candidate else {
                throw NSError(domain: "LoupeCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Capture ended during startup."])
            }
            self.active = candidate
        }
        tail = Task { _ = await operation.result }

        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            Task { @MainActor in
                if self.revision == request { self.stop() }
            }
        }
    }

    func stop() {
        revision += 1
        active = nil
        let predecessor = tail
        tail = Task { @MainActor in
            await predecessor?.value
            do { try await self.stopCurrent() }
            catch { self.failed?(error) }
        }
    }

    func waitForStop() async { await tail?.value }

    /// SCStream's delegate reports that this stream has already ended.
    func didEnd(_ stream: Stream) -> Bool {
        guard current === stream else { return false }
        current = nil
        active = nil
        return true
    }

    private func stopCurrent() async throws {
        guard let previous = current else { return }
        active = nil
        // Keep ownership on failure: a later request must retry shutdown before
        // it can create another stream. Never assume that try? means stopped.
        do { try await stopStream(previous) }
        catch {
            // An end callback may have confirmed shutdown during the await.
            if current === previous { throw error }
        }
        if current === previous { current = nil }
    }
}
