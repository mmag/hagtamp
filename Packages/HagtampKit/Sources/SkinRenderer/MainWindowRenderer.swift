import SkinKit

/// Draws the main window (275x116) in normal (non-shade) mode.
///
/// Element positions follow Webamp's main-window.css (MIT, see
/// THIRD_PARTY_NOTICES.md), itself measured against Winamp 2.9.
public enum MainWindowRenderer {
    public static let width = 275
    public static let height = 116

    /// Where the visualizer draws (76x16).
    public static let visualizerRect = PixelRect(x: 24, y: 43, width: 76, height: 16)
    public static let marqueeRect = PixelRect(x: 111, y: 27, width: 155, height: 6)

    public static func render(_ skin: Skin, _ state: MainWindowState) -> Bitmap {
        var canvas = Bitmap(width: width, height: height, fill: .black)
        canvas.draw(skin, Sprite.Main.background, x: 0, y: 0)
        canvas.draw(skin, state.focused ? Sprite.TitleBar.active : Sprite.TitleBar.inactive, x: 0, y: 0)

        drawClutterBar(&canvas, skin, state)
        drawStatus(&canvas, skin, state)
        drawTime(&canvas, skin, state)
        drawInfo(&canvas, skin, state)
        drawSliders(&canvas, skin, state)
        drawButtons(&canvas, skin, state)
        return canvas
    }

    private static func drawClutterBar(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        canvas.draw(skin, Sprite.TitleBar.clutterBar, x: 10, y: 22)
        if state.doubleSize {
            canvas.draw(skin, Sprite.TitleBar.clutterD, x: 10, y: 47)
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
        canvas.draw(skin, Sprite.Volume.thumb, x: 107 + Int((volume * 51).rounded()), y: 58)

        let balance = min(1, max(-1, state.balance))
        let balanceFrame = Int(abs(balance) * 27)
        let fromVolume = skin.balanceUsesVolume
        let balanceStrip = fromVolume ? Sprite.Volume.background : Sprite.Balance.background
        canvas.draw(skin, frame(balanceStrip, index: balanceFrame, width: 38), x: 177, y: 57, width: 38, height: 13)
        let balanceThumb = fromVolume ? Sprite.Volume.thumb : Sprite.Balance.thumb
        canvas.draw(skin, balanceThumb, x: 177 + Int(((balance + 1) / 2 * 24).rounded()), y: 58)

        canvas.draw(skin, Sprite.PosBar.background, x: 16, y: 72)
        if state.status != .stopped, let position = state.position {
            let x = 16 + Int((min(1, max(0, position)) * 219).rounded())
            canvas.draw(skin, Sprite.PosBar.thumb, x: x, y: 72)
        }
    }

    private static func drawButtons(_ canvas: inout Bitmap, _ skin: Skin, _ state: MainWindowState) {
        canvas.draw(skin, state.equalizerOpen ? Sprite.ShufRep.eqOn : Sprite.ShufRep.eq, x: 219, y: 58)
        canvas.draw(skin, state.playlistOpen ? Sprite.ShufRep.playlistOn : Sprite.ShufRep.playlist, x: 242, y: 58)

        canvas.draw(skin, Sprite.CButtons.previous, x: 16, y: 88)
        canvas.draw(skin, Sprite.CButtons.play, x: 39, y: 88)
        canvas.draw(skin, Sprite.CButtons.pause, x: 62, y: 88)
        canvas.draw(skin, Sprite.CButtons.stop, x: 85, y: 88)
        canvas.draw(skin, Sprite.CButtons.next, x: 108, y: 88)
        canvas.draw(skin, Sprite.CButtons.eject, x: 136, y: 89)

        canvas.draw(skin, state.shuffle ? Sprite.ShufRep.shuffleOn : Sprite.ShufRep.shuffle, x: 164, y: 89)
        canvas.draw(skin, state.repeatEnabled ? Sprite.ShufRep.repeatOn : Sprite.ShufRep.repeatOff, x: 210, y: 89)
    }

    /// The `index`-th frame of a vertical filmstrip with 15 px pitch.
    private static func frame(_ strip: Sprite, index: Int, width: Int) -> Sprite {
        Sprite(strip.sheet, strip.rect.x, strip.rect.y + index * 15, width, 15)
    }
}
