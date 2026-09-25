import Foundation
import Testing

@testable import Milkdrop

/// Small presets written for these tests.
@Suite struct MilkdropPresetTests {
    @Test func readsValuesCodeWavesShapesAndShaders() {
        let preset = MilkdropPreset.parse("""
            [preset00]
            fDecay=0.95
            zoom=1.02
            per_frame_2=b = 2;
            per_frame_1=a = 1;
            per_frame_init_1=q1 = 5;
            per_pixel_1=zoom = zoom + rad*0.01;
            wavecode_1_enabled=1
            wavecode_1_samples=128
            wave_1_per_point1=x = sample;
            shapecode_3_enabled=1
            shapecode_3_sides=6
            shape_3_per_frame1=ang = time;
            warp_1=`shader_body {
            warp_2=`ret = 0;
            comp_1=`shader_body { ret = 1; }
            """, name: "Test")
        #expect(preset.value("fDecay", 0) == 0.95 && preset.value("zoom", 0) == 1.02)
        #expect(preset.perFrame == "a = 1;\nb = 2;")
        #expect(preset.perFrameInit == "q1 = 5;" && preset.perPixel == "zoom = zoom + rad*0.01;")
        #expect(preset.waves[1].enabled && preset.waves[1].values["samples"] == 128 && preset.waves[1].perPoint == "x = sample;")
        #expect(!preset.waves[0].enabled)
        #expect(preset.shapes[3].enabled && preset.shapes[3].values["sides"] == 6 && preset.shapes[3].perFrame == "ang = time;")
        #expect(preset.warpShader == "shader_body {\nret = 0;")
        #expect(preset.compositeShader == "shader_body { ret = 1; }")
    }
}

@Suite struct MilkdropEngineTests {
    let square = SIMD2(1.0, 1.0)

    func frame(_ text: String, time: Double = 0, audio: MilkdropAudio = .silence) -> (MilkdropEngine, MilkdropFrame) {
        let engine = MilkdropEngine(preset: .parse(text, name: "Test"), meshWidth: 8, meshHeight: 6)
        return (engine, engine.frame(time: time, fps: 60, frame: 1, progress: 0, audio: audio, aspect: square))
    }

    func uv(_ frame: MilkdropFrame, _ i: Int, _ j: Int) -> SIMD2<Float> { frame.warp[j * (frame.meshWidth + 1) + i] }

    @Test func stillPresetLeavesTheImageInPlace() {
        let (_, f) = frame("warp=0\nzoom=1\nrot=0")
        #expect(f.warp.count == 9 * 7)
        #expect(abs(uv(f, 0, 0).x) < 1e-6 && abs(uv(f, 0, 0).y) < 1e-6)
        #expect(abs(uv(f, 8, 6).x - 1) < 1e-6 && abs(uv(f, 8, 6).y - 1) < 1e-6)
        #expect(abs(uv(f, 4, 3).x - 0.5) < 1e-6)
    }

    @Test func zoomPullsTowardsTheCenterAndDxShifts() {
        let (_, zoomed) = frame("warp=0\nzoom=2")
        #expect(abs(uv(zoomed, 0, 0).x - 0.25) < 1e-6)  // the corner samples halfway in: zooming in
        let (_, shifted) = frame("warp=0\ndx=0.1")
        #expect(abs(uv(shifted, 4, 3).x - 0.4) < 1e-6)
    }

    @Test func codeFlowsFromInitToFrameToVertices() {
        let text = """
            warp=0
            per_frame_init_1=q1 = 0.5; counter = 10;
            per_frame_1=counter = counter + 1; dx = q1 * 0.2;
            per_pixel_1=dy = if(above(x, 0.5), 0.1, 0);
            """
        let engine = MilkdropEngine(preset: .parse(text, name: "Test"), meshWidth: 8, meshHeight: 6)
        _ = engine.frame(time: 0, fps: 60, frame: 1, progress: 0, audio: .silence, aspect: square)
        let second = engine.frame(time: 0.1, fps: 60, frame: 2, progress: 0, audio: .silence, aspect: square)
        #expect(engine.errors.isEmpty)
        #expect(abs(uv(second, 4, 3).x - 0.4) < 1e-6)  // dx = 0.1 from q1
        #expect(abs(uv(second, 8, 3).y - 0.4) < 1e-6 && abs(uv(second, 0, 3).y - 0.5) < 1e-6)
    }

    /// A preset that loops millions of times per vertex still gives a frame
    /// in about the time a frame's code is allowed.
    @Test func loopsStopWhenTheFrameRunsOutOfTime() {
        let engine = MilkdropEngine(preset: .parse("per_pixel_1=a = loop(1000000, b = b + 1);", name: "Heavy"))
        let start = DispatchTime.now().uptimeNanoseconds
        _ = engine.frame(time: 0, fps: 60, frame: 1, progress: 0, audio: .silence, aspect: square)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(seconds < 0.6)
    }

    /// Presets are files from anywhere: impossible values don't bring the app down.
    @Test func impossibleValuesDontCrash() {
        let (_, f) = frame("""
            nWaveMode=nan
            zoom=inf
            fWaveAlpha=1
            nVideoEchoOrientation=1e300
            per_frame_1=wave_mode = 1e300; echo_orient = 0/0; mv_x = 1e300; mv_y = -1e300; mv_a = 1;
            wavecode_0_enabled=1
            wavecode_0_samples=1e300
            wavecode_0_sep=-1e300
            wave_0_per_frame1=samples = 1e300; sep = 1e300;
            shapecode_0_enabled=1
            shapecode_0_num_inst=1e300
            shape_0_per_frame1=sides = 0/0;
            """)
        #expect(f.warp.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(f.shapes.count == 1024 && f.shapes.allSatisfy { $0.sides == 3 })
        #expect(MilkdropPreset.parse("zoom=inf\nrot=nan\nwarp=2", name: "Test").value("zoom", 1) == 1)
    }

    @Test func brokenBlocksAreSkipped() {
        let (engine, f) = frame("per_frame_1=zoom = (1 +\nper_pixel_1=rot = 0.1;")
        #expect(engine.errors.count == 1 && engine.errors[0].hasPrefix("per-frame"))
        #expect(f.warp.count == 63)
    }

    @Test func wavesShapesAndBorders() {
        let (_, f) = frame("""
            fWaveAlpha=1
            nWaveMode=4
            ob_size=0.02
            ob_a=1
            wavecode_0_enabled=1
            wavecode_0_samples=16
            wave_0_per_point1=x = sample; y = 0.25; r = 0; a = 0.5;
            shapecode_0_enabled=1
            shapecode_0_num_inst=3
            shapecode_0_sides=5
            shape_0_per_frame1=x = 0.2 + instance * 0.3;
            """)
        let custom = f.lines.first { $0.points.count == 16 }
        #expect(custom?.points.last == SIMD2(1, 0.25) && custom?.colors.first == SIMD4(0, 1, 1, 0.5))
        #expect(f.lines.contains { $0.points.count == 288 })  // the main wave
        #expect(f.shapes.map(\.center.x) == [0.2, 0.5, 0.8] && f.shapes.allSatisfy { $0.sides == 5 })
        #expect(f.borders.count == 1 && f.borders[0].size == 0.02)
    }

    @Test func blendingMixesMeshesAndFadesDrawing() {
        let (_, a) = frame("warp=0\ndx=0.2\nob_a=1")
        let (_, b) = frame("warp=0\ndx=0")
        let half = MilkdropFrame.blend(a, b, t: 0.5)
        #expect(abs(uv(half, 4, 3).x - 0.4) < 1e-6)
        #expect(half.borders.first?.color.w == 0.5)
    }

    @Test func soundDrivesTheVariables() {
        let analyzer = MilkdropAudioAnalyzer()
        let quiet = (0..<1024).map { Float(sin(Double($0) * 0.05)) * 0.05 }
        for _ in 0..<60 { _ = analyzer.analyze(quiet, dt: 1.0 / 60) }
        let loud = analyzer.analyze(quiet.map { $0 * 8 }, dt: 1.0 / 60)
        #expect(loud.bass > 3)  // a beat: well above the recent average
        #expect(loud.waveform.count == 576 && loud.spectrum.count == 512)
        #expect(analyzer.analyze(Array(repeating: 0, count: 1024), dt: 1.0 / 60).bass < 0.1)
    }
}

/// The presets that ship with the app (App/Presets) all compile and draw something.
@Suite struct BundledPresetTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Presets")

    @Test func everyBundledPresetRuns() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }
        #expect(files.count >= 8)
        let loud = MilkdropAudio(waveform: (0..<576).map { Float(sin(Double($0) * 0.2)) * 0.5 }, spectrum: Array(repeating: 0.05, count: 512))
        for file in files {
            let preset = MilkdropPreset.parse(try String(contentsOf: file, encoding: .utf8), name: file.lastPathComponent)
            let engine = MilkdropEngine(preset: preset)
            #expect(engine.errors.isEmpty, "\(file.lastPathComponent): \(engine.errors)")
            let frame = engine.frame(time: 3, fps: 60, frame: 180, progress: 0.2, audio: loud, aspect: SIMD2(1, 0.75))
            #expect(frame.warp.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(file.lastPathComponent)")
            #expect(!frame.lines.isEmpty || !frame.shapes.isEmpty, "\(file.lastPathComponent) draws nothing")
        }
    }
}
