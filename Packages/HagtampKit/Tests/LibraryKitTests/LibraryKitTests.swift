import AVFAudio
import Foundation
@preconcurrency import SFBAudioEngine
import os
import Testing

@testable import LibraryKit

private func entry(
    _ path: String, title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
    track: Int? = nil, disc: Int? = nil, year: Int? = nil, added: TimeInterval = 0
) -> LibraryEntry {
    var entry = LibraryEntry(url: URL(fileURLWithPath: path), added: Date(timeIntervalSince1970: added))
    entry.title = title
    entry.artist = artist
    entry.album = album
    entry.albumArtist = albumArtist
    entry.trackNumber = track
    entry.discNumber = disc
    entry.year = year
    return entry
}

@Suite struct LibraryCatalogTests {
    let catalog = LibraryCatalog([
        // Two discs in subfolders make one album.
        entry("/m/Alpha/Best/CD2/01.flac", title: "Four", artist: "Alpha", album: "Best", track: 1, disc: 2, year: 1999, added: 10),
        entry("/m/Alpha/Best/CD1/02.flac", title: "Two", artist: "Alpha", album: "Best", track: 2, disc: 1, year: 1999, added: 10),
        entry("/m/Alpha/Best/CD1/01.flac", title: "One", artist: "Alpha", album: "Best", track: 1, disc: 1, year: 1999, added: 10),
        // A compilation without album artist tags.
        entry("/m/Hits/01.mp3", title: "Song B", artist: "Beta", album: "Hits", track: 1, added: 30),
        entry("/m/Hits/02.mp3", title: "Song C", artist: "Björk", album: "Hits", track: 2, added: 30),
        // The album artist tag wins over the track artist.
        entry("/m/Gamma/01.mp3", title: "Duet", artist: "Gamma feat. Delta", album: "Pairs", albumArtist: "Gamma", added: 20),
        // Nothing tagged.
        entry("/m/loose/Some File.mp3", added: 5),
    ])

    @Test func groupsArtistsAndAlbums() {
        #expect(catalog.artists.map(\.name) == ["Alpha", "Gamma", LibraryCatalog.unknownArtist, LibraryCatalog.variousArtists])
        #expect(catalog.albums.count == 4)
        let alpha = catalog.artists[0]
        #expect(alpha.albumCount == 1)
        let best = catalog.albums(ofArtist: alpha.id)[0]
        #expect(best.name == "Best" && best.year == 1999)
        #expect(catalog.tracks(ofAlbum: best.id).map(\.displayTitle) == ["One", "Two", "Four"])
        let hits = catalog.albums.first { $0.name == "Hits" }
        #expect(hits?.artist == LibraryCatalog.variousArtists)
        #expect(catalog.albums.contains { $0.name == "Pairs" && $0.artist == "Gamma" })
        let loose = catalog.albums.first { $0.artist == LibraryCatalog.unknownArtist }
        #expect(loose?.name == LibraryCatalog.unknownAlbum)
        #expect(catalog.tracks(ofAlbum: loose!.id).first?.displayTitle == "Some File")
    }

    @Test func recentlyAddedComesNewestFirst() {
        #expect(catalog.recentlyAdded.map(\.name) == ["Hits", "Pairs", "Best", LibraryCatalog.unknownAlbum])
    }

    @Test func searchIgnoresCaseAndAccents() {
        let found = catalog.search("bjork song")
        #expect(found.tracks.map(\.displayTitle) == ["Song C"])
        #expect(catalog.search("ALPHA").artists.map(\.name) == ["Alpha"])
        #expect(catalog.search("hits").albums.map(\.name) == ["Hits"])
        #expect(catalog.search("   ").tracks.isEmpty)
    }

    @Test func yearsFromDates() {
        #expect(LibraryEntry.year(from: "1987") == 1987)
        #expect(LibraryEntry.year(from: "1987-05-01T00:00:00Z") == 1987)
        #expect(LibraryEntry.year(from: "87") == nil)
    }
}

final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func add() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// Real files: FLAC with tags, in a temporary folder.
@Suite struct LocalLibraryTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-library-\(UUID().uuidString)")
    var music: URL { folder.appendingPathComponent("Music") }
    var index: URL { folder.appendingPathComponent("library.json") }

    @discardableResult
    func makeTrack(_ path: String, title: String, artist: String, album: String, track: Int) throws -> URL {
        let url = music.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: wav, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410)!
            buffer.frameLength = 4410
            try file.write(from: buffer)
        }
        try AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        try retag(url, title: title, artist: artist, album: album, track: track)
        return url
    }

    func retag(_ url: URL, title: String, artist: String, album: String, track: Int) throws {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.title = title
        file.metadata.artist = artist
        file.metadata.albumTitle = album
        file.metadata.trackNumber = track
        try file.writeMetadata()
    }

    /// Opens a library on `index` and counts the files whose tags it reads.
    func open(_ folders: [URL]) async -> (LocalLibrary, Counter) {
        let library = LocalLibrary(indexFile: index)
        let reads = Counter()
        await library.observeReads { _ in reads.add() }
        await library.open(folders: folders)
        await library.waitForScan()
        return (library, reads)
    }

    @Test func scansIncrementallyAndRemembers() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeTrack("Alpha/Vol 1/01.flac", title: "One", artist: "Alpha", album: "Vol 1", track: 1)
        let second = try makeTrack("Alpha/Vol 1/02.flac", title: "Two", artist: "Alpha", album: "Vol 1", track: 2)
        try makeTrack("Beta/B/01.flac", title: "Bee", artist: "Beta", album: "B", track: 1)
        try Data("not audio".utf8).write(to: music.appendingPathComponent("notes.txt"))

        let (library, reads) = await open([music])
        var catalog = await library.catalog
        #expect(reads.value == 3)
        #expect(catalog.trackCount == 3)
        #expect(catalog.artists.map(\.name) == ["Alpha", "Beta"])
        let vol1 = try #require(catalog.albums.first { $0.name == "Vol 1" })
        #expect(catalog.tracks(ofAlbum: vol1.id).map(\.title) == ["One", "Two"])
        #expect(catalog.tracks(ofAlbum: vol1.id).first?.duration.map { abs($0 - 0.1) < 0.01 } == true)

        // Nothing changed: nothing reread.
        await library.rescan()
        await library.waitForScan()
        #expect(reads.value == 3)

        // One file retagged, one deleted: only the changed one is read.
        try await Task.sleep(for: .milliseconds(1100))  // a later modification date
        try retag(second, title: "Two (Remix)", artist: "Alpha", album: "Vol 1", track: 2)
        try FileManager.default.removeItem(at: music.appendingPathComponent("Beta/B/01.flac"))
        await library.rescan()
        await library.waitForScan()
        catalog = await library.catalog
        #expect(reads.value == 4)
        #expect(catalog.artists.map(\.name) == ["Alpha"])
        #expect(catalog.tracks(ofAlbum: vol1.id).map(\.title) == ["One", "Two (Remix)"])

        // A new session starts from the saved index and rereads nothing.
        let (reopened, rereads) = await open([music])
        #expect(await reopened.catalog.trackCount == 2)
        #expect(rereads.value == 0)
    }

    @Test func watcherNoticesNewFiles() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let calls = Counter()
        let watcher = FolderWatcher([music], latency: 0.2) { calls.add() }
        try await Task.sleep(for: .milliseconds(300))
        try makeTrack("New/01.flac", title: "New", artist: "N", album: "N", track: 1)
        for _ in 0..<50 where calls.value == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(calls.value > 0)
        withExtendedLifetime(watcher) {}
    }

    /// Only audio files and folders matter; other files and ignored folders (the app's own) don't.
    @Test func watcherIgnoresWhatIsntMusic() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = music.appendingPathComponent("AppData")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let calls = Counter()
        let watcher = FolderWatcher([music], latency: 0.2, extensions: ["flac"], ignoring: [own]) { calls.add() }
        // FSEvents may still report the folders just created; count from here.
        try await Task.sleep(for: .milliseconds(800))
        let before = calls.value
        try Data("settings".utf8).write(to: music.appendingPathComponent("notes.txt"))
        try Data("cache".utf8).write(to: own.appendingPathComponent("song.flac"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(calls.value == before)
        try makeTrack("New/01.flac", title: "New", artist: "N", album: "N", track: 1)
        for _ in 0..<50 where calls.value == before { try await Task.sleep(for: .milliseconds(100)) }
        #expect(calls.value > before)
        withExtendedLifetime(watcher) {}
    }

    /// A folder that is missing at a scan (a disk not mounted) keeps its tracks.
    @Test func unreachableFolderKeepsItsFiles() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeTrack("Disk/01.flac", title: "One", artist: "A", album: "A", track: 1)
        let disk = music.appendingPathComponent("Disk"), away = music.appendingPathComponent("Away")
        let (library, _) = await open([disk])
        #expect(await library.catalog.trackCount == 1)
        try FileManager.default.moveItem(at: disk, to: away)
        await library.rescan()
        await library.waitForScan()
        #expect(await library.catalog.trackCount == 1)
        try FileManager.default.moveItem(at: away, to: disk)
    }

    @Test func removingAFolderDropsItsFiles() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeTrack("A/01.flac", title: "A1", artist: "A", album: "A", track: 1)
        try makeTrack("B/01.flac", title: "B1", artist: "B", album: "B", track: 1)
        let (library, _) = await open([music.appendingPathComponent("A"), music.appendingPathComponent("B")])
        #expect(await library.catalog.trackCount == 2)
        await library.setFolders([music.appendingPathComponent("B")])
        #expect(await library.catalog.artists.map(\.name) == ["B"])
        await library.waitForScan()
        #expect(await library.catalog.trackCount == 1)
    }
}
