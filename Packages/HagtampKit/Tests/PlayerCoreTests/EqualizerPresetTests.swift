import Foundation
import Testing

@testable import PlayerCore

@Suite struct EqualizerPresetTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Our built-in table must be Winamp's own preset library.
    @Test func builtInPresetsMatchWinampQ1() throws {
        let library = try EQFFile.parse(try fixture("winamp.q1"))
        #expect(library.map(\.name) == EqualizerPreset.builtIn.map(\.name))
        #expect(library == EqualizerPreset.builtIn)
    }

    @Test func extremesMapToSliderEnds() throws {
        let max = try #require(try EQFFile.parse(try fixture("max.EQF")).first)
        let min = try #require(try EQFFile.parse(try fixture("min.EQF")).first)
        #expect(max.bands.allSatisfy { $0 == 1 })
        #expect(min.bands.allSatisfy { $0 == 0 })
        #expect(EqualizerPreset.decibels(1) == 12)
        #expect(EqualizerPreset.decibels(0.5) == 0)
    }

    @Test func writingRoundTrips() throws {
        // Byte equality with winamp.q1 isn't expected: Winamp leaves junk after the names.
        let data = EQFFile.data(for: EqualizerPreset.builtIn)
        #expect(data.count == (try fixture("winamp.q1")).count)
        #expect(try EQFFile.parse(data) == EqualizerPreset.builtIn)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: EQFFile.Failure.self) { try EQFFile.parse(Data("hello".utf8)) }
    }
}
