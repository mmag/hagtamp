import Foundation
import Metal
import Milkdrop
import simd

/// Draws `MilkdropFrame`s with Metal. Each frame: the previous image is
/// warped through the mesh into the other feedback texture (fading by
/// `decay`), shapes, waves and borders are drawn on top of it (so they
/// leave trails), and the result is composited to the target.
public final class MilkdropRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLRenderPipelineState
    private let drawPipelines: [Blend: MTLRenderPipelineState]
    private let texturedPipelines: [Blend: MTLRenderPipelineState]
    private let compositePipeline: MTLRenderPipelineState
    private let wrapSampler: MTLSamplerState
    private let clampSampler: MTLSamplerState
    private var feedback: [MTLTexture] = []
    private var current = 0

    public static let feedbackFormat = MTLPixelFormat.rgba16Float
    /// The image is made at most this big (longest side) and stretched to
    /// the target, like MilkDrop's fixed-size canvas: on a big Retina
    /// window one-pixel lines and dots would otherwise all but vanish.
    public var maxCanvasSize = 1024

    private enum Blend: Hashable { case alpha, additive }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), targetFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shaders, options: nil)
        else { return nil }
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: Blend?) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if let blend {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let warp = pipeline("warp_vertex", "warp_fragment", format: Self.feedbackFormat, blend: nil),
            let composite = pipeline("composite_vertex", "composite_fragment", format: targetFormat, blend: nil)
        else { return nil }
        var draw: [Blend: MTLRenderPipelineState] = [:], textured: [Blend: MTLRenderPipelineState] = [:]
        for blend in [Blend.alpha, .additive] {
            guard let plain = pipeline("draw_vertex", "draw_fragment", format: Self.feedbackFormat, blend: blend),
                let withTexture = pipeline("draw_vertex", "textured_fragment", format: Self.feedbackFormat, blend: blend)
            else { return nil }
            draw[blend] = plain
            textured[blend] = withTexture
        }
        warpPipeline = warp
        compositePipeline = composite
        drawPipelines = draw
        texturedPipelines = textured

        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.sAddressMode = mode
            descriptor.tAddressMode = mode
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let wrap = sampler(.repeat), let clamp = sampler(.clampToEdge) else { return nil }
        wrapSampler = wrap
        clampSampler = clamp
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// Feedback textures follow the target's size; a new size starts from black.
    private func prepareFeedback(width: Int, height: Int) {
        guard feedback.first.map({ $0.width != width || $0.height != height }) ?? true else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.feedbackFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        feedback = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        guard let buffer = queue.makeCommandBuffer() else { return }
        for texture in feedback {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        buffer.commit()
    }

    /// The canvas for a target: its shape, at most `maxCanvasSize` along the longer side.
    func canvasSize(for target: MTLTexture) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxCanvasSize) / Double(max(target.width, target.height, 1)))
        return (max(1, Int((Double(target.width) * scale).rounded())), max(1, Int((Double(target.height) * scale).rounded())))
    }

    /// Renders `frame` into `target` (a drawable's texture or an offscreen one).
    public func render(_ frame: MilkdropFrame, to target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let canvas = canvasSize(for: target)
        prepareFeedback(width: canvas.width, height: canvas.height)
        guard feedback.count == 2 else { return }
        let previous = feedback[current], next = feedback[1 - current]
        let sampler = frame.wrap ? wrapSampler : clampSampler

        // 1. Warp: the previous image through the mesh, faded.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = next
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(warpPipeline)
        let mesh = Self.meshTriangles(frame)
        // setVertexBytes takes at most 4 KB; a 48x36 mesh is about 160.
        guard let meshBuffer = device.makeBuffer(bytes: mesh, length: mesh.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
            encoder.endEncoding()
            return
        }
        encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
        var decay = frame.decay
        encoder.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentTexture(previous, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)

        // 2. Drawing on top of it, in MilkDrop's order.
        let geometry = DrawGeometry(size: SIMD2(Float(canvas.width), Float(canvas.height)))
        if frame.darkenCenter { draw(geometry.darkCenter(), blend: .alpha, encoder) }
        for shape in frame.shapes {
            let fill = geometry.shape(shape)
            if shape.textured {
                encoder.setRenderPipelineState(texturedPipelines[shape.additive ? .additive : .alpha]!)
                encoder.setFragmentTexture(previous, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                upload(fill, encoder)
            } else {
                draw(fill, blend: shape.additive ? .additive : .alpha, encoder)
            }
            if shape.borderColor.w > 0.001 {
                draw(geometry.outline(shape), blend: shape.additive ? .additive : .alpha, encoder)
            }
        }
        for lines in frame.lines {
            draw(geometry.lines(lines), blend: lines.additive ? .additive : .alpha, encoder)
        }
        for border in frame.borders {
            draw(geometry.border(border), blend: .alpha, encoder)
        }
        encoder.endEncoding()

        // 3. Composite to the target.
        let screen = MTLRenderPassDescriptor()
        screen.colorAttachments[0].texture = target
        screen.colorAttachments[0].loadAction = .dontCare
        screen.colorAttachments[0].storeAction = .store
        guard let composite = commandBuffer.makeRenderCommandEncoder(descriptor: screen) else { return }
        composite.setRenderPipelineState(compositePipeline)
        var settings = CompositeSettings(frame.composite)
        composite.setFragmentBytes(&settings, length: MemoryLayout<CompositeSettings>.stride, index: 0)
        composite.setFragmentTexture(next, index: 0)
        composite.setFragmentSamplerState(sampler, index: 0)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
        current = 1 - current
    }

    private func draw(_ vertices: [DrawVertex], blend: Blend, _ encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(drawPipelines[blend]!)
        upload(vertices, encoder)
    }

    private func upload(_ vertices: [DrawVertex], _ encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty else { return }
        let length = vertices.count * MemoryLayout<DrawVertex>.stride
        if length <= 4096 {
            encoder.setVertexBytes(vertices, length: length, index: 0)
        } else if let buffer = device.makeBuffer(bytes: vertices, length: length, options: .storageModeShared) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        } else {
            return
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    /// Two triangles per mesh cell: (clip x, clip y, u, v).
    static func meshTriangles(_ frame: MilkdropFrame) -> [SIMD4<Float>] {
        let w = frame.meshWidth, h = frame.meshHeight
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(w * h * 6)
        func vertex(_ i: Int, _ j: Int) -> SIMD4<Float> {
            let uv = frame.warp[j * (w + 1) + i]
            return SIMD4(Float(i) / Float(w) * 2 - 1, 1 - Float(j) / Float(h) * 2, uv.x, uv.y)
        }
        for j in 0..<h {
            for i in 0..<w {
                let a = vertex(i, j), b = vertex(i + 1, j), c = vertex(i, j + 1), d = vertex(i + 1, j + 1)
                result += [a, b, c, b, d, c]
            }
        }
        return result
    }

    /// Reads a texture back (tests): BGRA or RGBA 8-bit rows.
    public func pixels(of texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }
}

/// Matches the shaders' `CompositeSettings`.
struct CompositeSettings {
    var gamma: Float
    var echoZoom: Float
    var echoAlpha: Float
    var echoOrientation: Int32
    var brighten: Int32
    var darken: Int32
    var solarize: Int32
    var invert: Int32

    init(_ c: MilkdropFrame.Composite) {
        gamma = c.gamma
        echoZoom = c.echoZoom == 0 ? 1 : c.echoZoom
        echoAlpha = c.echoAlpha
        echoOrientation = Int32(c.echoOrientation)
        brighten = c.brighten ? 1 : 0
        darken = c.darken ? 1 : 0
        solarize = c.solarize ? 1 : 0
        invert = c.invert ? 1 : 0
    }
}

/// A vertex of drawn geometry: clip position, color and (textured shapes) uv.
struct DrawVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Turns shapes, lines and borders (0...1, y up) into triangles in clip space.
struct DrawGeometry {
    let size: SIMD2<Float>

    /// Lines are about one pixel at 512 px tall, like the original's at its
    /// usual size, and grow with the output.
    var lineWidth: Float { max(1, size.y / 512) }
    /// Round shapes stay round: x shrinks on wide outputs, y on tall ones.
    var aspect: SIMD2<Float> { size.x >= size.y ? SIMD2(size.y / size.x, 1) : SIMD2(1, size.x / size.y) }

    func clip(_ p: SIMD2<Float>) -> SIMD2<Float> { p * 2 - 1 }

    func shape(_ s: MilkdropFrame.Shape) -> [DrawVertex] {
        let center = DrawVertex(position: clip(s.center), uv: SIMD2(0.5, 0.5), color: s.centerColor)
        var result: [DrawVertex] = []
        let rim = rimPoints(s)
        for k in 0..<s.sides {
            let a = rim[k], b = rim[(k + 1) % s.sides]
            result += [center, a, b]
        }
        return result
    }

    private func rimPoints(_ s: MilkdropFrame.Shape) -> [DrawVertex] {
        (0..<s.sides).map { k in
            let angle = Float(k) / Float(s.sides) * 2 * .pi + s.angle + .pi / 4
            let offset = SIMD2(cos(angle), sin(angle)) * s.radius * aspect
            // Textured shapes show the image, turned and zoomed (texture v runs down).
            let t = angle + s.textureAngle - s.angle
            let zoom = s.textureZoom == 0 ? 1 : s.textureZoom
            let uv = SIMD2<Float>(0.5, 0.5) + SIMD2(cos(t), -sin(t)) * s.radius / zoom
            return DrawVertex(position: clip(s.center + offset), uv: uv, color: s.edgeColor)
        }
    }

    func outline(_ s: MilkdropFrame.Shape) -> [DrawVertex] {
        let rim = rimPoints(s).map { ($0.position + 1) / 2 }
        let points = rim + [rim[0]]
        return strip(points, colors: Array(repeating: s.borderColor, count: points.count), width: lineWidth * (s.thickBorder ? 2 : 1))
    }

    func lines(_ l: MilkdropFrame.Lines) -> [DrawVertex] {
        let width = lineWidth * (l.thick ? 2 : 1)
        switch l.kind {
        case .dots:
            return zip(l.points, l.colors).flatMap { p, c in p.x.isFinite ? quad(center: p, half: SIMD2(repeating: width) / size, color: c) : [] }
        case .segments:
            return stride(from: 0, to: l.points.count - 1, by: 2).flatMap { i in
                strip([l.points[i], l.points[i + 1]], colors: [l.colors[i], l.colors[i + 1]], width: width)
            }
        case .strip:
            // Non-finite points break the line in two.
            var result: [DrawVertex] = []
            var run: [SIMD2<Float>] = [], runColors: [SIMD4<Float>] = []
            for (p, c) in zip(l.points, l.colors) {
                if p.x.isFinite, p.y.isFinite {
                    run.append(p)
                    runColors.append(c)
                } else {
                    result += strip(run, colors: runColors, width: width)
                    run = []
                    runColors = []
                }
            }
            return result + strip(run, colors: runColors, width: width)
        }
    }

    /// A polyline as quads, `width` pixels wide.
    func strip(_ points: [SIMD2<Float>], colors: [SIMD4<Float>], width: Float) -> [DrawVertex] {
        guard points.count >= 2 else { return [] }
        var result: [DrawVertex] = []
        for i in 0..<points.count - 1 {
            let a = points[i] * size, b = points[i + 1] * size
            let direction = b - a
            let length = simd_length(direction)
            guard length > 0.0001 else { continue }
            let normal = SIMD2(-direction.y, direction.x) / length * (width / 2)
            let corners = [a + normal, a - normal, b + normal, b - normal].map { DrawVertex(position: clip($0 / size), uv: .zero, color: .zero) }
            var v = corners
            v[0].color = colors[i]
            v[1].color = colors[i]
            v[2].color = colors[i + 1]
            v[3].color = colors[i + 1]
            result += [v[0], v[1], v[2], v[1], v[3], v[2]]
        }
        return result
    }

    func quad(center: SIMD2<Float>, half: SIMD2<Float>, color: SIMD4<Float>) -> [DrawVertex] {
        let corners = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)].map {
            DrawVertex(position: clip(center + $0 * half), uv: .zero, color: color)
        }
        return [corners[0], corners[1], corners[2], corners[1], corners[3], corners[2]]
    }

    func rect(_ origin: SIMD2<Float>, _ extent: SIMD2<Float>, _ color: SIMD4<Float>) -> [DrawVertex] {
        quad(center: origin + extent / 2, half: extent / 2, color: color)
    }

    /// A frame `inset` in from the edges, `size` thick (fractions of the screen).
    func border(_ b: MilkdropFrame.Border) -> [DrawVertex] {
        let i = b.inset, s = b.size
        guard s > 0, i + s <= 0.5 else { return [] }
        return rect(SIMD2(i, i), SIMD2(1 - 2 * i, s), b.color) + rect(SIMD2(i, 1 - i - s), SIMD2(1 - 2 * i, s), b.color)
            + rect(SIMD2(i, i + s), SIMD2(s, 1 - 2 * (i + s)), b.color) + rect(SIMD2(1 - i - s, i + s), SIMD2(s, 1 - 2 * (i + s)), b.color)
    }

    /// A soft dark spot in the middle, so the center doesn't burn out.
    func darkCenter() -> [DrawVertex] {
        let shape = MilkdropFrame.Shape(
            center: SIMD2(0.5, 0.5), radius: 0.07, angle: 0, sides: 24, centerColor: SIMD4(0, 0, 0, 3.0 / 32), edgeColor: .zero,
            borderColor: .zero)
        return self.shape(shape)
    }
}

extension MilkdropRenderer {
    static let shaders = """
        #include <metal_stdlib>
        using namespace metal;

        struct WarpOut { float4 position [[position]]; float2 uv; };

        vertex WarpOut warp_vertex(const device float4 *vertices [[buffer(0)]], uint id [[vertex_id]]) {
            WarpOut out;
            out.position = float4(vertices[id].xy, 0, 1);
            out.uv = vertices[id].zw;
            return out;
        }

        fragment float4 warp_fragment(WarpOut in [[stage_in]], texture2d<float> previous [[texture(0)]],
                                      sampler s [[sampler(0)]], constant float &decay [[buffer(0)]]) {
            return float4(saturate(previous.sample(s, in.uv).rgb * decay), 1);
        }

        struct DrawVertex { float2 position; float2 uv; float4 color; };
        struct DrawOut { float4 position [[position]]; float2 uv; float4 color; };

        vertex DrawOut draw_vertex(const device DrawVertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {
            DrawOut out;
            out.position = float4(vertices[id].position, 0, 1);
            out.uv = vertices[id].uv;
            out.color = vertices[id].color;
            return out;
        }

        fragment float4 draw_fragment(DrawOut in [[stage_in]]) { return in.color; }

        fragment float4 textured_fragment(DrawOut in [[stage_in]], texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
            return float4(image.sample(s, in.uv).rgb * in.color.rgb, in.color.a);
        }

        struct CompositeOut { float4 position [[position]]; float2 uv; };

        vertex CompositeOut composite_vertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            CompositeOut out;
            out.position = float4(p * 2 - 1, 0, 1);
            out.uv = float2(p.x, 1 - p.y);
            return out;
        }

        struct CompositeSettings {
            float gamma; float echoZoom; float echoAlpha; int echoOrientation;
            int brighten; int darken; int solarize; int invert;
        };

        fragment float4 composite_fragment(CompositeOut in [[stage_in]], texture2d<float> image [[texture(0)]],
                                           sampler s [[sampler(0)]], constant CompositeSettings &c [[buffer(0)]]) {
            float3 color = image.sample(s, in.uv).rgb;
            if (c.echoAlpha > 0.001) {
                float2 e = (in.uv - 0.5) / c.echoZoom + 0.5;
                if (c.echoOrientation & 1) e.x = 1 - e.x;
                if (c.echoOrientation & 2) e.y = 1 - e.y;
                color = mix(color, image.sample(s, e).rgb, c.echoAlpha);
            }
            color = saturate(color * c.gamma);
            if (c.brighten) color = sqrt(color);
            if (c.darken) color = color * color;
            if (c.solarize) color = color * (1 - color) * 4;
            if (c.invert) color = 1 - color;
            return float4(color, 1);
        }
        """
}
