import AVFoundation
import Foundation

/// Audio device startup and playback never run in an AppKit mouse handler.
/// All player state is owned by the serial audio queue.
nonisolated final class LoupeTickPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PencilCase.loupe.tick", qos: .userInteractive)
    private let pending = DispatchSemaphore(value: 1)
    private var player: AVAudioPlayer?

    init() {
        queue.async { [self] in
            player = try? AVAudioPlayer(data: Self.clickSound())
            player?.prepareToPlay()
        }
    }

    func prepare() {
        submit { player in
            if !player.isPlaying { player.prepareToPlay() }
        }
    }

    func play() {
        submit { player in
            player.currentTime = 0
            player.play()
        }
    }

    private func submit(_ action: @escaping @Sendable (AVAudioPlayer) -> Void) {
        guard pending.wait(timeout: .now()) == .success else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + 80_000_000

        queue.async { [self] in
            defer { pending.signal() }
            // Never replay a backlog of old ticks after an audio-device stall.
            guard DispatchTime.now().uptimeNanoseconds <= deadline, let player else { return }
            action(player)
        }
    }

    private static func clickSound() -> Data {
        let rate = 44100
        let count = 441
        var pcm = Data()
        var random: UInt32 = 0x12345678
        for i in 0..<count {
            random = 1664525 &* random &+ 1013904223
            let noise = Double(random & 0xffff) / 32767.5 - 1
            let t = Double(i) / Double(rate)
            let envelope = exp(-t * 750) * min(1, Double(i) / 8)
            var sample = Int16((noise * 0.4 + sin(t * 2 * .pi * 2400) * 0.6) * envelope * 11000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + pcm.count))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
