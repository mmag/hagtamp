import Foundation
import Testing

@testable import PlayerCore

@Suite struct NormalizationTests {
    /// −16 LUFS is 2 dB above ReplayGain's reference.
    let normalization = Normalization(target: -16)

    @Test func loudTracksComeDownToTheTarget() {
        let loud = Loudness(trackGain: -9, trackPeak: 1)
        #expect(normalization.gain(for: loud, album: false, typicalGain: nil) == -7)
    }

    @Test func quietTracksGoUpNoFurtherThanTheirPeak() {
        let quiet = Loudness(trackGain: 6, trackPeak: 0.5)  // 0.5 leaves 6.02 dB of headroom
        #expect(abs(normalization.gain(for: quiet, album: false, typicalGain: nil) - 20 * log10(2)) < 1e-9)
        let quieter = Loudness(trackGain: 2, trackPeak: 0.5)
        #expect(normalization.gain(for: quieter, album: false, typicalGain: nil) == 4)
        // No peak: no turning up.
        #expect(normalization.gain(for: Loudness(trackGain: 3), album: false, typicalGain: nil) == 0)
        #expect(normalization.gain(for: Loudness(trackGain: -5), album: false, typicalGain: nil) == -3)
    }

    @Test func albumGainKeepsTheAlbumsOwnBalance() {
        let track = Loudness(trackGain: 1, trackPeak: 0.9, albumGain: -6, albumPeak: 1)
        #expect(normalization.gain(for: track, album: true, typicalGain: nil) == -4)
        #expect(abs(normalization.gain(for: track, album: false, typicalGain: nil) - -20 * log10(0.9)) < 1e-9)
        // Without an album gain the track's own counts.
        let single = Loudness(trackGain: -10, trackPeak: 1)
        #expect(normalization.gain(for: single, album: true, typicalGain: nil) == -8)
    }

    @Test func unknownTracksGetTheTypicalGainAndNeverGoUp() {
        #expect(normalization.gain(for: nil, album: false, typicalGain: -9) == -7)
        #expect(normalization.gain(for: nil, album: false, typicalGain: nil) == Normalization.usualGain + 2)
        #expect(normalization.gain(for: nil, album: false, typicalGain: 4) == 0)
    }

    @Test func offMeansUntouched() {
        var off = normalization
        off.enabled = false
        #expect(off.gain(for: Loudness(trackGain: -9, trackPeak: 1), album: false, typicalGain: nil) == 0)
        #expect(off.gain(for: nil, album: false, typicalGain: -9) == 0)
    }

    @Test func automaticModeUsesAlbumGainForAlbumsInOrder() {
        #expect(normalization.usesAlbumGain(shuffle: false, continuesAlbum: true))
        #expect(!normalization.usesAlbumGain(shuffle: true, continuesAlbum: true))
        #expect(!normalization.usesAlbumGain(shuffle: false, continuesAlbum: false))
        #expect(Normalization(mode: .album).usesAlbumGain(shuffle: true, continuesAlbum: false))
        #expect(!Normalization(mode: .track).usesAlbumGain(shuffle: false, continuesAlbum: true))
    }

    @Test func taggedValuesOutOfReasonAreMissing() {
        #expect(Loudness(tagged: nil, trackPeak: 1, albumGain: -3, albumPeak: 1) == nil)
        #expect(Loudness(tagged: .nan, trackPeak: 1, albumGain: nil, albumPeak: nil) == nil)
        let odd = Loudness(tagged: -7, trackPeak: 0, albumGain: 900, albumPeak: -1)
        #expect(odd == Loudness(trackGain: -7))
    }
}

@Suite struct LoudnessIndexTests {
    @Test func tracksCombineIntoTheirAlbum() throws {
        var index = LoudnessIndex()
        index["/a/1.flac"] = .init(measured: LoudnessMeasurement(loudness: -10, blocks: 100, peak: 0.9), album: "a")
        #expect(index.loudness(for: "/a/1.flac") == Loudness(trackGain: -8, trackPeak: 0.9, albumGain: -8, albumPeak: 0.9))

        // A quieter track as long again: the album's energy is the mean of the two.
        index["/a/2.flac"] = .init(measured: LoudnessMeasurement(loudness: -20, blocks: 100, peak: 0.5), album: "a")
        let album = 10 * log10((pow(10, -1.0) + pow(10, -2.0)) / 2)
        let second = try #require(index.loudness(for: "/a/2.flac"))
        #expect(second.trackGain == 2)
        #expect(abs((second.albumGain ?? 0) - (-18 - album)) < 1e-9)
        #expect(second.albumPeak == 0.9)
        #expect(index.loudness(for: "/a/1.flac")?.albumGain == second.albumGain)

        // A track leaving the album takes its share along.
        index["/a/2.flac"] = nil
        #expect(index.loudness(for: "/a/1.flac")?.albumGain == -8)
        #expect(index.loudness(for: "/a/2.flac") == nil)
    }

    @Test func tagsWinOverMeasuring() {
        var index = LoudnessIndex()
        let tags = Loudness(trackGain: -3.5, trackPeak: 0.99, albumGain: -4, albumPeak: 1)
        index["x"] = .init(tags: tags, measured: LoudnessMeasurement(loudness: -9, blocks: 10, peak: 1), album: "b")
        #expect(index.loudness(for: "x") == tags)
    }

    @Test func typicalGainIsTheMedian() {
        var index = LoudnessIndex()
        #expect(index.typicalGain == nil)
        for (i, loudness) in [-8.0, -9, -14, -30].enumerated() {
            index["\(i)"] = .init(measured: LoudnessMeasurement(loudness: loudness, blocks: 1, peak: 1))
        }
        #expect(index.typicalGain == -18 - (-9.0 + -14) / 2)
    }

    @Test func recordsKnowWhenTheirFileChanged() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let record = LoudnessIndex.Record(size: 10, modified: date)
        #expect(record.matches(size: 10, modified: date.addingTimeInterval(0.0000005)))
        #expect(!record.matches(size: 11, modified: date))
        #expect(!record.matches(size: 10, modified: date.addingTimeInterval(1)))
        #expect(LoudnessIndex.Record().matches(size: nil, modified: nil))
    }

    @Test func savesAndLoads() throws {
        var index = LoudnessIndex()
        index["/a/1.mp3"] = .init(
            measured: LoudnessMeasurement(loudness: -11.25, blocks: 1800, peak: 0.97), album: "a", size: 4_000_000,
            modified: Date(timeIntervalSince1970: 1_700_000_000.123456))
        index["nd:me@server:song1"] = .init(tags: Loudness(trackGain: -6.1, trackPeak: 1.02))
        let loaded = try JSONDecoder().decode(LoudnessIndex.self, from: JSONEncoder().encode(index))
        #expect(loaded.records == index.records)
        #expect(loaded.loudness(for: "/a/1.mp3")?.albumGain == index.loudness(for: "/a/1.mp3")?.albumGain)
    }

    @Test func combiningNothingIsNothing() {
        #expect(LoudnessMeasurement.combined([]) == nil)
        #expect(LoudnessMeasurement.combined([LoudnessMeasurement(loudness: -10, blocks: 0, peak: 1)]) == nil)
    }
}
