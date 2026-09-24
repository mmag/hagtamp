import Metal
import Testing

@testable import Milkdrop
@testable import MilkdropMetal

/// Offscreen: frames go into a texture and come back as pixels.
@Suite(.serialized) struct MilkdropRendererTests {
    let renderer = MilkdropRenderer(targetFormat: .rgba8Unorm)

    func target(_ renderer: MilkdropRenderer, size: Int = 64) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return renderer.device.makeTexture(descriptor: descriptor)
    }

    func render(_ frame: MilkdropFrame, into texture: MTLTexture) -> [UInt8] {
        guard let renderer, let buffer = renderer.makeCommandBuffer() else { return [] }
        renderer.render(frame, to: texture, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        return renderer.pixels(of: texture)
    }

    /// Brightness of column `x` (summed over rows, red channel).
    func column(_ pixels: [UInt8], _ x: Int, size: Int = 64) -> Int {
        (0..<size).reduce(0) { $0 + Int(pixels[($1 * size + x) * 4]) }
    }

    func still(_ uvShift: Float = 0) -> MilkdropFrame {
        var warp: [SIMD2<Float>] = []
        for j in 0...4 { for i in 0...4 { warp.append(SIMD2(Float(i) / 4 - uvShift, Float(j) / 4)) } }
        var frame = MilkdropFrame(meshWidth: 4, meshHeight: 4, warp: warp)
        frame.decay = 1
        frame.wrap = false
        frame.composite.gamma = 1
        return frame
    }

    @Test func drawsTrailsWarpsAndComposites() throws {
        let renderer = try #require(renderer)
        let texture = try #require(target(renderer))
        #expect(render(still(), into: texture).allSatisfy { $0 == 0 || $0 == 255 } && column(render(still(), into: texture), 32) == 0)

        // A white vertical line at x = 0.25 ...
        var line = still()
        line.lines = [MilkdropFrame.Lines(kind: .strip, points: [SIMD2(0.25, 0), SIMD2(0.25, 1)], colors: Array(repeating: SIMD4(1, 1, 1, 1), count: 2), thick: true)]
        let drawn = render(line, into: texture)
        #expect(column(drawn, 16) > 64 * 200)
        // ... stays as a trail with decay 1 ...
        #expect(column(render(still(), into: texture), 16) > 64 * 200)
        // ... and moves right when the mesh samples from the left.
        var moved = render(still(0.25), into: texture)
        #expect(column(moved, 32) > 64 * 200 && column(moved, 16) < 64 * 50)
        // Invert turns the black rest white.
        var inverted = still()
        inverted.composite.invert = true
        moved = render(inverted, into: texture)
        #expect(column(moved, 2) == 64 * 255)
    }

    /// A full-size mesh (well over setVertexBytes' 4 KB) and a long wave render too.
    @Test func fullSizeMeshAndLongLines() throws {
        let renderer = try #require(MilkdropRenderer(targetFormat: .rgba8Unorm))
        let texture = try #require(target(renderer))
        let engine = MilkdropEngine(preset: .parse("fWaveAlpha=1\nnWaveMode=4", name: "Test"))
        let audio = MilkdropAudio(waveform: (0..<576).map { Float(sin(Double($0) * 0.1)) }, spectrum: Array(repeating: 0, count: 512))
        let frame = engine.frame(time: 1, fps: 60, frame: 60, progress: 0, audio: audio, aspect: SIMD2(1, 1))
        #expect(frame.warp.count == 49 * 37)
        let pixels = render(frame, into: texture)
        #expect(pixels.contains { $0 > 100 })
    }

    /// A big target gets a canvas of at most 1024 along its longer side, stretched to fit.
    @Test func bigTargetsDrawOnABoundedCanvas() throws {
        let renderer = try #require(MilkdropRenderer(targetFormat: .rgba8Unorm))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2362, height: 744, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let canvas = renderer.canvasSize(for: texture)
        #expect(canvas.width == 1024 && canvas.height == 323)
        var frame = still()
        frame.lines = [MilkdropFrame.Lines(kind: .strip, points: [SIMD2(0, 0.5), SIMD2(1, 0.5)], colors: Array(repeating: SIMD4(1, 1, 1, 1), count: 2))]
        let pixels = render(frame, into: texture)
        let row = 372, bright = (0..<2362).filter { pixels[(row * 2362 + $0) * 4] > 100 }.count
        #expect(bright > 2000)  // the one-pixel line on the canvas is a couple of pixels on the target
    }

    @Test func decayFadesAndShapesFill() throws {
        let renderer = try #require(MilkdropRenderer(targetFormat: .rgba8Unorm))
        let texture = try #require(target(renderer))
        var frame = still()
        frame.shapes = [MilkdropFrame.Shape(
            center: SIMD2(0.5, 0.5), radius: 0.3, angle: 0, sides: 4, centerColor: SIMD4(1, 0, 0, 1), edgeColor: SIMD4(1, 0, 0, 1),
            borderColor: .zero)]
        let filled = render(frame, into: texture)
        let middle = (32 * 64 + 32) * 4
        #expect(filled[middle] == 255 && filled[middle + 1] == 0)
        var fading = still()
        fading.decay = 0.5
        let faded = render(fading, into: texture)
        #expect((100...160).contains(faded[middle]))
    }
}
