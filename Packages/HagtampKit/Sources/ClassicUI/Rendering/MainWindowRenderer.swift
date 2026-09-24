import SkinKit

/// Draws the main window: 275x116, or 275x14 in shade mode.
///
/// Element positions follow Webamp's main-window.css (MIT, see
/// THIRD_PARTY_NOTICES.md), itself measured against Winamp 2.9.
public enum MainWindowRenderer {
    public static let width = 275
    public static let height = 116
    public static let shadeHeight = 14

    /// Where the visualizer draws (76x16).
    public static let visualizerRect = PixelRect(x: 24, y: 43, width: 76, height: 16)
    /// 31 glyphs of the TEXT.BMP font.
    public static let marqueeRect = PixelRect(x: 111, y: 27, width: 155, height: 6)

    public static func render(_ skin: Skin, _ state: MainWindowState) -> Bitmap {
        if state.shade { return renderShade(skin, state) }

        var canvas = Bitmap(width: width, height: height, fill: .black)
        canvas.draw(skin, Sprite.Main.background, x: 0, y: 0)
        canvas.draw(skin, state.focused ? Sprite.TitleBar.active : Sprite.TitleBar.inactive, x: 0, y: 0)
        drawTitleButtons(&canvas, skin, state)

        drawClutterBar(&canvas, skin, state)
        drawStatus(&canvas, skin, state)
        drawTime(&canvas, skin, state)
        drawInfo(&canvas, skin, state)
        drawSliders(&canvas, skin, state)
        drawButtons(&canvas, skin, state)
        return canvas
    }

    /// Title bar buttons are part of the title bar image; only pressed ones are drawn.
    private static func drawTitleButtons(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        switch state.pressed {
        case .options: canvas.draw(skin, Sprite.TitleBar.optionsPressed, x: 6, y: 3)
        case .minimize: canvas.draw(skin, Sprite.TitleBar.minimizePressed, x: 244, y: 3)
        case .shade: canvas.draw(skin, Sprite.TitleBar.shadePressed, x: 254, y: 3)
        case .close: canvas.draw(skin, Sprite.TitleBar.closePressed, x: 264, y: 3)
        default: break
        }
    }

    private static func drawClutterBar(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        canvas.draw(skin, Sprite.TitleBar.clutterBar, x: 10, y: 22)
        let buttons: [(Control, Sprite, Int, Bool)] = [
            (.clutterOptions, Sprite.TitleBar.clutterO, 25, false),
            (.clutterAlwaysOnTop, Sprite.TitleBar.clutterA, 33, state.alwaysOnTop),
            (.clutterInfo, Sprite.TitleBar.clutterI, 40, false),
            (.clutterDoubleSize, Sprite.TitleBar.clutterD, 47, state.doubleSize),
            (.clutterVisualization, Sprite.TitleBar.clutterV, 55, false),
        ]
        for (control, sprite, y, on) in buttons where on || state.pressed == control {
            canvas.draw(skin, sprite, x: 10, y: y)
        }
    }

    private static func drawStatus(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        let icon: Sprite
        switch state.status {
        case .playing: icon = Sprite.PlayPaus.playing
        case .paused: icon = Sprite.PlayPaus.paused
        case .stopped: icon = Sprite.PlayPaus.stopped
        }
        canvas.draw(skin, icon, x: 26, y: 28)
        if state.status == .playing {
            let indicator = state.working ? Sprite.PlayPaus.working : Sprite.PlayPaus.notWorking
            canvas.draw(skin, indicator, x: 24, y: 28, width: 3, height: 9)
        }
    }

    private static func drawTime(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        guard state.status != .stopped, let time = state.time else { return }
        let numsEx = skin.usesNumsEx
        let remaining = time.mode == .remaining
        if numsEx {
            canvas.draw(skin, remaining ? Sprite.NumsEx.minus : Sprite.NumsEx.noMinus, x: 38, y: 26)
        } else {
            canvas.draw(skin, remaining ? Sprite.Numbers.minus : Sprite.Numbers.noMinus, x: 38, y: 32)
        }
        for (digit, x) in zip(time.digits, [48, 60, 78, 90]) {
            canvas.draw(skin, numsEx ? Sprite.NumsEx.digit(digit) : Sprite.Numbers.digit(digit), x: x, y: 26)
        }
    }

    private static func drawInfo(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        let marquee = Marquee.displayText(state.marqueeText)
        canvas.drawText(skin, marquee, x: marqueeRect.x - state.marqueeOffset, y: marqueeRect.y, clip: marqueeRect)

        let playing = state.status != .stopped
        if playing {
            canvas.drawText(skin, state.kbps ?? "", x: 111, y: 43, width: 15)
            canvas.drawText(skin, state.khz ?? "", x: 156, y: 43, width: 10)
        }
        let stereo = playing && state.channels == 2
        let mono = playing && state.channels == 1
        canvas.draw(skin, stereo ? Sprite.MonoSter.stereoOn : Sprite.MonoSter.stereo, x: 239, y: 41)
        canvas.draw(skin, mono ? Sprite.MonoSter.monoOn : Sprite.MonoSter.mono, x: 212, y: 41)
    }

    private static func drawSliders(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        // Volume: 28 frames, 15 px apart, of which 13 rows show.
        let volume = min(1, max(0, state.volume))
        let volumeFrame = max(0, Int((volume * 28).rounded()) - 1)
        canvas.draw(skin, frame(Sprite.Volume.background, index: volumeFrame, width: 68), x: 107, y: 57, width: 68, height: 13)
        let volumeThumb = state.pressed == .volume ? Sprite.Volume.thumbPressed : Sprite.Volume.thumb
        canvas.draw(skin, volumeThumb, x: MainWindowLayout.volume.thumbPosition(volume), y: 58)

        let balance = min(1, max(-1, state.balance))
        let balanceFrame = Int(abs(balance) * 27)
        let fromVolume = skin.balanceUsesVolume
        let balanceStrip = fromVolume ? Sprite.Volume.background : Sprite.Balance.background
        canvas.draw(skin, frame(balanceStrip, index: balanceFrame, width: 38), x: 177, y: 57, width: 38, height: 13)
        let balancePressed = state.pressed == .balance
        let balanceThumb =
            fromVolume
            ? (balancePressed ? Sprite.Volume.thumbPressed : Sprite.Volume.thumb)
            : (balancePressed ? Sprite.Balance.thumbPressed : Sprite.Balance.thumb)
        canvas.draw(skin, balanceThumb, x: MainWindowLayout.balance.thumbPosition((balance + 1) / 2), y: 58)

        canvas.draw(skin, Sprite.PosBar.background, x: 16, y: 72)
        if state.status != .stopped, let position = state.position {
            let thumb = state.pressed == .position ? Sprite.PosBar.thumbPressed : Sprite.PosBar.thumb
            canvas.draw(skin, thumb, x: MainWindowLayout.position.thumbPosition(position), y: 72)
        }
    }

    private static func drawButtons(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        let p = state.pressed
        let eq: Sprite =
            state.equalizerOpen
            ? (p == .equalizerToggle ? Sprite.ShufRep.eqOnPressed : Sprite.ShufRep.eqOn)
            : (p == .equalizerToggle ? Sprite.ShufRep.eqPressed : Sprite.ShufRep.eq)
        canvas.draw(skin, eq, x: 219, y: 58)
        let playlist: Sprite =
            state.playlistOpen
            ? (p == .playlistToggle ? Sprite.ShufRep.playlistOnPressed : Sprite.ShufRep.playlistOn)
            : (p == .playlistToggle ? Sprite.ShufRep.playlistPressed : Sprite.ShufRep.playlist)
        canvas.draw(skin, playlist, x: 242, y: 58)

        let transport: [(Control, Sprite, Sprite, Int)] = [
            (.previous, Sprite.CButtons.previous, Sprite.CButtons.previousPressed, 16),
            (.play, Sprite.CButtons.play, Sprite.CButtons.playPressed, 39),
            (.pause, Sprite.CButtons.pause, Sprite.CButtons.pausePressed, 62),
            (.stop, Sprite.CButtons.stop, Sprite.CButtons.stopPressed, 85),
            (.next, Sprite.CButtons.next, Sprite.CButtons.nextPressed, 108),
        ]
        for (control, normal, pressed, x) in transport {
            canvas.draw(skin, p == control ? pressed : normal, x: x, y: 88)
        }
        canvas.draw(skin, p == .eject ? Sprite.CButtons.ejectPressed : Sprite.CButtons.eject, x: 136, y: 89)

        let shuffle: Sprite =
            state.shuffle
            ? (p == .shuffle ? Sprite.ShufRep.shuffleOnPressed : Sprite.ShufRep.shuffleOn)
            : (p == .shuffle ? Sprite.ShufRep.shufflePressed : Sprite.ShufRep.shuffle)
        canvas.draw(skin, shuffle, x: 164, y: 89)
        let repeatSprite: Sprite =
            state.repeatEnabled
            ? (p == .repeatToggle ? Sprite.ShufRep.repeatOnPressed : Sprite.ShufRep.repeatOn)
            : (p == .repeatToggle ? Sprite.ShufRep.repeatPressed : Sprite.ShufRep.repeatOff)
        canvas.draw(skin, repeatSprite, x: 210, y: 89)
    }

    // MARK: - Shade mode

    private static func renderShade(_ skin: Skin, _ state: MainWindowState) -> Bitmap {
        var canvas = Bitmap(width: width, height: shadeHeight, fill: .black)
        canvas.draw(skin, state.focused ? Sprite.TitleBar.shadeActive : Sprite.TitleBar.shadeInactive, x: 0, y: 0)

        switch state.pressed {
        case .options: canvas.draw(skin, Sprite.TitleBar.optionsPressed, x: 6, y: 3)
        case .minimize: canvas.draw(skin, Sprite.TitleBar.minimizePressed, x: 244, y: 3)
        case .close: canvas.draw(skin, Sprite.TitleBar.closePressed, x: 264, y: 3)
        default: break
        }
        if state.pressed == .shade {
            canvas.draw(skin, Sprite.TitleBar.unshadePressed, x: 254, y: 3)
        } else if state.focused {
            canvas.draw(skin, Sprite.TitleBar.unshade, x: 254, y: 3)
        }

        let time = state.status == .stopped ? nil : state.time
        drawMiniTime(&canvas, skin, time, x: 127, y: 4)

        canvas.draw(skin, Sprite.TitleBar.shadePositionBackground, x: 226, y: 4)
        if state.status != .stopped, let position = state.position {
            let p = min(1, max(0, position))
            let thumb =
                p <= 1.0 / 3 ? Sprite.TitleBar.shadePositionThumbLeft
                : p >= 2.0 / 3 ? Sprite.TitleBar.shadePositionThumbRight : Sprite.TitleBar.shadePositionThumb
            canvas.draw(skin, thumb, x: MainWindowLayout.shadePosition.thumbPosition(p), y: 4)
        }
        return canvas
    }

    /// The small "-MM:SS" display in TEXT.BMP glyphs (main shade and playlist).
    /// The colon is part of the background image; blank slots are painted with spaces.
    static func drawMiniTime(_ canvas: inout Bitmap, _ skin: Skin, _ time: TimeDisplay?, x: Int, y: Int) {
        let slots = [1, 7, 12, 20, 25]
        for slot in slots { canvas.drawText(skin, " ", x: x + slot, y: y) }
        guard let time else { return }
        let characters = [time.mode == .remaining ? "-" : " "] + time.digits.map(String.init)
        for (character, slot) in zip(characters, slots) {
            canvas.drawText(skin, character, x: x + slot, y: y)
        }
    }

    /// The `index`-th frame of a vertical filmstrip with 15 px pitch.
    private static func frame(_ strip: Sprite, index: Int, width: Int) -> Sprite {
        Sprite(strip.sheet, strip.rect.x, strip.rect.y + index * 15, width, 15)
    }
}
