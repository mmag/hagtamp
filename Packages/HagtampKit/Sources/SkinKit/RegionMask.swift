extension SkinRegions {
    /// Rasterizes polygons into a per-pixel mask (row-major, `true` = visible).
    ///
    /// A pixel is inside when its centre is, using the non-zero winding rule.
    /// For the integer coordinates of region.txt this matches GDI regions:
    /// the rectangle (0,0)-(275,116) covers exactly 275x116 pixels.
    public static func mask(_ polygons: [Polygon], width: Int, height: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        var crossings: [(x: Double, winding: Int)] = []
        for y in 0..<height {
            let cy = Double(y) + 0.5
            crossings.removeAll(keepingCapacity: true)
            for polygon in polygons {
                for i in polygon.indices {
                    let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                    let (ay, by) = (Double(a.y), Double(b.y))
                    guard (ay <= cy) != (by <= cy) else { continue }
                    let t = (cy - ay) / (by - ay)
                    crossings.append((Double(a.x) + t * Double(b.x - a.x), ay < by ? 1 : -1))
                }
            }
            crossings.sort { $0.x < $1.x }
            var winding = 0
            for (i, crossing) in crossings.enumerated() {
                winding += crossing.winding
                guard winding != 0, i + 1 < crossings.count else { continue }
                // Pixels whose centres lie between this crossing and the next.
                let start = max(0, Int((crossing.x - 0.5).rounded(.up)))
                let end = min(width, Int((crossings[i + 1].x - 0.5).rounded(.up)))
                if start < end {
                    for x in start..<end { mask[y * width + x] = true }
                }
            }
        }
        return mask
    }
}

extension Bitmap {
    /// Makes pixels outside `mask` fully transparent.
    public mutating func apply(mask: [Bool]) {
        precondition(mask.count == pixels.count)
        for i in pixels.indices where !mask[i] { pixels[i] = 0 }
    }
}
