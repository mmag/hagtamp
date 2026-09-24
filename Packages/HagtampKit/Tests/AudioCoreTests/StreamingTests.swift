import AVFAudio
import Foundation
@preconcurrency import SFBAudioEngine
import StreamingInput
import Testing

@testable import AudioCore

/// A download simulated on disk: bytes are appended to the partial file on
/// demand, then it is moved into place like the audio cache does.
final class FakeDownload: @unchecked Sendable {
    let url: URL
    let partialFile: URL
    let state = StreamState()
    private let data: Data
    private var written = 0

    init(_ file: URL) throws {
        data = try Data(contentsOf: file)
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-stream-\(UUID().uuidString).\(file.pathExtension)")
        partialFile = url.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partialFile.path, contents: nil)
        state.setExpectedLength(data.count)
    }

    var size: Int { data.count }

    func write(upTo end: Int) throws {
        let end = min(end, data.count)
        guard end > written else { return }
        let handle = try FileHandle(forWritingTo: partialFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: data[written..<end])
        try handle.close()
        state.appendedBytes(end - written)
        written = end
    }

    /// Writes the rest in small chunks, like a network download.
    func finish(chunk: Int = 8192, pause: TimeInterval = 0.002) throws {
        while written < data.count {
            try write(upTo: written + chunk)
            Thread.sleep(forTimeInterval: pause)
        }
        try FileManager.default.moveItem(at: partialFile, to: url)
        state.finishWithError(nil)
    }

    func finishInBackground(chunk: Int = 8192, pause: TimeInterval = 0.002) {
        Thread.detachNewThread { try? self.finish(chunk: chunk, pause: pause) }
    }

    func track() throws -> StreamingTrack {
        try StreamingTrack(url: url, partialFile: partialFile, state: state)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: partialFile)
    }
}

/// A 20 s tone. MP3 comes from a fixture made with the lame tool:
/// SFBAudioEngine's own MP3 encoder writes a LAME header promising more
/// frames than the file holds, which only a decoder that scans the whole
/// file (not a stream) gets past.
func encodedTone(_ fileExtension: String) throws -> URL {
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-tone-\(UUID().uuidString).\(fileExtension)")
    if fileExtension == "mp3" {
        let fixture = try #require(Bundle.module.url(forResource: "tone-20s", withExtension: "mp3", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }
    let wav = try makeTone(seconds: 20)
    defer { try? FileManager.default.removeItem(at: wav) }
    try AudioConverter.convert(wav, to: copy)
    return copy
}

/// Serialized: mpg123 sets up each decoder with a CPU probe that isn't
/// thread-safe, so MP3 decoders must not open at the same time. (In the
/// app they all open on the player's decoding thread.)
@Suite(.serialized) struct StreamingTests {}

extension StreamingTests {
@Suite struct StreamingDecodeTests {
    /// Every streamable format opens from the head of the file and decodes
    /// to the end while the rest is still arriving.
    @Test(arguments: ["mp3", "flac", "opus"])
    func decodesWhileDownloading(_ fileExtension: String) throws {
        #expect(StreamingTrack.canStream(fileExtension: fileExtension))
        let file = try encodedTone(fileExtension)
        defer { try? FileManager.default.removeItem(at: file) }
        let download = try FakeDownload(file)
        defer { download.remove() }
        try download.write(upTo: 16384)
        download.finishInBackground(chunk: 16384, pause: 0.05)

        let decoder = try download.track().decoder
        try decoder.open()  // a seekable source would make mpg123 and opusfile read to the end first
        #expect(!download.state.finished)
        #expect(!decoder.supportsSeeking)

        let format = decoder.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var frames = 0
        repeat {
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            frames += Int(buffer.frameLength)
        } while buffer.frameLength > 0
        #expect(download.state.finished)
        #expect(abs(Double(frames) / format.sampleRate - 20) < 0.1, "\(fileExtension): \(frames) frames")
    }

    @Test func completedDownloadsAreSeekable() throws {
        let file = try encodedTone("mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        let download = try FakeDownload(file)
        defer { download.remove() }
        try download.finish(pause: 0)
        let decoder = try download.track().decoder
        try decoder.open()
        #expect(decoder.supportsSeeking)
        #expect(decoder.length > 0)
    }

    @Test func cancelEndsAWaitingRead() async throws {
        let file = try encodedTone("mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        let download = try FakeDownload(file)
        defer { download.remove() }
        try download.write(upTo: download.size / 4)
        let track = try download.track()
        try track.decoder.open()

        // Decode until the reader waits for data that never comes.
        let started = Date()
        let finished = Task.detached {
            let buffer = AVAudioPCMBuffer(pcmFormat: track.decoder.processingFormat, frameCapacity: 4096)!
            repeat {
                try? track.decoder.decode(into: buffer, length: buffer.frameCapacity)
            } while buffer.frameLength > 0
            return Date()
        }
        try await Task.sleep(for: .milliseconds(300))
        track.cancel()
        let ended = await finished.value
        #expect(ended.timeIntervalSince(started) < 2)
    }
}

@Suite @MainActor struct StreamingPlaybackTests {
    @Test func playsBeforeTheDownloadCompletes() async throws {
        let file = try encodedTone("mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        let download = try FakeDownload(file)
        defer { download.remove() }
        try download.write(upTo: download.size / 10)  // two seconds

        let engine = AudioEngine()
        engine.volume = 0
        try engine.play(.stream(try download.track()))
        for _ in 0..<40 where (engine.currentTime ?? 0) < 0.2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.state == .playing)
        #expect(engine.nowPlayingURL == download.url)
        #expect(!download.state.finished)
        #expect(!engine.canSeek)

        // Playback carries on past the first part as the rest arrives.
        download.finishInBackground()
        for _ in 0..<80 where (engine.currentTime ?? 0) < 2.5 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((engine.currentTime ?? 0) >= 2.5)
        #expect(download.state.finished)
        engine.stop()
    }

    /// A stream stuck waiting for data must not hold up the next track.
    @Test func switchingAwayFromAStalledStream() async throws {
        let stalled = try encodedTone("mp3")
        let other = try makeTone(seconds: 2)
        defer {
            try? FileManager.default.removeItem(at: stalled)
            try? FileManager.default.removeItem(at: other)
        }
        let download = try FakeDownload(stalled)
        defer { download.remove() }
        try download.write(upTo: download.size / 40)  // half a second

        let engine = AudioEngine()
        engine.volume = 0
        try engine.play(.stream(try download.track()))
        try await Task.sleep(for: .milliseconds(1500))  // past the downloaded part
        try engine.play(other)
        for _ in 0..<40 where engine.nowPlayingURL != other {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.nowPlayingURL == other)
        engine.stop()
    }

    @Test func startsAFilePartWay() async throws {
        let url = try makeTone(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        engine.volume = 0
        try engine.play(url, from: 0.5)
        for _ in 0..<40 where (engine.currentTime ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((engine.currentTime ?? 0) >= 2)
        #expect(engine.canSeek)
        engine.stop()
    }
}
}
