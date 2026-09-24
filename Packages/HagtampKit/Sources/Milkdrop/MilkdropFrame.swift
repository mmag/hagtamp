import Foundation

/// Everything the renderer needs for one frame, computed without the GPU.
///
/// Positions are in 0...1 with y up (0,0 = bottom left); texture
/// coordinates are 0...1 with v down, like the feedback texture.
public struct MilkdropFrame: Sendable {
    /// The warp mesh: `(meshWidth + 1) x (meshHeight + 1)` texture
    /// coordinates, row by row from the top, saying where each point of the
    /// new frame samples the previous one.
    public var meshWidth: Int
    public var meshHeight: Int
    public var warp: [SIMD2<Float>]
    /// Brightness kept from the previous frame (0.98: trails fade slowly).
    public var decay: Float = 0.98
    /// Sampling past the edges wraps around instead of repeating the edge.
    public var wrap = true
    /// Drawn into the feedback image (they trail with it).
    public var shapes: [Shape] = []
    public var lines: [Lines] = []
    public var borders: [Border] = []
    public var darkenCenter = false
    public var composite = Composite()
    /// 0...1 while this frame fades in over another preset (1: fully shown).
    public var opacity: Float = 1

    public init(meshWidth: Int, meshHeight: Int, warp: [SIMD2<Float>]) {
        self.meshWidth = meshWidth
        self.meshHeight = meshHeight
        self.warp = warp
    }

    public struct Lines: Sendable {
        /// A connected line, separate points, or pairs of points (motion vectors).
        public enum Kind: Sendable { case strip, dots, segments }
        public var kind: Kind
        public var points: [SIMD2<Float>]
        /// One per point.
        public var colors: [SIMD4<Float>]
        public var thick = false
        public var additive = false

        public init(kind: Kind, points: [SIMD2<Float>], colors: [SIMD4<Float>], thick: Bool = false, additive: Bool = false) {
            self.kind = kind
            self.points = points
            self.colors = colors
            self.thick = thick
            self.additive = additive
        }
    }

    /// A regular polygon, filled from `centerColor` to `edgeColor`, with an
    /// optional border; `textured` fills it from the feedback image.
    public struct Shape: Sendable {
        public var center: SIMD2<Float>
        public var radius: Float
        public var angle: Float
        public var sides: Int
        public var centerColor: SIMD4<Float>
        public var edgeColor: SIMD4<Float>
        public var borderColor: SIMD4<Float>
        public var additive = false
        public var thickBorder = false
        public var textured = false
        public var textureZoom: Float = 1
        public var textureAngle: Float = 0

        public init(
            center: SIMD2<Float>, radius: Float, angle: Float, sides: Int, centerColor: SIMD4<Float>, edgeColor: SIMD4<Float>,
            borderColor: SIMD4<Float>, additive: Bool = false, thickBorder: Bool = false, textured: Bool = false,
            textureZoom: Float = 1, textureAngle: Float = 0
        ) {
            self.center = center
            self.radius = radius
            self.angle = angle
            self.sides = sides
            self.centerColor = centerColor
            self.edgeColor = edgeColor
            self.borderColor = borderColor
            self.additive = additive
            self.thickBorder = thickBorder
            self.textured = textured
            self.textureZoom = textureZoom
            self.textureAngle = textureAngle
        }
    }

    /// A frame around the screen `inset` from the edge, `size` thick (fractions of the screen).
    public struct Border: Sendable {
        public var inset: Float
        public var size: Float
        public var color: SIMD4<Float>

        public init(inset: Float, size: Float, color: SIMD4<Float>) {
            self.inset = inset
            self.size = size
            self.color = color
        }
    }

    /// How the feedback image reaches the screen.
    public struct Composite: Sendable {
        /// Brightness multiplier (MilkDrop's "gamma").
        public var gamma: Float = 1
        /// A second copy of the image on top: zoomed, flipped, blended in.
        public var echoZoom: Float = 1
        public var echoAlpha: Float = 0
        /// 0 normal, 1 flipped left-right, 2 upside down, 3 both.
        public var echoOrientation = 0
        public var brighten = false
        public var darken = false
        public var solarize = false
        public var invert = false

        public init() {}
    }
}
