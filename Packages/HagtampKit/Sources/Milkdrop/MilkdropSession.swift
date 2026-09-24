import Foundation

/// What the visualization window drives: the preset on screen, a soft
/// blend into the next one, and the sound analysis.
public final class MilkdropSession: @unchecked Sendable {
    public let meshWidth: Int
    public let meshHeight: Int
    /// Seconds a preset shows before `progress` reaches 1.
    public var presetDuration: Double = 20
    /// Seconds a soft switch takes.
    public var blendDuration: Double = 2.5

    public private(set) var current: MilkdropEngine?
    private var previous: MilkdropEngine?
    private var presetStart = 0.0
    private var blendStart = 0.0
    private var lastTime: Double?
    private var frameCount = 0
    private var fps = 60.0
    private let analyzer = MilkdropAudioAnalyzer()

    public init(meshWidth: Int = 48, meshHeight: Int = 36) {
        self.meshWidth = meshWidth
        self.meshHeight = meshHeight
    }

    /// Switches presets: blended over `blendDuration`, or at once (a hard cut).
    public func load(_ preset: MilkdropPreset, at time: Double, blend: Bool = true) {
        previous = blend ? current : nil
        current = MilkdropEngine(preset: preset, meshWidth: meshWidth, meshHeight: meshHeight)
        presetStart = time
        blendStart = time
    }

    public var isBlending: Bool { previous != nil }

    /// Seconds since the current preset came up.
    public func elapsed(at time: Double) -> Double { time - presetStart }

    /// `samples`: the latest audio (mono), `size`: the output in pixels.
    public func frame(time: Double, samples: [Float], size: SIMD2<Double>) -> MilkdropFrame? {
        guard let current else { return nil }
        let dt = lastTime.map { max(0, time - $0) } ?? 1.0 / 60
        lastTime = time
        if dt > 0 { fps = fps * 0.9 + min(240, 1 / max(dt, 1.0 / 240)) * 0.1 }
        frameCount += 1
        let audio = analyzer.analyze(samples, dt: dt)
        let aspect = Self.aspect(size)
        let progress = min(1, max(0, (time - presetStart) / presetDuration))
        var frame = current.frame(time: time, fps: fps, frame: frameCount, progress: progress, audio: audio, aspect: aspect)

        if let previous {
            let t = Float(min(1, max(0, (time - blendStart) / blendDuration)))
            if t >= 1 {
                self.previous = nil
            } else {
                let old = previous.frame(time: time, fps: fps, frame: frameCount, progress: 1, audio: audio, aspect: aspect)
                frame = MilkdropFrame.blend(old, frame, t: Self.ease(t))
            }
        }
        return frame
    }

    /// MilkDrop's aspectx/aspecty: 1 along the longer side.
    public static func aspect(_ size: SIMD2<Double>) -> SIMD2<Double> {
        guard size.x > 0, size.y > 0 else { return SIMD2(1, 1) }
        return size.x >= size.y ? SIMD2(1, size.y / size.x) : SIMD2(size.x / size.y, 1)
    }

    static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }
}

extension MilkdropFrame {
    /// Between two presets: the meshes and settings mix, the drawing of both
    /// fades across (the old one out, the new one in).
    public static func blend(_ from: MilkdropFrame, _ to: MilkdropFrame, t: Float) -> MilkdropFrame {
        guard from.warp.count == to.warp.count else { return to }
        var result = to
        result.warp = zip(from.warp, to.warp).map { $0 + ($1 - $0) * t }
        result.decay = from.decay + (to.decay - from.decay) * t
        result.wrap = t < 0.5 ? from.wrap : to.wrap
        result.darkenCenter = t < 0.5 ? from.darkenCenter : to.darkenCenter
        var composite = to.composite
        composite.gamma = from.composite.gamma + (to.composite.gamma - from.composite.gamma) * t
        composite.echoAlpha = from.composite.echoAlpha * (1 - t) + to.composite.echoAlpha * t
        composite.echoZoom = from.composite.echoZoom + (to.composite.echoZoom - from.composite.echoZoom) * t
        if t < 0.5 {
            composite.echoOrientation = from.composite.echoOrientation
            composite.brighten = from.composite.brighten
            composite.darken = from.composite.darken
            composite.solarize = from.composite.solarize
            composite.invert = from.composite.invert
        }
        result.composite = composite
        func faded<T>(_ items: [T], by factor: Float, _ fade: (inout T, Float) -> Void) -> [T] {
            items.map { item in
                var item = item
                fade(&item, factor)
                return item
            }
        }
        let fadeLines: (inout Lines, Float) -> Void = { lines, f in lines.colors = lines.colors.map { SIMD4($0.x, $0.y, $0.z, $0.w * f) } }
        let fadeShape: (inout Shape, Float) -> Void = { shape, f in
            shape.centerColor.w *= f
            shape.edgeColor.w *= f
            shape.borderColor.w *= f
        }
        let fadeBorder: (inout Border, Float) -> Void = { border, f in border.color.w *= f }
        result.lines = faded(from.lines, by: 1 - t, fadeLines) + faded(to.lines, by: t, fadeLines)
        result.shapes = faded(from.shapes, by: 1 - t, fadeShape) + faded(to.shapes, by: t, fadeShape)
        result.borders = faded(from.borders, by: 1 - t, fadeBorder) + faded(to.borders, by: t, fadeBorder)
        return result
    }
}
