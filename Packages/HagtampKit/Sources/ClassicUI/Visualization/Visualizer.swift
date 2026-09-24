import Foundation
import SkinKit

/// Options of Winamp's classic visualizer (Options > Visualization in the
/// main window's right-click menu). Defaults are those of a fresh Winamp.
public struct VisualizerSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case analyzer, oscilloscope, off }
    public enum AnalyzerStyle: String, Codable, CaseIterable, Sendable { case normal, fire, line }
    public enum BandWidth: String, Codable, CaseIterable, Sendable { case thick, thin }
    public enum Falloff: String, Codable, CaseIterable, Sendable { case slower, slow, moderate, fast, faster }
    public enum OscilloscopeStyle: String, Codable, CaseIterable, Sendable { case dots, lines, solid }

    public var mode = Mode.analyzer
    public var analyzerStyle = AnalyzerStyle.normal
    public var bandWidth = BandWidth.thick
    public var peaks = true
    public var barFalloff = Falloff.moderate
    public var peakFalloff = Falloff.slow
    public var oscilloscopeStyle = OscilloscopeStyle.lines

    public init() {}

    /// Clicking the visualizer cycles analyzer → oscilloscope → off.
    public var nextMode: Mode {
        switch mode {
        case .analyzer: .oscilloscope
        case .oscilloscope: .off
        case .off: .analyzer
        }
    }

    var barFalloffSpeed: Float {
        switch barFalloff {
        case .slower: 3
        case .slow: 6
        case .moderate: 12
        case .fast: 16
        case .faster: 32
        }
    }

    var peakFalloffFactor: Float {
        switch peakFalloff {
        case .slower: 1.05
        case .slow: 1.1
        case .moderate: 1.2
        case .fast: 1.4
        case .faster: 1.6
        }
    }
}

/// Winamp's classic spectrum analyzer and oscilloscope.
///
/// A port of Webamp's VisPainter.ts (MIT), which was matched against the
/// Winamp 2.63 and 5.666 executables. Keeps bar and peak state between
/// frames, so render once per display frame (~60 Hz).
public final class Visualizer {
    public static let size = (width: 76, height: 16)
    /// The main window's shade mode shows a 38x5 version.
    public static let smallSize = (width: 38, height: 5)

    private var fft = NullsoftFFT()
    private var barFalloff = [Float](repeating: 0, count: 76)
    private var peaks = [Int16](repeating: 0, count: 76)
    private var peakSpeed = [Float](repeating: 0, count: 76)

    public init() {}

    /// Renders one frame. `samples`: the most recent mono samples in −1...1
    /// (1024 are used), or nil for silence.
    public func render(samples: [Float]?, colors: [PixelColor], settings: VisualizerSettings, small: Bool) -> Bitmap {
        let (width, height) = small ? Self.smallSize : Self.size
        var canvas = Bitmap(width: width, height: height, fill: colors[0])
        if !small {
            for x in stride(from: 0, to: width, by: 2) {
                for y in stride(from: 1, to: height, by: 2) { canvas[x, y] = colors[1] }
            }
        }
        let bytes = (samples ?? []).suffix(NullsoftFFT.samplesIn).map { s -> UInt8 in
            s.isFinite ? UInt8(min(255, max(0, 128 + s * 128))) : 128
        }
        let padded = [UInt8](repeating: 128, count: max(0, NullsoftFFT.samplesIn - bytes.count)) + bytes

        switch settings.mode {
        case .analyzer: paintAnalyzer(&canvas, padded, colors, settings, small: small)
        case .oscilloscope: paintOscilloscope(&canvas, padded, colors, settings, small: small)
        case .off: break
        }
        return canvas
    }

    // MARK: - Analyzer

    private func paintAnalyzer(_ canvas: inout Bitmap, _ bytes: [UInt8], _ colors: [PixelColor], _ settings: VisualizerSettings, small: Bool) {
        let spectrum = fft.spectrum(of: bytes.map { (Float($0) - 128) / 24 })
        let targetSize = small ? 40 : 75
        let maxHeight: Float = small ? 5 : 15
        let maxWidth = small ? 37 : 75
        let pushDown = small ? 0 : 2
        let height = canvas.height

        // Blend of linear and logarithmic frequency mapping, like modern Winamp.
        let maxIndex = NullsoftFFT.samplesOut
        let logMax = log10(Float(maxIndex))
        let scale: Float = 0.91
        var sample = [Float](repeating: 0, count: 76)
        for x in 0..<targetSize {
            let linear = Float(x) / Float(targetSize - 1) * Float(maxIndex - 1)
            let logarithmic = pow(10, logMax * Float(x) / Float(targetSize - 1))
            let index = (1 - scale) * linear + scale * logarithmic
            let i1 = min(maxIndex - 1, Int(index.rounded(.down)))
            let i2 = min(maxIndex - 1, Int(index.rounded(.up)))
            let fraction = index - Float(i1)
            sample[x] = i1 == i2 ? spectrum[i1] : (1 - fraction) * spectrum[i1] + fraction * spectrum[i2]
        }

        let thick = settings.bandWidth == .thick
        for x in 0..<maxWidth {
            let chunk = thick ? x & ~3 : 0
            // Webamp stores these in Int16 arrays: values truncate toward zero.
            var data: Float
            if thick {
                data = Float(Int16(clamping: Int((sample[chunk] + sample[chunk + 1] + sample[chunk + 2] + sample[chunk + 3]) / 4)))
            } else {
                data = Float(Int16(clamping: Int(sample[x])))
            }
            data = min(data, maxHeight)
            peaks[x] = min(peaks[x], Int16(maxHeight * 256))

            barFalloff[x] -= settings.barFalloffSpeed / 16
            if barFalloff[x] <= data { barFalloff[x] = data }
            if Float(peaks[x]) <= (barFalloff[x] * 256).rounded() {
                peaks[x] = Int16(clamping: Int(barFalloff[x] * 256))
                peakSpeed[x] = 3
            }
            var barPeak = Int(peaks[x] / 256)
            peaks[x] = max(0, peaks[x] - Int16(peakSpeed[x].rounded()))
            peakSpeed[x] *= settings.peakFalloffFactor
            if !small && barPeak < 1 { barPeak = -3 }  // hide resting peaks below the view

            if thick && x == chunk + 3 { continue }  // gap between thick bars
            let barHeight = Int(barFalloff[x].rounded()) - pushDown
            paintBar(&canvas, x: x, barHeight: barHeight, colors: colors, settings: settings, small: small, pushDown: pushDown)
            if settings.peaks {
                let y = height - (barPeak + 1 - pushDown)
                if y >= 0 && y < height { canvas[x, y] = colors[23] }
            }
        }
    }

    private func paintBar(_ canvas: inout Bitmap, x: Int, barHeight: Int, colors: [PixelColor], settings: VisualizerSettings, small: Bool, pushDown: Int) {
        let height = canvas.height
        let top = max(0, height - barHeight)
        guard top < height else { return }
        // Colour of canvas row `row` in normal style.
        func gradient(_ row: Int) -> PixelColor {
            if small {
                let smallColors = [colors[17], colors[14], colors[11], colors[8], colors[4]]
                return smallColors[max(0, min(4, 4 - row))]
            }
            return colors[max(0, min(23, 2 - pushDown + row))]
        }
        for y in top..<height {
            switch settings.analyzerStyle {
            case .normal:
                canvas[x, y] = gradient(y)
            case .fire:
                // The gradient starts at the top of each bar (red tip).
                canvas[x, y] = small ? gradient(y - top) : colors[min(17, 2 + y - top)]
            case .line:
                // The whole bar in the colour of its height.
                canvas[x, y] = small ? gradient(top) : colors[min(17, 2 + top)]
            }
        }
    }

    // MARK: - Oscilloscope

    private func paintOscilloscope(_ canvas: inout Bitmap, _ bytes: [UInt8], _ colors: [PixelColor], _ settings: VisualizerSettings, small: Bool) {
        let data = Array(bytes.prefix(576))
        let sliceWidth = data.count / 75
        let pushDown = small ? 0 : 2
        let renderHeight = small ? 5 : 16
        var lastY = 0

        func colorIndex(_ y: Int) -> Int {
            if small { return 0 }
            switch y {
            case 14...: return 4
            case 12...: return 3
            case 10...: return 2
            case 8...: return 1
            case 6...: return 0
            case 4...: return 1
            case 2...: return 2
            default: return 3
            }
        }

        for x in 0...75 {
            guard x < (small ? 38 : 75) else { break }
            var y = Int((Double(data[x * sliceWidth]) / 16 * 2).rounded()) - 9
            if small {
                y -= 5
                y = Int((Double(y + 11) / 16 * 5).rounded()) - 2
            }
            y = max(0, min(renderHeight - 1, y))
            let value = y
            if x == 0 { lastY = y }
            var top = y, bottom = lastY
            lastY = y

            switch settings.oscilloscopeStyle {
            case .solid:
                let middle = small ? 2 : 8
                if y >= middle {
                    top = middle
                    bottom = y
                } else {
                    top = y
                    bottom = small ? 2 : 7
                }
                if x == 0 && small {
                    top = y
                    bottom = y
                }
            case .dots:
                top = y
                bottom = y
            case .lines:
                if bottom < top {
                    swap(&top, &bottom)
                    if !small { top += 1 }
                }
            }
            guard top <= bottom else { continue }
            for row in top...bottom {
                let py = row + pushDown
                if py >= 0 && py < canvas.height { canvas[x, py] = colors[18 + colorIndex(value)] }
            }
        }
    }
}
