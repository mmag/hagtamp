import AVFAudio
import Foundation
import Testing

@testable import AudioCore
import PlayerCore

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

        // Band gains reach the audio too: cut every band, keep the preamp flat.
        engine.setEqualizer(enabled: true, preamp: 0.5, bands: Array(repeating: 0.5, count: 10))
        try await Task.sleep(for: .milliseconds(400))
        let flat = engine.samples.latest(1024).map(abs).max() ?? 0
        engine.setEqualizer(enabled: true, preamp: 0.5, bands: Array(repeating: 0, count: 10))
        try await Task.sleep(for: .milliseconds(400))
        let cut = engine.samples.latest(1024).map(abs).max() ?? 0
        #expect(cut < flat / 2, "bands: flat \(flat), cut \(cut)")

        engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.state == .stopped)
        #expect(events.contains { if case .nowPlaying(let u) = $0 { return u == url } else { return false } })
    }
}

extension AudioEngineTests {
    /// The loudest sample the visualizer saw lately, once the engine has had time to get there.
    private func settledPeak(_ engine: AudioEngine) async throws -> Float {
        try await Task.sleep(for: .milliseconds(600))
        return engine.samples.latest(2048).map(abs).max() ?? 0
    }

    /// Normalization gain reaches the audio (the visualizer taps it before
    /// the volume), and changes while a track plays glide in.
    @Test func appliesTrackGain() async throws {
        let url = try makeTone(seconds: 4)  // peaks at 0.5
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        engine.volume = 0
        engine.setEqualizer(enabled: false, preamp: 0.5, bands: Array(repeating: 0.5, count: 10))
        let gain = try engine.play(.file(url), gain: -20 * log10(2))
        let halved = try await settledPeak(engine)
        #expect(abs(halved - 0.25) < 0.01, "at −6 dB: \(halved)")
        #expect(gain.hasStarted)

        gain.decibels = 0
        let restored = try await settledPeak(engine)
        #expect(abs(restored - 0.5) < 0.01, "back at 0 dB: \(restored)")
        engine.stop()
    }

    /// FLAC decodes to integers: turned up past full scale, it must not wrap around.
    @Test func turnsIntegerDecodersUpWithoutWrapping() async throws {
        let url = try encodedTone("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        engine.volume = 0
        engine.setEqualizer(enabled: false, preamp: 0.5, bands: Array(repeating: 0.5, count: 10))
        try engine.play(.file(url), gain: 20 * log10(3))  // 0.5 × 3 = 1.5
        let peak = try await settledPeak(engine)
        #expect(abs(peak - 1.5) < 0.02, "\(peak)")
        engine.stop()
    }

    /// A queued track starts at its own gain, on the sample where it begins.
    @Test func queuedTracksKeepTheirOwnGain() async throws {
        let first = try makeTone(seconds: 1)
        let second = try makeTone(seconds: 3)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = AudioEngine()
        engine.volume = 0
        engine.setEqualizer(enabled: false, preamp: 0.5, bands: Array(repeating: 0.5, count: 10))
        try engine.play(.file(first), gain: 0)
        let queued = try engine.enqueue(.file(second), gain: -20 * log10(4))
        #expect(!queued.hasStarted)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(engine.nowPlayingURL?.lastPathComponent == second.lastPathComponent)
        let peak = try await settledPeak(engine)
        #expect(abs(peak - 0.125) < 0.01, "\(peak)")
        engine.stop()
    }
}

@Suite struct LocalLyricsTests {
    @Test func sidecarLRCComesFirst() throws {
        let url = try makeTone(seconds: 1)
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: lrc)
        }
        #expect(Lyrics.local(for: url) == nil)
        try "[00:00.20]made up line\n[00:00.70]another one".write(to: lrc, atomically: true, encoding: .utf8)
        let lyrics = try #require(Lyrics.local(for: url))
        #expect(lyrics.isSynced && lyrics.lines.map(\.text) == ["made up line", "another one"])
    }
}
