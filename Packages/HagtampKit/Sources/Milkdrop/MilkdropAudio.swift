import Accelerate
import Foundation

/// The sound of one frame as presets see it: the waveform, the spectrum, and
/// bass/mid/treble relative to their recent average (1 = as loud as lately,
/// above 1 on a beat), with smoother "att" versions.
public struct MilkdropAudio: Sendable {
    /// 576 samples, -1...1.
    public var waveform: [Float]
    /// 512 bins, low to high.
    public var spectrum: [Float]
    public var bass = 1.0, mid = 1.0, treb = 1.0
    public var bassAtt = 1.0, midAtt = 1.0, trebAtt = 1.0

    public static let silence = MilkdropAudio(waveform: Array(repeating: 0, count: 576), spectrum: Array(repeating: 0, count: 512))

    public var volume: Double { (bass + mid + treb) / 3 }
    public var volumeAtt: Double { (bassAtt + midAtt + trebAtt) / 3 }
}

/// Turns the player's samples into `MilkdropAudio`, frame by frame.
public final class MilkdropAudioAnalyzer: @unchecked Sendable {
    private let size = 1024
    private let setup: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private var average = [Double](repeating: 0, count: 3)
    private var attenuated = [Double](repeating: 1, count: 3)

    public init() {
        setup = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
    }

    /// `samples`: the latest 1024 or so; `dt`: seconds since the last frame.
    public func analyze(_ samples: [Float], dt: Double) -> MilkdropAudio {
        var input = Array(samples.suffix(size))
        if input.count < size { input = Array(repeating: 0, count: size - input.count) + input }
        let waveform = Array(input.suffix(576))

        var spectrum = [Float](repeating: 0, count: size / 2)
        if let setup {
            let windowed = vDSP.multiply(input, window)
            var real = [Float](repeating: 0, count: size / 2), imaginary = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    windowed.withUnsafeBufferPointer { samples in
                        samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    setup.forward(input: split, output: &split)
                    vDSP.absolute(split, result: &spectrum)
                }
            }
            vDSP.multiply(1 / Float(size), spectrum, result: &spectrum)
        }

        // Bands at 44.1 kHz with 43 Hz bins: bass to 250 Hz, mid to 2 kHz, treble to 11 kHz.
        let bands = [1..<6, 6..<47, 47..<256]
        var result = MilkdropAudio(waveform: waveform, spectrum: spectrum)
        var values = [Double](repeating: 1, count: 3)
        let frames = max(0.001, dt) * 30  // the original tuned its smoothing at 30 fps
        for (i, band) in bands.enumerated() {
            let now = Double(spectrum[band].reduce(0, +))
            // A slow average makes 1 mean "as loud as lately"; silence reads as 0.
            let rate = average[i] == 0 ? 1 : 1 - pow(0.992, frames)
            average[i] += (now - average[i]) * rate
            values[i] = average[i] > 1e-6 ? min(8, now / average[i]) : 0
            let attack = 1 - pow(values[i] > attenuated[i] ? 0.2 : 0.5, frames)
            attenuated[i] += (values[i] - attenuated[i]) * attack
        }
        (result.bass, result.mid, result.treb) = (values[0], values[1], values[2])
        (result.bassAtt, result.midAtt, result.trebAtt) = (attenuated[0], attenuated[1], attenuated[2])
        return result
    }
}
