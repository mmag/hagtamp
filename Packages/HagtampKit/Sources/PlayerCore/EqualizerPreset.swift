import Foundation

/// Winamp's equalizer bands, in Hz.
public let equalizerFrequencies: [Double] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

/// Equalizer settings as slider positions: 0...1 per band and preamp, 0.5 = 0 dB.
public struct EqualizerPreset: Codable, Equatable, Sendable {
    public var name: String
    public var bands: [Double]
    public var preamp: Double

    public init(name: String, bands: [Double], preamp: Double) {
        precondition(bands.count == 10)
        self.name = name
        self.bands = bands
        self.preamp = preamp
    }

    /// Slider range of Winamp's classic equalizer.
    public static let maxGain = 12.0

    /// Gain in dB for a slider position.
    public static func decibels(_ position: Double) -> Double {
        (min(1, max(0, position)) - 0.5) * 2 * maxGain
    }

    public static let flat = EqualizerPreset(name: "Flat", bands: Array(repeating: 0.5, count: 10), preamp: 0.5)
}

// MARK: - Winamp's 1...64 scale

extension EqualizerPreset {
    /// Winamp stores sliders as 1 (−12 dB) ... 64 (+12 dB); 33 is its "0 dB" midline.
    static func position(winampValue value: Int) -> Double {
        Double(min(64, max(1, value)) - 1) / 63
    }

    static func winampValue(position: Double) -> Int {
        Int((min(1, max(0, position)) * 63).rounded()) + 1
    }

    init(name: String, winampBands: [Int], winampPreamp: Int) {
        self.init(
            name: name, bands: winampBands.map(Self.position(winampValue:)),
            preamp: Self.position(winampValue: winampPreamp))
    }

    /// The presets shipped with Winamp (winamp.q1), via Webamp's builtin.json (MIT).
    public static let builtIn: [EqualizerPreset] = [
        ("Classical", [33, 33, 33, 33, 33, 33, 20, 20, 20, 16], 33),
        ("Club", [33, 33, 38, 42, 42, 42, 38, 33, 33, 33], 33),
        ("Dance", [48, 44, 36, 32, 32, 22, 20, 20, 32, 32], 33),
        ("Laptop speakers/headphones", [40, 50, 41, 26, 28, 35, 40, 48, 53, 56], 33),
        ("Large hall", [49, 49, 42, 42, 33, 24, 24, 24, 33, 33], 33),
        ("Party", [44, 44, 33, 33, 33, 33, 33, 33, 44, 44], 33),
        ("Pop", [29, 40, 44, 45, 41, 30, 28, 28, 29, 29], 33),
        ("Reggae", [33, 33, 31, 22, 33, 43, 43, 33, 33, 33], 33),
        ("Rock", [45, 40, 23, 19, 26, 39, 47, 50, 50, 50], 33),
        ("Soft", [40, 35, 30, 28, 30, 39, 46, 48, 50, 52], 33),
        ("Ska", [28, 24, 25, 31, 39, 42, 47, 48, 50, 48], 33),
        ("Full Bass", [48, 48, 48, 42, 35, 25, 18, 15, 14, 14], 33),
        ("Soft Rock", [39, 39, 36, 31, 25, 23, 26, 31, 37, 47], 33),
        ("Full Treble", [16, 16, 16, 25, 37, 50, 58, 58, 58, 60], 33),
        ("Full Bass & Treble", [44, 42, 33, 20, 24, 35, 46, 50, 52, 52], 33),
        ("Live", [24, 33, 39, 41, 42, 42, 39, 37, 37, 36], 33),
        ("Techno", [45, 42, 33, 23, 24, 33, 45, 48, 48, 47], 33),
    ].map { EqualizerPreset(name: $0.0, winampBands: $0.1, winampPreamp: $0.2) }
}

// MARK: - EQF files

/// Winamp's equalizer library format (`.eqf` files and `winamp.q1`).
public enum EQFFile {
    static let header = Array("Winamp EQ library file v1.1".utf8)
    static let nameLength = 257

    public enum Failure: Error {
        case notEQF
    }

    public static func parse(_ data: Data) throws -> [EqualizerPreset] {
        let bytes = [UInt8](data)
        guard bytes.starts(with: header) else { throw Failure.notEQF }
        var at = header.count + 4  // Ctrl-Z and "!--"
        var presets: [EqualizerPreset] = []
        while at + nameLength + 11 <= bytes.count {
            let nameBytes = bytes[at..<at + nameLength].prefix { $0 != 0 }
            let name = String(data: Data(nameBytes), encoding: .windowsCP1252) ?? ""
            at += nameLength
            // Values are stored inverted: 0 is the top of the slider.
            let values = bytes[at..<at + 11].map { 64 - Int($0) }
            at += 11
            presets.append(EqualizerPreset(name: name, winampBands: Array(values[0..<10]), winampPreamp: values[10]))
        }
        return presets
    }

    public static func data(for presets: [EqualizerPreset]) -> Data {
        var bytes = header + [26] + Array("!--".utf8)
        for preset in presets {
            var name = Array((preset.name.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()).prefix(nameLength - 1))
            name += [UInt8](repeating: 0, count: nameLength - name.count)
            bytes += name
            for value in preset.bands + [preset.preamp] {
                bytes.append(UInt8(64 - EqualizerPreset.winampValue(position: value)))
            }
        }
        return Data(bytes)
    }
}
