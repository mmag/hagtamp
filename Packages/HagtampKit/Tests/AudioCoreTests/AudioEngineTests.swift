import AVFAudio
import Foundation
import Testing

@testable import AudioCore

/// Writes a stereo 16-bit WAV with a sine tone.
func makeTone(seconds: Double = 1, frequency: Double = 1000, sampleRate: Double = 44100) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-tone-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) { data[i] = 0.5 * Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) }
    }
    try file.write(from: buffer)
    return url
}

@Suite struct TrackInfoTests {
    @Test func readsStreamProperties() throws {
        let url = try makeTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = TrackInfo.read(from: url)
        #expect(abs((info.duration ?? 0) - 2) < 0.01)
        #expect(info.sampleRate == 44100)
        #expect(info.channels == 2)
        #expect(info.displayName == url.deletingPathExtension().lastPathComponent)
    }

    @Test func unreadableFilesStillHaveAName() {
        let info = TrackInfo.read(from: URL(fileURLWithPath: "/nonexistent/Some Song.mp3"))
        #expect(info.displayName == "Some Song")
        #expect(info.duration == nil)
    }
}

@Suite(.serialized) @MainActor struct AudioEngineTests {
    @Test func playsAndFeedsTheVisualizer() async throws {
        let url = try makeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        engine.volume = 0  // silent: the visualizer tap sits before the volume stage
        var events: [AudioEngine.Event] = []
        engine.onEvent = { events.append($0) }
        try engine.play(url)

        var peak: Float = 0
        for _ in 0..<40 where peak < 0.1 {
            try await Task.sleep(for: .milliseconds(50))
            peak = engine.samples.latest(1024).map(abs).max() ?? 0
        }
        #expect(engine.state == .playing)
        #expect(peak > 0.3)
        #expect(engine.nowPlayingURL?.lastPathComponent == url.lastPathComponent)
        #expect((engine.totalTime ?? 0) > 2.9)

        // The equalizer's preamp scales what the visualizer sees.
        engine.setEqualizer(enabled: true, preamp: 0, bands: Array(repeating: 0.5, count: 10))
        try await Task.sleep(for: .milliseconds(400))
        let attenuated = engine.samples.latest(1024).map(abs).max() ?? 0
        #expect(attenuated < peak / 2)

        engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.state == .stopped)
        #expect(events.contains { if case .nowPlaying(let u) = $0 { return u == url } else { return false } })
    }
}
