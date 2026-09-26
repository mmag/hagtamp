import AVFAudio
import Foundation
@preconcurrency import SFBAudioEngine
import Testing

@testable import AudioCore
import PlayerCore

/// Feeds a meter 997 Hz sines, `(seconds, dBFS)` one after the other, in buffers of 4096 frames.
private func measure(_ parts: [(seconds: Double, dBFS: Double)], sampleRate: Double = 48000, channels: Int = 2) -> LoudnessMeasurement? {
    guard var meter = LoudnessMeter(sampleRate: sampleRate, channelCount: channels) else { return nil }
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var phase = 0
    for part in parts {
        let amplitude = Float(pow(10, part.dBFS / 20))
        var left = Int(part.seconds * sampleRate)
        while left > 0 {
            let frames = min(left, 4096)
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                let sample = amplitude * Float(sin(2 * .pi * 997 * Double(phase + i) / sampleRate))
                for channel in 0..<channels { buffer.floatChannelData![channel][i] = sample }
            }
            meter.process(buffer)
            phase += frames
            left -= frames
        }
    }
    return meter.measurement
}

@Suite struct LoudnessMeterTests {
    /// EBU Tech 3341, case 1: a −23 dBFS sine in both channels reads −23 LUFS.
    @Test(arguments: [48000.0, 44100, 96000])
    func readsTheReferenceTone(_ sampleRate: Double) throws {
        let result = try #require(measure([(20, -23)], sampleRate: sampleRate))
        #expect(abs(result.loudness - -23) < 0.1, "\(sampleRate) Hz: \(result.loudness)")
        #expect(abs(result.peak - pow(10, -23.0 / 20)) < 0.001)
        #expect(abs(result.gain - 5) < 0.1)
    }

    /// Case 3: quiet stretches 13 LU down fall below the relative gate.
    @Test func gatesQuietPassages() throws {
        let result = try #require(measure([(10, -36), (60, -23), (10, -36)]))
        #expect(abs(result.loudness - -23) < 0.1, "\(result.loudness)")
        #expect(abs(result.blocks - 600) < 10, "\(result.blocks) blocks")
    }

    /// A mono file plays on both speakers: as loud as the same sound in stereo.
    @Test func monoCountsTwice() throws {
        let result = try #require(measure([(10, -23)], channels: 1))
        #expect(abs(result.loudness - -23) < 0.1, "\(result.loudness)")
    }

    @Test func silenceAndSnippetsHaveNoLoudness() {
        #expect(measure([(5, -200)]) == nil)
        #expect(measure([(0.3, -10)]) == nil)
        #expect(measure([(0.5, -10)]) != nil)
    }

    @Test func refusesFormatsItCantMeasure() {
        #expect(LoudnessMeter(sampleRate: 0, channelCount: 2) == nil)
        #expect(LoudnessMeter(sampleRate: 44100, channelCount: 0) == nil)
    }
}

/// Serialized: the MP3 fixture's tags are written and read.
@Suite(.serialized) struct LoudnessReadingTests {
    /// makeTone's sine peaks at 0.5: −6 dBFS in both channels.
    @Test func measuresAFile() throws {
        let url = try makeTone(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let reading = try #require(LoudnessReading.read(url))
        #expect(reading.tags == nil)
        let measured = try #require(reading.measured)
        #expect(abs(measured.loudness - -6.0) < 0.15, "\(measured.loudness)")
        #expect(abs(measured.peak - 0.5) < 0.01)
    }

    /// MP3 is decoded by Core Audio for measuring (mpg123 stays on the player's thread).
    @Test func measuresMP3() throws {
        let fixture = try #require(Bundle.module.url(forResource: "tone-20s", withExtension: "mp3", subdirectory: "Fixtures"))
        let measured = try #require(LoudnessReading.read(fixture)?.measured)
        #expect(abs(measured.loudness - -6.4) < 0.1, "\(measured.loudness)")  // ffmpeg's ebur128 reads −6.4
    }

    @Test func tagsSpareTheMeasuring() throws {
        let fixture = try #require(Bundle.module.url(forResource: "tone-20s", withExtension: "mp3", subdirectory: "Fixtures"))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-rg-\(UUID().uuidString).mp3")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let file = try AudioFile(readingPropertiesAndMetadataFrom: copy)
        file.metadata.replayGainTrackGain = -7.5
        file.metadata.replayGainTrackPeak = 0.9
        file.metadata.replayGainAlbumGain = -8
        file.metadata.albumTitle = "Tönes "
        file.metadata.artist = "Some Artist"
        try file.writeMetadata()

        let reading = try #require(LoudnessReading.read(copy))
        #expect(reading.tags == Loudness(trackGain: -7.5, trackPeak: 0.9, albumGain: -8))
        #expect(reading.measured == nil)
        #expect(reading.album == "some artist\u{1F}tones")
        #expect(TrackInfo.read(from: copy).replayGain == reading.tags)
    }

    @Test func unreadableFilesHaveNoReading() {
        #expect(LoudnessReading.read(URL(fileURLWithPath: "/nonexistent/song.flac")) == nil)
    }
}
