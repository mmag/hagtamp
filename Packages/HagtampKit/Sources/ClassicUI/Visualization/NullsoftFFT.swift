import Foundation

/// The FFT used by Winamp's classic visualizer (Nullsoft's fft.cpp from
/// MilkDrop, via WACUP's vis_classic and Webamp's FFTNullsoft.ts, MIT).
///
/// 1024 windowed samples in, 512 magnitudes out, equalized on a log scale so
/// high frequencies aren't drowned out.
struct NullsoftFFT {
    static let samplesIn = 1024
    static let samplesOut = 512

    private let bitReverse: [Int]
    private let envelope: [Float]
    private let equalize: [Float]
    private let cosSin: [(Float, Float)]
    private var real = [Float](repeating: 0, count: 1024)
    private var imag = [Float](repeating: 0, count: 1024)

    init() {
        let n = Self.samplesOut * 2

        var table = Array(0..<n)
        var j = 0
        for i in 0..<n {
            if j > i { table.swapAt(i, j) }
            var m = n >> 1
            while m >= 1 && j >= m {
                j -= m
                m >>= 1
            }
            j += m
        }
        bitReverse = table

        var pairs: [(Float, Float)] = []
        var size = 2
        while size <= n {
            let theta = -2.0 * Double.pi / Double(size)
            pairs.append((Float(cos(theta)), Float(sin(theta))))
            size <<= 1
        }
        cosSin = pairs

        let mult = 1.0 / Float(Self.samplesIn) * 6.2831853
        envelope = (0..<Self.samplesIn).map { 0.5 + 0.5 * sin(Float($0) * mult - 1.5707963268) }

        var bias: Float = 0.04
        var eq = [Float](repeating: 0, count: n / 2)
        for i in 0..<(n / 2) {
            let inv = (9.0 - bias) / Float(n / 2)
            eq[i] = log10(1.0 + bias + Float(i + 1) * inv)
            bias /= 1.0025
        }
        equalize = eq
    }

    /// `wave` holds at least 1024 samples scaled like Webamp's
    /// (byte sample − 128) / 24; returns 512 magnitudes.
    mutating func spectrum(of wave: [Float]) -> [Float] {
        let n = real.count
        for i in 0..<n {
            let index = bitReverse[i]
            real[i] = index < wave.count ? wave[index] * envelope[index] : 0
            imag[i] = 0
        }

        var size = 2
        var t = 0
        while size <= n {
            let (wpr, wpi) = cosSin[t]
            var wr: Float = 1, wi: Float = 0
            let half = size >> 1
            for m in 0..<half {
                var i = m
                while i < n {
                    let j = i + half
                    let tr = wr * real[j] - wi * imag[j]
                    let ti = wr * imag[j] + wi * real[j]
                    real[j] = real[i] - tr
                    imag[j] = imag[i] - ti
                    real[i] += tr
                    imag[i] += ti
                    i += size
                }
                let w = wr
                wr = wr * wpr - wi * wpi
                wi = wi * wpr + w * wpi
            }
            size <<= 1
            t += 1
        }

        return (0..<Self.samplesOut).map { i in
            (real[i] * real[i] + imag[i] * imag[i]).squareRoot() * equalize[i]
        }
    }
}
