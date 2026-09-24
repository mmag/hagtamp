import SkinKit

/// Pixel comparison of a render against a reference image.
public struct ImageDiff: Sendable {
    public struct Area: Sendable {
        public let name: String
        public let rect: PixelRect
        public var mismatches = 0
        public var compared = 0
    }

    public private(set) var areas: [Area]
    /// Reference, render and highlighted differences side by side.
    public private(set) var visualization: Bitmap

    public var totalMismatches: Int { areas.reduce(0) { $0 + $1.mismatches } }

    /// Compares opaque pixels exactly and transparency as visible/invisible.
    /// Semi-transparent reference pixels (anti-aliased clip edges) and
    /// `ignoring` rects are skipped.
    public init(reference: Bitmap, render: Bitmap, areas: [(String, PixelRect)], ignoring: [PixelRect] = [], tolerance: Int = 0) {
        precondition(reference.width == render.width && reference.height == render.height)
        let w = reference.width, h = reference.height
        var diff = Bitmap(width: w, height: h, fill: PixelColor(rgb: 0x202020))
        self.areas = areas.map { Area(name: $0.0, rect: $0.1) }

        for y in 0..<h {
            for x in 0..<w {
                let ref = reference[x, y], got = render[x, y]
                if ignoring.contains(where: { $0.contains(x: x, y: y) }) {
                    diff[x, y] = PixelColor(rgb: 0x000060)
                    continue
                }
                if ref.alpha != 0 && ref.alpha != 255 { continue }
                let same: Bool
                if ref.alpha == 0 || got.alpha == 0 {
                    same = ref.alpha == got.alpha
                } else {
                    same =
                        abs(Int(ref.red) - Int(got.red)) <= tolerance
                        && abs(Int(ref.green) - Int(got.green)) <= tolerance
                        && abs(Int(ref.blue) - Int(got.blue)) <= tolerance
                }
                if let i = self.areas.firstIndex(where: { $0.rect.contains(x: x, y: y) }) {
                    self.areas[i].compared += 1
                    if !same { self.areas[i].mismatches += 1 }
                }
                if !same {
                    diff[x, y] = PixelColor(rgb: 0xFF00FF)
                } else if got.alpha == 255 {
                    // Dimmed copy of the matching pixel for context.
                    diff[x, y] = PixelColor(r: got.red / 4, g: got.green / 4, b: got.blue / 4)
                }
            }
        }

        var visualization = Bitmap(width: w * 3 + 8, height: h, fill: PixelColor(rgb: 0x808080))
        visualization.draw(reference, from: reference.bounds, atX: 0, y: 0)
        visualization.draw(render, from: render.bounds, atX: w + 4, y: 0)
        visualization.draw(diff, from: diff.bounds, atX: 2 * w + 8, y: 0)
        self.visualization = visualization
    }
}
