import SkinKit

/// Draws the equalizer window: 275x116, or 275x14 in shade mode.
///
/// Layout from Webamp's equalizer-window.css (MIT, see THIRD_PARTY_NOTICES.md).
public enum EqualizerWindowRenderer {
    public static let width = 275
    public static let height = 116
    public static let shadeHeight = 14

    public static let preampX = 21
    public static let bandX = (0..<10).map { 78 + $0 * 18 }
    public static let sliderY = 38

    public static func render(_ skin: Skin, _ state: EqualizerWindowState) -> Bitmap {
        if state.shade { return renderShade(skin, state) }

        var canvas = Bitmap(width: width, height: height, fill: .black)
        canvas.draw(skin, Sprite.EqMain.background, x: 0, y: 0)
        canvas.draw(skin, state.focused ? Sprite.EqMain.titleBarActive : Sprite.EqMain.titleBar, x: 0, y: 0)
        let p = state.pressed
        if p == .shade {
            // Skins without EQ_EX.BMP show their own title bar there instead of the base skin's sprite.
            let sprite = skin.inheritedSheets.contains(.eqEx) ? Sprite.EqMain.maximizePressedFallback : Sprite.EqEx.maximizePressed
            canvas.draw(skin, sprite, x: 254, y: 3)
        }
        if p == .close { canvas.draw(skin, Sprite.EqMain.closePressed, x: 264, y: 3) }

        let on: Sprite =
            state.enabled
            ? (p == .equalizerOn ? Sprite.EqMain.onSelectedPressed : Sprite.EqMain.onSelected)
            : (p == .equalizerOn ? Sprite.EqMain.onPressed : Sprite.EqMain.on)
        canvas.draw(skin, on, x: 14, y: 18)
        let auto: Sprite =
            state.auto
            ? (p == .equalizerAuto ? Sprite.EqMain.autoSelectedPressed : Sprite.EqMain.autoSelected)
            : (p == .equalizerAuto ? Sprite.EqMain.autoPressed : Sprite.EqMain.auto)
        canvas.draw(skin, auto, x: 40, y: 18)
        drawGraph(&canvas, skin, state)
        canvas.draw(skin, p == .presets ? Sprite.EqMain.presetsPressed : Sprite.EqMain.presets, x: 217, y: 18)

        drawSlider(&canvas, skin, value: state.preamp, x: preampX, pressed: p == .preamp)
        for (i, (value, x)) in zip(state.bands, bandX).enumerated() {
            drawSlider(&canvas, skin, value: value, x: x, pressed: p == .band(i))
        }
        return canvas
    }

    /// A vertical slider: one of 28 background frames (two rows of 14) plus the thumb.
    private static func drawSlider(_ canvas: inout Bitmap, _ skin: Skin, value: Double, x: Int, pressed: Bool) {
        let value = min(1, max(0, value))
        let frame = frameIndex(value, frames: 28)
        let strip = Sprite.EqMain.sliderBackground.rect
        let background = Sprite(.eqmain, strip.x + (frame % 14) * 15, strip.y + (frame / 14) * 65, 14, 63)
        canvas.draw(skin, background, x: x, y: sliderY)
        let thumb = pressed ? Sprite.EqMain.sliderThumbPressed : Sprite.EqMain.sliderThumb
        canvas.draw(skin, thumb, x: x + 1, y: EqualizerWindowLayout.band.thumbPosition(value))
    }

    private static func renderShade(_ skin: Skin, _ state: EqualizerWindowState) -> Bitmap {
        var canvas = Bitmap(width: width, height: shadeHeight, fill: .black)
        canvas.draw(skin, state.focused ? Sprite.EqEx.shadeActive : Sprite.EqEx.shadeInactive, x: 0, y: 0)
        if state.pressed == .shade { canvas.draw(skin, Sprite.EqEx.minimizePressed, x: 254, y: 3) }
        if state.pressed == .close { canvas.draw(skin, Sprite.EqEx.shadeClosePressed, x: 264, y: 3) }

        // The thumbs change shape with the third of the range they are in.
        func third(_ v: Double) -> Int { v < 1.0 / 3 ? 0 : v < 2.0 / 3 ? 1 : 2 }
        let volume = min(1, max(0, state.volume))
        let volumeThumbs = [Sprite.EqEx.shadeVolumeThumbLeft, Sprite.EqEx.shadeVolumeThumbCenter, Sprite.EqEx.shadeVolumeThumbRight]
        canvas.draw(skin, volumeThumbs[third(volume)], x: EqualizerWindowLayout.shadeVolume.thumbPosition(volume), y: 4)
        let balance = (min(1, max(-1, state.balance)) + 1) / 2
        let balanceThumbs = [Sprite.EqEx.shadeBalanceThumbLeft, Sprite.EqEx.shadeBalanceThumbCenter, Sprite.EqEx.shadeBalanceThumbRight]
        canvas.draw(skin, balanceThumbs[third(balance)], x: EqualizerWindowLayout.shadeBalance.thumbPosition(balance), y: 4)
        return canvas
    }

    static let graphOrigin = (x: 86, y: 17)
    static let graphHeight = 19

    /// The response curve: a natural cubic spline through the ten bands,
    /// coloured row by row from the skin's 1x19 colour strip.
    private static func drawGraph(_ canvas: inout Bitmap, _ skin: Skin, _ state: EqualizerWindowState) {
        let (ox, oy) = graphOrigin
        canvas.draw(skin, Sprite.EqMain.graphBackground, x: ox, y: oy)

        let maxY = graphHeight - 1
        // TODO: Verify against Reamp/Winamp: Webamp draws the preamp line upside down
        // relative to the slider; we draw it where the slider points.
        let preampY = Int(((1 - min(1, max(0, state.preamp))) * Double(maxY)).rounded())
        canvas.draw(skin, Sprite.EqMain.preampLine, x: ox, y: oy + preampY)

        guard let colors = skin.bitmap(.eqmain) else { return }
        let colorColumn = Sprite.EqMain.graphLineColors.rect
        func color(row: Int) -> PixelColor? {
            let y = colorColumn.y + row
            guard colorColumn.x < colors.width, y < colors.height else { return nil }
            return colors[colorColumn.x, y]
        }

        let xs = (0..<state.bands.count).map { Double($0 * 12) }
        let ys = state.bands.map { (1 - min(1, max(0, $0))) * Double(maxY) }
        let curve = NaturalSpline(xs: xs, ys: ys)
        let paddingLeft = 2
        var lastY = Int(ys[0].rounded())
        for x in 0...Int(xs.last ?? 0) {
            let y = min(maxY, max(0, Int(curve.value(at: Double(x)).rounded())))
            for row in min(y, lastY)...max(y, lastY) {
                if let c = color(row: row) {
                    canvas[ox + paddingLeft + x, oy + row] = c
                }
            }
            lastY = y
        }
    }
}

/// Natural cubic spline, as used by Webamp's EQ graph.
struct NaturalSpline {
    let xs: [Double]
    let ys: [Double]
    let ks: [Double]

    init(xs: [Double], ys: [Double]) {
        self.xs = xs
        self.ys = ys
        ks = Self.slopes(xs, ys)
    }

    func value(at x: Double) -> Double {
        var i = 1
        while i < xs.count - 1, xs[i] < x { i += 1 }
        let dx = xs[i] - xs[i - 1], dy = ys[i] - ys[i - 1]
        let t = (x - xs[i - 1]) / dx
        let a = ks[i - 1] * dx - dy
        let b = -ks[i] * dx + dy
        return (1 - t) * ys[i - 1] + t * ys[i] + t * (1 - t) * (a * (1 - t) + b * t)
    }

    /// Solves the tridiagonal system for the knot slopes (natural end conditions).
    private static func slopes(_ xs: [Double], _ ys: [Double]) -> [Double] {
        let n = xs.count - 1
        guard n >= 1 else { return xs.map { _ in 0 } }
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 2), count: n + 1)
        for i in 1..<max(1, n) {
            let l = 1 / (xs[i] - xs[i - 1]), r = 1 / (xs[i + 1] - xs[i])
            m[i][i - 1] = l
            m[i][i] = 2 * (l + r)
            m[i][i + 1] = r
            m[i][n + 1] = 3 * ((ys[i] - ys[i - 1]) * l * l + (ys[i + 1] - ys[i]) * r * r)
        }
        let first = 1 / (xs[1] - xs[0]), last = 1 / (xs[n] - xs[n - 1])
        m[0][0] = 2 * first
        m[0][1] = first
        m[0][n + 1] = 3 * (ys[1] - ys[0]) * first * first
        m[n][n - 1] = last
        m[n][n] = 2 * last
        m[n][n + 1] = 3 * (ys[n] - ys[n - 1]) * last * last

        // Gaussian elimination with partial pivoting.
        let size = n + 1
        for k in 0..<size {
            let pivot = (k..<size).max { abs(m[$0][k]) < abs(m[$1][k]) }!
            m.swapAt(k, pivot)
            for i in (k + 1)..<size {
                let f = m[i][k] / m[k][k]
                for j in k...(size) { m[i][j] -= m[k][j] * f }
            }
        }
        var ks = [Double](repeating: 0, count: size)
        for i in stride(from: size - 1, through: 0, by: -1) {
            var sum = m[i][size]
            for j in (i + 1)..<size { sum -= m[i][j] * ks[j] }
            ks[i] = sum / m[i][i]
        }
        return ks
    }
}
