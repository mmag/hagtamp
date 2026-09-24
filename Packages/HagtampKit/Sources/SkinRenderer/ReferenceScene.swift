import Foundation
import SkinKit

/// The fixed player state the Winamp Skin Museum screenshots are taken in
/// (Webamp's `?screenshot=1` mode), so our renders can be diffed against them.
///
/// Layout: main window, equalizer and playlist stacked into a 275x348 image,
/// transparent outside the windows' regions.
public enum ReferenceScene {
    public static let width = 275
    public static let height = 348

    public static let tracks: [(artist: String, title: String, seconds: Int)] = [
        ("DJ Mike Llama", "Llama Whipping Intro", 5),
        ("Marilyn Manson", "Rock Is Dead", 191),
        ("Propellerheads", "Spybreak! (Short One)", 240),
        ("Ministry", "Bad Blood", 300),
    ]

    public static var mainState: MainWindowState {
        var state = MainWindowState()
        state.focused = true
        state.status = .playing
        state.time = TimeDisplay(seconds: 3)
        state.marqueeText = "1. DJ Mike Llama - Llama Whipping Intro (0:05)"
        state.kbps = "128"
        state.khz = "44"
        state.channels = 2
        state.volume = 0.78
        state.balance = 0
        state.position = 0.6
        state.shuffle = true
        state.repeatEnabled = true
        state.equalizerOpen = true
        state.playlistOpen = true
        return state
    }

    public static var equalizerState: EqualizerWindowState {
        var state = EqualizerWindowState()
        state.focused = false
        state.enabled = true
        state.auto = true
        state.preamp = 0.56
        state.bands = [52, 74, 83, 91, 80, 54, 23, 19, 34, 75].map { Double($0) / 100 }
        return state
    }

    public static var playlistState: PlaylistWindowState {
        var state = PlaylistWindowState()
        state.rows = tracks.enumerated().map { i, track in
            PlaylistRow(title: "\(i + 1). \(track.artist) - \(track.title)", duration: formatTime(track.seconds))
        }
        state.currentRow = 0
        state.selectedRows = [2]
        state.runningTime = "\(formatTime(tracks[2].seconds))/\(formatTime(tracks.map(\.seconds).reduce(0, +)))"
        state.miniTime = TimeDisplay(seconds: 3)
        return state
    }

    /// Regions of the composite that are not expected to match the museum
    /// screenshots.
    public static let volatileRects: [PixelRect] = [
        // Webamp renders live data we don't reproduce (dummy visualizer data,
        // track list in the browser's font).
        MainWindowRenderer.visualizerRect,
        PixelRect(x: 12, y: 232 + 20, width: 243, height: 58),
        // Deliberate deviations from Webamp, pending verification against Reamp:
        // Winamp paints the blank "no minus" glyph in elapsed mode, Webamp leaves the background.
        PixelRect(x: 38, y: 26, width: 9, height: 13),
        // Museum screenshots disagree on the marquee's last column (Webamp versions
        // differ between 154 and 155 px); we use 31 characters = 155 px.
        PixelRect(x: 265, y: 27, width: 1, height: 6),
        // Webamp's EQ graph is an approximation (inverted preamp line, different curve).
        PixelRect(x: 86, y: 116 + 17, width: 113, height: 19),
    ]

    public static func render(_ skin: Skin) -> Bitmap {
        var scene = Bitmap(width: width, height: height)

        var main = MainWindowRenderer.render(skin, mainState)
        if let region = skin.regions.main {
            main.apply(mask: SkinRegions.mask(region, width: main.width, height: main.height))
        }
        var equalizer = EqualizerWindowRenderer.render(skin, equalizerState)
        if let region = skin.regions.equalizer {
            equalizer.apply(mask: SkinRegions.mask(region, width: equalizer.width, height: equalizer.height))
        }
        let playlist = PlaylistWindowRenderer.render(skin, playlistState)

        scene.draw(main, from: main.bounds, atX: 0, y: 0)
        scene.draw(equalizer, from: equalizer.bounds, atX: 0, y: 116)
        scene.draw(playlist, from: playlist.bounds, atX: 0, y: 232)
        return scene
    }

    static func formatTime(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
