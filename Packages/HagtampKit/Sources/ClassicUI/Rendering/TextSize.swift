import CoreGraphics

/// How big the playlist, library lists and lyrics are written: Winamp's size
/// (9 pt text in 13 px rows) or larger. Rows grow with the text.
public struct TextSize: Sendable, Equatable, Hashable {
    public var scale: Double

    public init(scale: Double) {
        self.scale = min(3, max(0.5, scale))
    }

    public static let normal = TextSize(scale: 1)

    public var fontSize: CGFloat { CGFloat(9 * scale) }
    public var rowHeight: Int { scaled(13) }
    public var headerHeight: Int { scaled(14) }

    /// A distance measured at Winamp's size, at this one.
    public func scaled(_ pixels: Int) -> Int { Int((Double(pixels) * scale).rounded()) }
}
