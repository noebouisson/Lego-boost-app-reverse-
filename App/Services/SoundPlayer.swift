import AppCore
import AVFoundation
import BlockEngine

/// Sons synthétisés sur l'iPad : aucun fichier audio.
final class SoundPlayer: SoundPlaying, @unchecked Sendable {

    /// Note glissant d'une fréquence à une autre, suivie d'un silence.
    private struct Segment {
        var from: Double
        var to: Double
        var duration: Double
        var gap: Double = 0
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private let sampleRate = 44_100.0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ sound: SoundID) async {
        guard let buffer = makeBuffer(Self.segments(for: sound)), prepare() else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                    continuation.resume()
                }
                node.play()
            }
        } onCancel: {
            self.node.stop()
        }
    }

    func stopAll() {
        node.stop()
    }

    /// Démarre le moteur audio si besoin. Faux si l'audio est indisponible.
    private func prepare() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if engine.isRunning { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private static func segments(for sound: SoundID) -> [Segment] {
        switch sound {
        case .beep:
            return [Segment(from: 880, to: 880, duration: 0.18)]
        case .doubleBeep:
            return [Segment(from: 880, to: 880, duration: 0.10, gap: 0.07), Segment(from: 880, to: 880, duration: 0.10)]
        case .rise:
            return [Segment(from: 300, to: 1200, duration: 0.40)]
        case .fall:
            return [Segment(from: 1200, to: 300, duration: 0.40)]
        case .success:
            return [Segment(from: 523, to: 523, duration: 0.12), Segment(from: 659, to: 659, duration: 0.12),
                    Segment(from: 784, to: 784, duration: 0.28)]
        case .error:
            return [Segment(from: 220, to: 220, duration: 0.18, gap: 0.04), Segment(from: 160, to: 150, duration: 0.35)]
        case .laser:
            return [Segment(from: 1800, to: 200, duration: 0.25)]
        case .robot:
            return [440, 620, 350, 760, 500, 290].map { Segment(from: $0, to: $0, duration: 0.07, gap: 0.01) }
        }
    }

    private func makeBuffer(_ segments: [Segment]) -> AVAudioPCMBuffer? {
        let total = segments.reduce(0.0) { $0 + $1.duration + $1.gap }
        let frameCount = AVAudioFrameCount(total * sampleRate)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        var index = 0
        var phase = 0.0
        let fade = 0.006 * sampleRate
        for segment in segments {
            let count = Int(segment.duration * sampleRate)
            for step in 0..<count where index < Int(frameCount) {
                let progress = Double(step) / Double(max(1, count))
                let frequency = segment.from + (segment.to - segment.from) * progress
                phase += 2 * Double.pi * frequency / sampleRate
                // Fondu d'entrée et de sortie pour éviter les claquements.
                let envelope = min(1, Double(step) / fade, Double(count - step) / fade)
                samples[index] = Float(sin(phase) * 0.35 * envelope)
                index += 1
            }
            let silence = Int(segment.gap * sampleRate)
            for _ in 0..<silence where index < Int(frameCount) {
                samples[index] = 0
                index += 1
            }
        }
        while index < Int(frameCount) {
            samples[index] = 0
            index += 1
        }
        return buffer
    }
}
