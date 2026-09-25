import Foundation

/// A MilkDrop preset (.milk): base values, the code blocks and up to four
/// custom waves and four custom shapes. MilkDrop 2 shader code is kept for
/// the renderer that can translate it.
public struct MilkdropPreset: Sendable {
    public struct Wave: Sendable {
        public var index: Int
        public var values: [String: Double] = [:]
        public var initCode = ""
        public var perFrame = ""
        public var perPoint = ""
        public var enabled: Bool { (values["enabled"] ?? 0) != 0 }
    }

    public struct Shape: Sendable {
        public var index: Int
        public var values: [String: Double] = [:]
        public var initCode = ""
        public var perFrame = ""
        public var enabled: Bool { (values["enabled"] ?? 0) != 0 }
    }

    public var name: String
    /// Base values by lower-cased key as written (fdecay, zoom, wave_r...).
    public var values: [String: Double] = [:]
    public var perFrameInit = ""
    public var perFrame = ""
    public var perPixel = ""
    public var waves: [Wave] = (0..<4).map { Wave(index: $0) }
    public var shapes: [Shape] = (0..<4).map { Shape(index: $0) }
    /// MilkDrop 2 pixel shaders (HLSL), nil in MilkDrop 1 presets.
    public var warpShader: String?
    public var compositeShader: String?

    public init(name: String) {
        self.name = name
    }

    public func value(_ key: String, _ fallback: Double) -> Double {
        values[key.lowercased()] ?? fallback
    }

    /// Reads a .milk file's text. Lines are "key=value"; code comes in
    /// numbered lines (per_frame_1, per_frame_2...) that join in order.
    public static func parse(_ text: String, name: String) -> MilkdropPreset {
        var preset = MilkdropPreset(name: name)
        var code: [String: [(Int, String)]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: equals)...])
            if let (block, number) = codeLine(key) {
                // Shader lines start with a backtick.
                let text = block.hasPrefix("warp") || block.hasPrefix("comp") ? String(value.drop { $0 == "`" }) : value
                code[block, default: []].append((number, text))
            } else if let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite {
                preset.store(key, number)
            }
        }
        func joined(_ block: String) -> String {
            (code[block] ?? []).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
        }
        preset.perFrameInit = joined("per_frame_init")
        preset.perFrame = joined("per_frame")
        preset.perPixel = joined("per_pixel")
        for i in 0..<4 {
            preset.waves[i].initCode = joined("wave_\(i)_init")
            preset.waves[i].perFrame = joined("wave_\(i)_per_frame")
            preset.waves[i].perPoint = joined("wave_\(i)_per_point")
            preset.shapes[i].initCode = joined("shape_\(i)_init")
            preset.shapes[i].perFrame = joined("shape_\(i)_per_frame")
        }
        let warp = joined("warp"), composite = joined("comp")
        preset.warpShader = warp.isEmpty ? nil : warp
        preset.compositeShader = composite.isEmpty ? nil : composite
        return preset
    }

    /// Base values of waves and shapes: "wavecode_0_samples", "shapecode_2_sides".
    private mutating func store(_ key: String, _ value: Double) {
        for (prefix, isWave) in [("wavecode_", true), ("shapecode_", false)] where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard let underscore = rest.firstIndex(of: "_"), let index = Int(rest[..<underscore]), (0..<4).contains(index) else { return }
            let name = String(rest[rest.index(after: underscore)...])
            if isWave { waves[index].values[name] = value } else { shapes[index].values[name] = value }
            return
        }
        values[key] = value
    }

    /// "per_frame_12" → ("per_frame", 12), "wave_1_per_point3" → ("wave_1_per_point", 3), "warp_4" → ("warp", 4).
    private static func codeLine(_ key: String) -> (String, Int)? {
        let blocks = ["per_frame_init_", "per_frame_", "per_pixel_", "warp_", "comp_"]
        for block in blocks where key.hasPrefix(block) {
            if block == "per_frame_", key.hasPrefix("per_frame_init_") { continue }
            guard let number = Int(key.dropFirst(block.count)) else { return nil }
            return (String(block.dropLast()), number)
        }
        for kind in ["wave", "shape"] where key.hasPrefix(kind + "_") {
            let rest = key.dropFirst(kind.count + 1)
            guard let underscore = rest.firstIndex(of: "_"), let index = Int(rest[..<underscore]) else { return nil }
            let tail = rest[rest.index(after: underscore)...]
            for part in ["init", "per_frame", "per_point"] where tail.hasPrefix(part) {
                guard let number = Int(tail.dropFirst(part.count)) else { continue }
                return ("\(kind)_\(index)_\(part)", number)
            }
        }
        return nil
    }
}
