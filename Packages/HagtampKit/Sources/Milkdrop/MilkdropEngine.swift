import Foundation

/// Runs one preset: its code every frame, turning time and sound into a
/// `MilkdropFrame`. Blocks that don't compile are skipped (and listed in
/// `errors`), like MilkDrop does with broken equations.
public final class MilkdropEngine: @unchecked Sendable {
    public let preset: MilkdropPreset
    public let meshWidth: Int
    public let meshHeight: Int
    public private(set) var errors: [String] = []

    private let global = EELGlobalMemory()
    private let frameVars: EELVariables
    private let perFrame: EELProgram?
    private let pixelVars: EELVariables
    private let perPixel: EELProgram?
    private var qAfterInit = [Double](repeating: 0, count: 32)
    private var waves: [WaveRuntime] = []
    private var shapes: [ShapeRuntime] = []

    /// Per-frame variables: name, preset key, default. They start every
    /// frame at the preset's value; the code may change them.
    static let frameVariables: [(String, String, Double)] = [
        ("zoom", "zoom", 1), ("zoomexp", "fzoomexponent", 1), ("rot", "rot", 0), ("warp", "warp", 1),
        ("cx", "cx", 0.5), ("cy", "cy", 0.5), ("dx", "dx", 0), ("dy", "dy", 0), ("sx", "sx", 1), ("sy", "sy", 1),
        ("decay", "fdecay", 0.98), ("gamma", "fgammaadj", 2), ("echo_zoom", "fvideoechozoom", 2),
        ("echo_alpha", "fvideoechoalpha", 0), ("echo_orient", "nvideoechoorientation", 0),
        ("wave_mode", "nwavemode", 0), ("wave_x", "wave_x", 0.5), ("wave_y", "wave_y", 0.5),
        ("wave_r", "wave_r", 1), ("wave_g", "wave_g", 1), ("wave_b", "wave_b", 1), ("wave_a", "fwavealpha", 0.8),
        ("wave_mystery", "fwaveparam", 0), ("wave_usedots", "bwavedots", 0), ("wave_thick", "bwavethick", 0),
        ("wave_additive", "badditivewaves", 0), ("wave_brighten", "bmaximizewavecolor", 1),
        ("ob_size", "ob_size", 0.01), ("ob_r", "ob_r", 0), ("ob_g", "ob_g", 0), ("ob_b", "ob_b", 0), ("ob_a", "ob_a", 0),
        ("ib_size", "ib_size", 0.01), ("ib_r", "ib_r", 0.25), ("ib_g", "ib_g", 0.25), ("ib_b", "ib_b", 0.25), ("ib_a", "ib_a", 0),
        ("mv_x", "nmotionvectorsx", 12), ("mv_y", "nmotionvectorsy", 9), ("mv_dx", "mv_dx", 0), ("mv_dy", "mv_dy", 0),
        ("mv_l", "mv_l", 0.9), ("mv_r", "mv_r", 1), ("mv_g", "mv_g", 1), ("mv_b", "mv_b", 1), ("mv_a", "mv_a", 0),
        ("darken_center", "bdarkencenter", 0), ("brighten", "bbrighten", 0), ("darken", "bdarken", 0),
        ("solarize", "bsolarize", 0), ("invert", "binvert", 0), ("wrap", "btexwrap", 1),
        ("warpanimspeed", "fwarpanimspeed", 1), ("warpscale", "fwarpscale", 1),
    ]
    /// What per-vertex code reads and may change.
    static let motionVariables = ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"]
    static let inputVariables = ["time", "fps", "frame", "progress", "bass", "mid", "treb", "bass_att", "mid_att", "treb_att", "meshx", "meshy", "pixelsx", "pixelsy", "aspectx", "aspecty"]

    public init(preset: MilkdropPreset, meshWidth: Int = 48, meshHeight: Int = 36) {
        self.preset = preset
        self.meshWidth = meshWidth
        self.meshHeight = meshHeight
        frameVars = EELVariables(global: global)
        pixelVars = EELVariables(global: global)
        var errors: [String] = []
        func compile(_ code: String, _ vars: EELVariables, _ what: String) -> EELProgram? {
            do {
                let program = try EELProgram(code, variables: vars)
                return program.isEmpty ? nil : program
            } catch {
                errors.append("\(what): \(error)")
                return nil
            }
        }
        let frameInit = compile(preset.perFrameInit, frameVars, "per-frame init")
        perFrame = compile(preset.perFrame, frameVars, "per-frame")
        perPixel = compile(preset.perPixel, pixelVars, "per-vertex")
        for wave in preset.waves where wave.enabled {
            let vars = EELVariables(global: global)
            waves.append(WaveRuntime(
                wave: wave, vars: vars, initCode: compile(wave.initCode, vars, "wave \(wave.index) init"),
                perFrame: compile(wave.perFrame, vars, "wave \(wave.index) per-frame"),
                perPoint: compile(wave.perPoint, vars, "wave \(wave.index) per-point")))
        }
        for shape in preset.shapes where shape.enabled {
            let vars = EELVariables(global: global)
            shapes.append(ShapeRuntime(
                shape: shape, vars: vars, initCode: compile(shape.initCode, vars, "shape \(shape.index) init"),
                perFrame: compile(shape.perFrame, vars, "shape \(shape.index) per-frame")))
        }
        self.errors = errors

        // Init code runs once; the q values it leaves are where every frame starts.
        resetFrameVariables()
        setInputs(frameVars, time: 0, fps: 60, frame: 0, progress: 0, audio: .silence, aspect: SIMD2(1, 1))
        frameInit?.run(frameVars)
        qAfterInit = (1...32).map { frameVars["q\($0)"] }
        for i in waves.indices { waves[i].runInit(q: qAfterInit) }
        for i in shapes.indices { shapes[i].runInit(q: qAfterInit) }
    }

    private func resetFrameVariables() {
        for (name, key, fallback) in Self.frameVariables {
            frameVars[name] = preset.value(key, fallback)
        }
    }

    private func setInputs(_ vars: EELVariables, time: Double, fps: Double, frame: Int, progress: Double, audio: MilkdropAudio, aspect: SIMD2<Double>) {
        vars["time"] = time
        vars["fps"] = fps
        vars["frame"] = Double(frame)
        vars["progress"] = progress
        vars["bass"] = audio.bass
        vars["mid"] = audio.mid
        vars["treb"] = audio.treb
        vars["bass_att"] = audio.bassAtt
        vars["mid_att"] = audio.midAtt
        vars["treb_att"] = audio.trebAtt
        vars["meshx"] = Double(meshWidth)
        vars["meshy"] = Double(meshHeight)
        vars["pixelsx"] = 1024
        vars["pixelsy"] = 1024 * aspect.x / aspect.y
        vars["aspectx"] = aspect.x
        vars["aspecty"] = aspect.y
    }

    // MARK: - Frame

    /// `aspect`: MilkDrop's aspectx/aspecty (1 along the longer side,
    /// shorter/longer along the other); `progress`: 0...1 through the preset's time.
    public func frame(time: Double, fps: Double, frame: Int, progress: Double, audio: MilkdropAudio, aspect: SIMD2<Double>) -> MilkdropFrame {
        resetFrameVariables()
        for i in 0..<32 { frameVars["q\(i + 1)"] = qAfterInit[i] }
        setInputs(frameVars, time: time, fps: fps, frame: frame, progress: progress, audio: audio, aspect: aspect)
        perFrame?.run(frameVars)
        let q = (1...32).map { frameVars["q\($0)"] }
        func v(_ name: String) -> Double { frameVars[name] }

        var result = MilkdropFrame(meshWidth: meshWidth, meshHeight: meshHeight, warp: warpMesh(time: time, q: q, aspect: aspect))
        result.decay = Float(min(1, max(0, v("decay"))))
        result.wrap = v("wrap") >= 0.5
        result.darkenCenter = v("darken_center") >= 0.5
        result.composite.gamma = Float(max(0, v("gamma")))
        result.composite.echoZoom = Float(v("echo_zoom"))
        result.composite.echoAlpha = Float(min(1, max(0, v("echo_alpha"))))
        result.composite.echoOrientation = ((Int(v("echo_orient")) % 4) + 4) % 4
        result.composite.brighten = v("brighten") >= 0.5
        result.composite.darken = v("darken") >= 0.5
        result.composite.solarize = v("solarize") >= 0.5
        result.composite.invert = v("invert") >= 0.5

        if let lines = motionVectors(result) { result.lines.append(lines) }
        for i in shapes.indices {
            result.shapes += shapes[i].frame(q: q) { self.setInputs($0, time: time, fps: fps, frame: frame, progress: progress, audio: audio, aspect: aspect) }
        }
        for i in waves.indices {
            if let lines = waves[i].frame(q: q, audio: audio, setInputs: {
                self.setInputs($0, time: time, fps: fps, frame: frame, progress: progress, audio: audio, aspect: aspect)
            }) {
                result.lines.append(lines)
            }
        }
        if let wave = mainWave(time: time, audio: audio, aspect: aspect) { result.lines.append(wave) }
        if v("ob_a") > 0, v("ob_size") > 0 {
            result.borders.append(.init(inset: 0, size: Float(v("ob_size")), color: SIMD4(Float(v("ob_r")), Float(v("ob_g")), Float(v("ob_b")), Float(v("ob_a")))))
        }
        if v("ib_a") > 0, v("ib_size") > 0 {
            result.borders.append(.init(
                inset: Float(max(0, v("ob_size"))), size: Float(v("ib_size")),
                color: SIMD4(Float(v("ib_r")), Float(v("ib_g")), Float(v("ib_b")), Float(v("ib_a")))))
        }
        return result
    }

    // MARK: - Warp mesh

    private func warpMesh(time: Double, q: [Double], aspect: SIMD2<Double>) -> [SIMD2<Float>] {
        var motion = Self.motionVariables.map { frameVars[$0] }
        let speed = frameVars["warpanimspeed"], scale = frameVars["warpscale"]
        let warpTime = time * speed
        let warpScaleInv = scale == 0 ? 1 : 1 / scale
        // The warp's four wobbling frequencies drift over time.
        let f0 = 11.68 + 4.0 * cos(warpTime * 1.413 + 10), f1 = 8.77 + 3.0 * cos(warpTime * 1.113 + 7)
        let f2 = 10.54 + 3.0 * cos(warpTime * 1.233 + 3), f3 = 11.49 + 4.0 * cos(warpTime * 0.933 + 5)

        var slots: [Int] = []
        if perPixel != nil {
            for name in Self.inputVariables { pixelVars[name] = frameVars[name] }
            for i in 1...32 { pixelVars["q\(i)"] = q[i - 1] }
            slots = Self.motionVariables.map(pixelVars.slot)
        }
        let xSlot = pixelVars.slot("x"), ySlot = pixelVars.slot("y"), radSlot = pixelVars.slot("rad"), angSlot = pixelVars.slot("ang")
        let frameMotion = motion

        var mesh: [SIMD2<Float>] = []
        mesh.reserveCapacity((meshWidth + 1) * (meshHeight + 1))
        for j in 0...meshHeight {
            for i in 0...meshWidth {
                let x = Double(i) / Double(meshWidth), y = Double(j) / Double(meshHeight)
                // Centered, aspect-corrected: circles stay round on wide screens.
                let vx = (x * 2 - 1) * aspect.x, vy = (y * 2 - 1) * aspect.y
                let rad = sqrt(vx * vx + vy * vy)
                var ang = atan2(-vy, vx)
                if ang < 0 { ang += 2 * .pi }
                if let perPixel {
                    pixelVars[xSlot] = x
                    pixelVars[ySlot] = y
                    pixelVars[radSlot] = rad
                    pixelVars[angSlot] = ang
                    for (k, slot) in slots.enumerated() { pixelVars[slot] = frameMotion[k] }
                    perPixel.run(pixelVars)
                    for (k, slot) in slots.enumerated() { motion[k] = pixelVars[slot] }
                }
                let (zoom, zoomExp, rot, warp, cx, cy, dx, dy, sx, sy) = (
                    motion[0], motion[1], motion[2], motion[3], motion[4], motion[5], motion[6], motion[7], motion[8], motion[9]
                )
                let zoom2 = pow(zoom, pow(zoomExp, rad * 2 - 1))
                let inverse = zoom2 == 0 || !zoom2.isFinite ? 1 : 1 / zoom2
                var u = vx * 0.5 * inverse + 0.5
                var v = vy * 0.5 * inverse + 0.5
                u = sx == 0 ? u : (u - cx) / sx + cx
                v = sy == 0 ? v : (v - cy) / sy + cy
                if warp != 0 {
                    u += warp * 0.0035 * sin(warpTime * 0.333 + warpScaleInv * (vx * f0 - vy * f3))
                    v += warp * 0.0035 * cos(warpTime * 0.375 - warpScaleInv * (vx * f2 + vy * f1))
                    u += warp * 0.0035 * cos(warpTime * 0.753 - warpScaleInv * (vx * f1 - vy * f2))
                    v += warp * 0.0035 * sin(warpTime * 0.825 + warpScaleInv * (vx * f0 + vy * f3))
                }
                let du = u - cx, dv = v - cy
                let c = cos(rot), s = sin(rot)
                u = du * c - dv * s + cx - dx
                v = du * s + dv * c + cy - dy
                // Back from the square space to the screen's.
                u = (u - 0.5) / aspect.x + 0.5
                v = (v - 0.5) / aspect.y + 0.5
                mesh.append(SIMD2(Float(u.isFinite ? u : 0.5), Float(v.isFinite ? v : 0.5)))
                if perPixel != nil { motion = frameMotion }
            }
        }
        return mesh
    }

    // MARK: - Main wave

    private func mainWave(time: Double, audio: MilkdropAudio, aspect: SIMD2<Double>) -> MilkdropFrame.Lines? {
        func v(_ name: String) -> Double { frameVars[name] }
        var alpha = v("wave_a")
        if preset.value("bmodwavealphabyvolume", 0) != 0 {
            let start = preset.value("fmodwavealphastart", 0.75), end = preset.value("fmodwavealphaend", 0.95)
            alpha *= min(1, max(0, (audio.volume - start) / max(0.01, end - start)))
        }
        guard alpha > 0.001 else { return nil }
        var color = SIMD3(v("wave_r"), v("wave_g"), v("wave_b")).clamped(lowerBound: .zero, upperBound: .one)
        if v("wave_brighten") >= 0.5, let top = [color.x, color.y, color.z].max(), top > 0.01 { color /= top }

        let scale = preset.value("fwavescale", 1)
        let samples = Self.smooth(audio.waveform.map(Double.init), amount: preset.value("fwavesmoothing", 0.75))
        let mystery = v("wave_mystery")
        let center = SIMD2(v("wave_x"), v("wave_y"))
        let mode = ((Int(v("wave_mode")) % 8) + 8) % 8
        let count = 288
        func sample(_ i: Int, _ offset: Int = 0) -> Double { samples[min(samples.count - 1, max(0, i * 2 + offset))] * scale }
        var points: [SIMD2<Double>] = []
        var kind = MilkdropFrame.Lines.Kind.strip
        switch mode {
        case 0:  // a ring breathing with the sound
            let radius = 0.25 + 0.15 * mystery
            for i in 0...count {
                let a = Double(i % count) / Double(count) * 2 * .pi
                let r = radius + 0.1 * sample(i)
                points.append(center + SIMD2(r * cos(a) / aspect.x * aspect.y, r * sin(a)))
            }
        case 1, 2, 3:  // the sound against itself a moment later
            for i in 0..<count {
                points.append(center + SIMD2(0.4 * sample(i), 0.4 * sample(i, 24)))
            }
            if mode != 1 { kind = .dots }
        case 4:  // a line across the screen
            for i in 0..<count {
                points.append(SIMD2(Double(i) / Double(count - 1), center.y + 0.25 * sample(i)))
            }
        case 5:  // the x-y figure, turning
            let a = time * 0.3 + mystery
            for i in 0..<count {
                let p = SIMD2(0.35 * sample(i), 0.35 * sample(i, 24))
                points.append(center + SIMD2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a)))
            }
        case 6:  // a tilted line through the center
            let a = mystery * .pi / 2
            let along = SIMD2(cos(a), sin(a)), across = SIMD2(-sin(a), cos(a))
            for i in 0..<count {
                let t = Double(i) / Double(count - 1) - 0.5
                points.append(center + along * t * 1.2 + across * 0.2 * sample(i))
            }
        default:  // two lines, above and below
            for i in 0..<count {
                points.append(SIMD2(Double(i) / Double(count - 1), center.y + 0.15 + 0.15 * sample(i)))
            }
            points.append(SIMD2(.nan, .nan))  // a break between the two
            for i in 0..<count {
                points.append(SIMD2(Double(i) / Double(count - 1), center.y - 0.15 + 0.15 * sample(i, 24)))
            }
        }
        if v("wave_usedots") >= 0.5 { kind = .dots }
        let rgba = SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(min(1, alpha)))
        return MilkdropFrame.Lines(
            kind: kind, points: points.map { SIMD2(Float($0.x), Float($0.y)) }, colors: Array(repeating: rgba, count: points.count),
            thick: v("wave_thick") >= 0.5, additive: v("wave_additive") >= 0.5)
    }

    /// A light low-pass over the samples; 0 = raw, towards 1 = smoother.
    static func smooth(_ values: [Double], amount: Double) -> [Double] {
        let k = min(0.95, max(0, amount))
        guard k > 0, !values.isEmpty else { return values }
        var out = values
        for i in 1..<out.count { out[i] = out[i - 1] * k + out[i] * (1 - k) }
        for i in stride(from: out.count - 2, through: 0, by: -1) { out[i] = out[i + 1] * k + out[i] * (1 - k) }
        return out
    }

    // MARK: - Motion vectors

    /// Short lines showing where the image flows, on a grid.
    private func motionVectors(_ frame: MilkdropFrame) -> MilkdropFrame.Lines? {
        let alpha = frameVars["mv_a"]
        let columns = Int(frameVars["mv_x"]), rows = Int(frameVars["mv_y"])
        guard alpha > 0.001, columns > 0, rows > 0, columns * rows <= 64 * 48 else { return nil }
        let length = frameVars["mv_l"], offset = SIMD2(frameVars["mv_dx"], frameVars["mv_dy"])
        let color = SIMD4(Float(frameVars["mv_r"]), Float(frameVars["mv_g"]), Float(frameVars["mv_b"]), Float(min(1, alpha)))
        var points: [SIMD2<Float>] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let x = (Double(i) + 0.5) / Double(columns) + offset.x, y = (Double(j) + 0.5) / Double(rows) + offset.y
                guard (0...1).contains(x), (0...1).contains(y) else { continue }
                // Where the mesh sends this point (texture v runs down, screen y up).
                let uv = sampleMesh(frame, x: x, y: 1 - y)
                let moved = SIMD2(Double(uv.x), 1 - Double(uv.y))
                let delta = (SIMD2(x, y) - moved) * length
                points.append(SIMD2(Float(x), Float(y)))
                points.append(SIMD2(Float(x - delta.x), Float(y - delta.y)))
            }
        }
        return MilkdropFrame.Lines(kind: .segments, points: points, colors: Array(repeating: color, count: points.count))
    }

    private func sampleMesh(_ frame: MilkdropFrame, x: Double, y: Double) -> SIMD2<Float> {
        let fx = x * Double(meshWidth), fy = y * Double(meshHeight)
        let i = min(meshWidth - 1, max(0, Int(fx))), j = min(meshHeight - 1, max(0, Int(fy)))
        let tx = Float(fx - Double(i)), ty = Float(fy - Double(j))
        let row = meshWidth + 1
        let a = frame.warp[j * row + i], b = frame.warp[j * row + i + 1]
        let c = frame.warp[(j + 1) * row + i], d = frame.warp[(j + 1) * row + i + 1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }
}

// MARK: - Custom waves and shapes

/// Base values reset every frame, then per-frame code runs; t1...t8 carry
/// what the init code left.
private struct WaveRuntime {
    let wave: MilkdropPreset.Wave
    let vars: EELVariables
    let initCode: EELProgram?
    let perFrame: EELProgram?
    let perPoint: EELProgram?
    var tAfterInit = [Double](repeating: 0, count: 8)

    static let bases: [(String, Double)] = [
        ("samples", 512), ("sep", 0), ("bspectrum", 0), ("busedots", 0), ("bdrawthick", 0), ("badditive", 0),
        ("scaling", 1), ("smoothing", 0.5), ("r", 1), ("g", 1), ("b", 1), ("a", 1),
    ]

    private func reset() {
        for (name, fallback) in Self.bases { vars[name] = wave.values[name] ?? fallback }
    }

    mutating func runInit(q: [Double]) {
        reset()
        for i in 0..<32 { vars["q\(i + 1)"] = q[i] }
        initCode?.run(vars)
        tAfterInit = (1...8).map { vars["t\($0)"] }
    }

    mutating func frame(q: [Double], audio: MilkdropAudio, setInputs: (EELVariables) -> Void) -> MilkdropFrame.Lines? {
        reset()
        setInputs(vars)
        for i in 0..<32 { vars["q\(i + 1)"] = q[i] }
        for i in 0..<8 { vars["t\(i + 1)"] = tAfterInit[i] }
        perFrame?.run(vars)
        let count = min(512, max(0, Int(vars["samples"])))
        guard count >= 2 else { return nil }
        let spectrum = vars["bspectrum"] >= 0.5
        let separation = Int(vars["sep"]), scaling = vars["scaling"]
        let source: [Double] =
            spectrum
            ? audio.spectrum.map { Double($0) * 20 } : audio.waveform.map(Double.init)
        let data = MilkdropEngine.smooth(source, amount: vars["smoothing"])
        func value(_ i: Int) -> Double { data.isEmpty ? 0 : data[min(data.count - 1, max(0, i))] * scaling }
        let color = (vars["r"], vars["g"], vars["b"], vars["a"])
        let slots = ["sample", "value1", "value2", "x", "y", "r", "g", "b", "a"].map(vars.slot)

        var points: [SIMD2<Float>] = [], colors: [SIMD4<Float>] = []
        for i in 0..<count {
            let sample = Double(i) / Double(count - 1)
            let index = Int(sample * Double(data.count - 1 - max(0, separation)))
            let value1 = value(index), value2 = value(index + separation)
            vars[slots[0]] = sample
            vars[slots[1]] = value1
            vars[slots[2]] = value2
            vars[slots[3]] = sample
            vars[slots[4]] = 0.5 + value1 * 0.5
            vars[slots[5]] = color.0
            vars[slots[6]] = color.1
            vars[slots[7]] = color.2
            vars[slots[8]] = color.3
            perPoint?.run(vars)
            points.append(SIMD2(Float(vars[slots[3]]), Float(vars[slots[4]])))
            colors.append(SIMD4(Float(vars[slots[5]]), Float(vars[slots[6]]), Float(vars[slots[7]]), Float(min(1, max(0, vars[slots[8]])))))
        }
        return MilkdropFrame.Lines(
            kind: vars["busedots"] >= 0.5 ? .dots : .strip, points: points, colors: colors,
            thick: vars["bdrawthick"] >= 0.5, additive: vars["badditive"] >= 0.5)
    }
}

private struct ShapeRuntime {
    let shape: MilkdropPreset.Shape
    let vars: EELVariables
    let initCode: EELProgram?
    let perFrame: EELProgram?
    var tAfterInit = [Double](repeating: 0, count: 8)

    static let bases: [(String, Double)] = [
        ("sides", 4), ("additive", 0), ("thickoutline", 0), ("textured", 0), ("num_inst", 1),
        ("x", 0.5), ("y", 0.5), ("rad", 0.1), ("ang", 0), ("tex_ang", 0), ("tex_zoom", 1),
        ("r", 1), ("g", 0), ("b", 0), ("a", 1), ("r2", 0), ("g2", 1), ("b2", 0), ("a2", 0),
        ("border_r", 1), ("border_g", 1), ("border_b", 1), ("border_a", 0.1),
    ]

    private func reset() {
        for (name, fallback) in Self.bases { vars[name] = shape.values[name] ?? fallback }
    }

    mutating func runInit(q: [Double]) {
        reset()
        for i in 0..<32 { vars["q\(i + 1)"] = q[i] }
        initCode?.run(vars)
        tAfterInit = (1...8).map { vars["t\($0)"] }
    }

    func frame(q: [Double], setInputs: (EELVariables) -> Void) -> [MilkdropFrame.Shape] {
        let instances = min(1024, max(1, Int(shape.values["num_inst"] ?? 1)))
        var result: [MilkdropFrame.Shape] = []
        for instance in 0..<instances {
            reset()
            setInputs(vars)
            for i in 0..<32 { vars["q\(i + 1)"] = q[i] }
            for i in 0..<8 { vars["t\(i + 1)"] = tAfterInit[i] }
            vars["instance"] = Double(instance)
            perFrame?.run(vars)
            func color(_ prefix: String, _ alpha: String) -> SIMD4<Float> {
                SIMD4(Float(vars[prefix + "r"]), Float(vars[prefix + "g"]), Float(vars[prefix + "b"]), Float(min(1, max(0, vars[alpha]))))
            }
            let sides = min(100, max(3, Int(vars["sides"])))
            result.append(MilkdropFrame.Shape(
                center: SIMD2(Float(vars["x"]), Float(vars["y"])), radius: Float(vars["rad"]), angle: Float(vars["ang"]), sides: sides,
                centerColor: color("", "a"),
                edgeColor: SIMD4(Float(vars["r2"]), Float(vars["g2"]), Float(vars["b2"]), Float(min(1, max(0, vars["a2"])))),
                borderColor: SIMD4(Float(vars["border_r"]), Float(vars["border_g"]), Float(vars["border_b"]), Float(min(1, max(0, vars["border_a"])))),
                additive: vars["additive"] >= 0.5, thickBorder: vars["thickoutline"] >= 0.5, textured: vars["textured"] >= 0.5,
                textureZoom: Float(vars["tex_zoom"]), textureAngle: Float(vars["tex_ang"])))
        }
        return result
    }
}
