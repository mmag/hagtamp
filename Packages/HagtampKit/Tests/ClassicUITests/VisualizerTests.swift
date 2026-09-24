import Foundation
import SkinKit
import Testing

@testable import ClassicUI

@Suite struct VisualizerTests {
    let colors = VisColors.default

    func sine(frequency: Double, amplitude: Float = 0.8, count: Int = 1024) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 44100)) }
    }

    func countNonBackground(_ bitmap: Bitmap) -> Int {
        bitmap.pixels.filter { $0 != colors[0].argb && $0 != colors[1].argb }.count
    }

    @Test func silenceShowsOnlyTheGrid() {
        let vis = Visualizer()
        let frame = vis.render(samples: nil, colors: colors, settings: VisualizerSettings(), small: false)
        #expect(frame.width == 76 && frame.height == 16)
        #expect(countNonBackground(frame) == 0)
        #expect(frame[0, 1] == colors[1])  // grid dots on odd rows, even columns
        #expect(frame[1, 1] == colors[0])
    }

    @Test func analyzerShowsBarsForATone() {
        let vis = Visualizer()
        var frame = Bitmap(width: 1, height: 1)
        for _ in 0..<3 {
            frame = vis.render(samples: sine(frequency: 1000), colors: colors, settings: VisualizerSettings(), small: false)
        }
        #expect(countNonBackground(frame) > 10)
        // Thick bands leave every fourth column empty.
        #expect((0..<16).allSatisfy { frame[3, $0] == colors[0] || frame[3, $0] == colors[1] })
    }

    @Test func barsFallAfterTheSoundStops() {
        let vis = Visualizer()
        _ = vis.render(samples: sine(frequency: 1000), colors: colors, settings: VisualizerSettings(), small: false)
        let loud = countNonBackground(vis.render(samples: sine(frequency: 1000), colors: colors, settings: VisualizerSettings(), small: false))
        var quiet = loud
        for _ in 0..<120 {
            quiet = countNonBackground(vis.render(samples: nil, colors: colors, settings: VisualizerSettings(), small: false))
        }
        #expect(quiet < loud)
        #expect(quiet == 0)
    }

    @Test func oscilloscopeDrawsTheWave() {
        var settings = VisualizerSettings()
        settings.mode = .oscilloscope
        let frame = Visualizer().render(samples: sine(frequency: 440), colors: colors, settings: settings, small: false)
        let rows = Set((0..<75).compactMap { x in (0..<16).first { y in colors[18...22].contains(frame[x, y]) } })
        #expect(rows.count > 4)
    }

    @Test func smallVersionFitsShadeMode() {
        let frame = Visualizer().render(samples: sine(frequency: 1000), colors: colors, settings: VisualizerSettings(), small: true)
        #expect(frame.width == 38 && frame.height == 5)
    }

    @Test func offDrawsBackgroundOnly() {
        var settings = VisualizerSettings()
        settings.mode = .off
        let frame = Visualizer().render(samples: sine(frequency: 1000), colors: colors, settings: settings, small: false)
        #expect(countNonBackground(frame) == 0)
        #expect(settings.nextMode == .analyzer)
    }
}
