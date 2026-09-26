#if DEBUG
import AVFAudio
import AppKit
import SFBAudioEngine

/// The README's screenshots (`make screenshots`): a made-up library (artists,
/// songs, covers and words all invented, the music synthesized) playing in
/// the default skin; every window is captured as the window server shows it
/// and laid out on a plain backdrop. Runs inside the self test's isolated
/// settings, with the engine muted.
@MainActor
enum Screenshots {
    private struct Album {
        let artist: String
        let title: String
        let year: Int
        let genre: String
        let colors: (UInt32, UInt32)
        let tracks: [(title: String, seconds: Int)]
    }

    private static let albums = [
        Album(
            artist: "Nova Harbor", title: "Tidal Lights", year: 2023, genre: "Dream Pop", colors: (0x1B3A6B, 0x0A1224),
            tracks: [("Signal Fires", 252), ("Low Tide Radio", 228), ("Harbor Lights", 303), ("Northbound", 211)]),
        Album(
            artist: "Nova Harbor", title: "Lantern Season", year: 2021, genre: "Dream Pop", colors: (0xE0A040, 0x6B2A3A),
            tracks: [("Paper Boats", 198), ("Evening Ferry", 263)]),
        Album(
            artist: "Marigold Static", title: "Paper Satellites", year: 2024, genre: "Indie Pop", colors: (0xF28C5A, 0x7A2E6E),
            tracks: [("Paper Satellites", 237), ("Neon Orchard", 266), ("Cassette Summer", 224)]),
        Album(
            artist: "Oona Vale", title: "Slow Orbit", year: 2022, genre: "Ambient", colors: (0x4B2E83, 0x120B24),
            tracks: [("Slow Orbit", 314), ("Glass Weather", 219), ("Lighthouse Keeper", 291)]),
        Album(
            artist: "Kestrel Lane", title: "Night Market", year: 2025, genre: "Synthpop", colors: (0x0F4C5C, 0x05161C),
            tracks: [("Night Market", 245), ("Tram Lines", 202), ("Rooftop Static", 238)]),
    ]

    /// The song that plays, and where its words are when the pictures are taken.
    private static let playing = (artist: "Marigold Static", title: "Paper Satellites")
    private static let lyrics = """
        [00:14.00]Folded every letter into paper satellites
        [00:20.00]Threw them off the rooftop into borrowed city lights
        [00:26.00]Every one a question that the static never answered
        [00:32.00]Every one a promise that the night wind carried farther
        [00:39.00]Oh, orbit, orbit, somewhere over you
        [00:45.00]Paper satellites are circling back to you
        [00:51.00]Oh, orbit, orbit, tell me they got through
        [00:57.00]Paper satellites, all circling back to you
        [01:05.00]Found one on the doorstep, crumpled from the falling
        [01:11.00]Ink run into rivers, still I heard it calling
        [01:17.00]Written in the margins in a hand I barely knew
        [01:23.00]Every word I sent you finding its way through
        [01:30.00]Oh, orbit, orbit, somewhere over you
        [01:36.00]Paper satellites are circling back to you
        """

    static func run(_ manager: WindowManager, output: URL, work: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let music = work.appendingPathComponent("Music", isDirectory: true)
        print("screenshots: making the library in \(music.path)")
        let files = makeLibrary(in: music)
        guard let playingFile = files.first(where: { $0.artist == playing.artist && $0.title == playing.title })?.url else {
            print("screenshots: FAILED to make the library")
            return
        }

        let model = manager.model
        // The slider shows a usual level; the engine stays silent (the visualizers read before the volume).
        model.volume = 0.78
        model.engine.volume = 0
        model.bands = [0.64, 0.6, 0.54, 0.48, 0.44, 0.46, 0.52, 0.58, 0.63, 0.66]
        model.preamp = 0.5
        model.equalizerEnabled = true

        // The playlist: a mix, the playing song third.
        let order = [0, 12, 6, 9, 7, 5, 13, 2, 10, 8, 14, 1]
        model.load(order.compactMap { files.indices.contains($0) ? files[$0].url : nil }, play: false)
        try? await Task.sleep(for: .seconds(1))  // tags are read in the background
        if let index = model.playlist.entries.firstIndex(where: { $0.url == playingFile }) { model.play(trackAt: index) }
        await wait { model.status == .playing && model.elapsed > 0.2 }
        model.seek(to: 43.0 / 237)

        // Hero: main, equalizer and playlist, with the visualization, lyrics and cover beside them.
        manager.setPlaylistSizeForTesting(width: 0, height: 6)
        let vis = manager.visualization
        vis.restore(["width": 11, "height": 4, "random": 0, "locked": 1])
        manager.lyrics.restore(["width": 0, "height": 6])
        manager.albumArt.restore(["width": 0, "height": 6])
        manager.toggleAlbumArt()
        manager.toggleLyrics()
        manager.toggleVisualization()
        manager.windowSizeChanged()
        await wait { vis.library.isLoaded }  // the preset list is read in the background
        showPreset("Aurora", in: vis)
        try? await Task.sleep(for: .seconds(9))
        print("screenshots: at \(Int(model.elapsed)) s, engine volume \(model.engine.volume), visualization frames \(vis.framesDrawn)")

        let column = [manager.main, manager.equalizer, manager.playlist] as [SkinWindowController]
        await restartMarquee(manager)
        var shots = stack(column, x: 0)
        let side = CGFloat(manager.main.window.frame.width)
        shots += place(vis, x: side, y: 0)
        let below = vis.window.frame.height
        shots += place(manager.lyrics, x: side, y: below)
        shots += place(manager.albumArt, x: side + manager.lyrics.window.frame.width, y: below)
        save(compose(shots), to: output.appendingPathComponent("hagtamp.png"))

        // Visualization presets, side by side.
        vis.restore(["width": 7, "height": 5])
        manager.windowSizeChanged()
        var tiles: [(CGImage, CGRect)] = []
        for (n, name) in ["Bass Tunnel", "Golden Drift", "Motion Grid", "Starfield Pulse"].enumerated() {
            showPreset(name, in: vis)
            try? await Task.sleep(for: .seconds(7))
            let size = vis.window.frame.size
            tiles += place(vis, x: CGFloat(n % 2) * (size.width + 16), y: CGFloat(n / 2) * (size.height + 16))
        }
        save(compose(tiles), to: output.appendingPathComponent("visualization.png"))
        manager.toggleVisualization()
        manager.toggleLyrics()
        manager.toggleAlbumArt()

        // The local library beside the main windows, browsing an artist.
        let library = manager.localLibrary
        library.restore(["width": 16, "height": 14])
        manager.toggleLocalLibrary()
        manager.windowSizeChanged()
        manager.localLibraryService.setFolders([music])
        await wait(seconds: 20) { manager.localLibrary.summary.contains("artists=4") && manager.localLibraryService.progress == nil }
        library.selectForTesting(row: 2, in: 0)  // Nova Harbor, two albums
        try? await Task.sleep(for: .seconds(1))
        print("screenshots: library \(library.summary)")
        await restartMarquee(manager)
        shots = stack(column, x: 0) + place(library, x: side, y: 0)
        save(compose(shots), to: output.appendingPathComponent("library.png"))

        // The preferences, with loudness normalization, once the library is measured.
        await wait(seconds: 120) { model.loudness.pendingCount == 0 }
        // Active, so its controls show their colours: the app launched from a terminal isn't.
        if let front = NSWorkspace.shared.frontmostApplication { NSRunningApplication.current.activate(from: front) }
        (NSApp.delegate as? AppDelegate)?.showPreferences(tab: .general)
        try? await Task.sleep(for: .seconds(1))
        if let preferences = NSApp.windows.first(where: { $0.identifier == PreferencesWindowController.identifier }) {
            preferences.makeFirstResponder(nil)  // no focus ring
            try? await Task.sleep(for: .milliseconds(300))
            save(SelfTest.capture(preferences), to: output.appendingPathComponent("preferences.png"))
            preferences.close()
        }
    }

    // MARK: - The library

    private struct File {
        let url: URL
        let artist: String
        let title: String
    }

    /// Artist/Album/NN Title.m4a with tags, a cover per album, the playing song's .lrc.
    private static func makeLibrary(in folder: URL) -> [File] {
        try? FileManager.default.removeItem(at: folder)
        var files: [File] = []
        for (a, album) in albums.enumerated() {
            let albumFolder = folder.appendingPathComponent(album.artist).appendingPathComponent(album.title)
            try? FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
            if let cover = cover(style: a, colors: album.colors),
                let jpeg = NSBitmapImageRep(cgImage: cover).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            {
                try? jpeg.write(to: albumFolder.appendingPathComponent("cover.jpg"))
            }
            for (n, track) in album.tracks.enumerated() {
                let url = albumFolder.appendingPathComponent(String(format: "%02d %@.m4a", n + 1, track.title))
                let isPlaying = album.artist == playing.artist && track.title == playing.title
                // Only the song that plays needs music; the others hum of the right length.
                guard isPlaying ? synthesize(seconds: track.seconds, to: url) : hum(seconds: track.seconds, to: url) else {
                    print("screenshots: FAILED to write \(url.lastPathComponent)")
                    continue
                }
                if let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) {
                    file.metadata.title = track.title
                    file.metadata.artist = album.artist
                    file.metadata.albumArtist = album.artist
                    file.metadata.albumTitle = album.title
                    file.metadata.trackNumber = n + 1
                    file.metadata.trackTotal = album.tracks.count
                    file.metadata.releaseDate = String(album.year)
                    file.metadata.genre = album.genre
                    try? file.writeMetadata()
                }
                if isPlaying { try? lyrics.write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8) }
                files.append(File(url: url, artist: album.artist, title: track.title))
            }
        }
        return files
    }

    /// AAC in an MP4 file, at a constant bitrate (what the main window shows).
    private static func aacFile(_ url: URL, rate: Double, channels: Int, bitrate: Int) -> AVAudioFile? {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate * 1000, AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
        return try? AVAudioFile(forWriting: url, settings: settings)
    }

    /// A soft low hum: silence would have no loudness to measure.
    private static func hum(seconds: Int, to url: URL) -> Bool {
        let rate = 22050.0
        guard let file = aacFile(url, rate: rate, channels: 1, bitrate: 32),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Double(seconds) * rate))
        else { return false }
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { samples[i] = 0.02 * Float(sin(2 * .pi * 110 * Double(i) / rate)) }
        return (try? file.write(from: buffer)) != nil
    }

    /// A little pop song at 112 bpm: kick, snare, hi-hat, bass, a pad and an
    /// arpeggio over Am - F - C - G, so the visualizers have something to show.
    private static func synthesize(seconds: Int, to url: URL) -> Bool {
        let rate = 44100.0
        guard let file = aacFile(url, rate: rate, channels: 2, bitrate: 192) else { return false }
        let beat = 60.0 / 112
        let chords: [[Double]] = [[110, 130.81, 164.81], [87.31, 110, 130.81], [130.81, 164.81, 196], [98, 123.47, 146.83]]
        var noise: UInt32 = 12345
        func random() -> Double {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            return Double(noise >> 8) / Double(1 << 24) * 2 - 1
        }
        var lastNoise = 0.0
        let chunk = Int(rate)
        for start in stride(from: 0, to: Int(Double(seconds) * rate), by: chunk) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return false }
            buffer.frameLength = buffer.frameCapacity
            let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
            for i in 0..<chunk {
                let t = Double(start + i) / rate
                let beats = t / beat
                let inBeat = (beats - floor(beats)) * beat
                let bar = Int(beats / 4)
                let chord = chords[bar % 4]
                // Kick on every beat: a falling sine.
                let kickPitch = 45 + 70 * exp(-inBeat * 30)
                var mono = 0.55 * sin(2 * .pi * kickPitch * inBeat) * exp(-inBeat * 9)
                // Snare on 2 and 4.
                if Int(beats) % 2 == 1 {
                    let n = random()
                    mono += (0.28 * n + 0.12 * sin(2 * .pi * 185 * inBeat)) * exp(-inBeat * 16)
                }
                // Hi-hat on the eighths: bright noise.
                let eighth = (beats * 2 - floor(beats * 2)) * beat / 2
                let n = random()
                mono += 0.16 * (n - lastNoise) * exp(-eighth * 60)
                lastNoise = n
                // Bass: the root, plucked on the eighths.
                let root = chord[0] / 2
                mono += 0.22 * (sin(2 * .pi * root * t) + 0.35 * sin(4 * .pi * root * t)) * (0.4 + 0.6 * exp(-eighth * 8))
                var l = mono, r = mono
                // Pad: the chord, a little apart in each ear.
                let swell = 0.6 + 0.4 * sin(2 * .pi * t / (beat * 16))
                func saw(_ f: Double) -> Double { 2 * (f * t - floor(f * t + 0.5)) }
                for (k, f) in chord.enumerated() {
                    l += 0.05 * swell * sin(2 * .pi * f * 2 * t * 1.002 + Double(k)) + 0.03 * swell * saw(f * 4 * 1.003)
                    r += 0.05 * swell * sin(2 * .pi * f * 2 * t * 0.998 + Double(k) * 2) + 0.03 * swell * saw(f * 4 * 0.997)
                }
                // Arpeggio in sixteenths from the fourth bar.
                if bar >= 4 {
                    let step = Int(beats * 4)
                    let note = chord[step % 3] * 4
                    let sixteenth = (beats * 4 - floor(beats * 4)) * beat / 4
                    let tone = asin(sin(2 * .pi * note * t)) * 2 / .pi * exp(-sixteenth * 14)
                    l += 0.11 * tone * (step % 2 == 0 ? 1 : 0.6)
                    r += 0.11 * tone * (step % 2 == 0 ? 0.6 : 1)
                }
                // Loud and soft-clipped, like a mastered record (the analyzer likes it).
                left[i] = Float(tanh(l * 1.6))
                right[i] = Float(tanh(r * 1.6))
            }
            guard (try? file.write(from: buffer)) != nil else { return false }
        }
        return true
    }

    /// Abstract cover art, one style per album.
    private static func cover(style: Int, colors: (UInt32, UInt32)) -> CGImage? {
        let size = 600.0
        guard let ctx = CGContext(
            data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        func color(_ rgb: UInt32, _ alpha: Double = 1) -> CGColor {
            CGColor(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: alpha)
        }
        let gradient = CGGradient(colorsSpace: nil, colors: [color(colors.0), color(colors.1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size * 0.4, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.setLineCap(.round)
        switch style {
        case 0:  // a moon over waves
            ctx.setFillColor(color(0xF4E9C8, 0.9))
            ctx.fillEllipse(in: CGRect(x: 380, y: 400, width: 120, height: 120))
            for k in 0..<9 {
                let base = 60.0 + Double(k) * 30
                ctx.setStrokeColor(color(0x9CC8FF, 0.25 + Double(k) * 0.05))
                ctx.setLineWidth(3)
                ctx.move(to: CGPoint(x: 0, y: base))
                for x in stride(from: 0.0, through: size, by: 6) {
                    ctx.addLine(to: CGPoint(x: x, y: base + 10 * sin(x / 40 + Double(k))))
                }
                ctx.strokePath()
            }
        case 1:  // a sun behind stripes
            ctx.setFillColor(color(0xFFE0A0, 0.95))
            ctx.fillEllipse(in: CGRect(x: 170, y: 190, width: 260, height: 260))
            ctx.setStrokeColor(color(colors.1, 0.8))
            for k in 0..<7 {
                ctx.setLineWidth(10 - Double(k))
                let y = 150.0 + Double(k) * 22
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size, y: y))
                ctx.strokePath()
            }
        case 2:  // a planet, orbits and satellites
            ctx.setFillColor(color(0xFFD27A, 0.95))
            ctx.fillEllipse(in: CGRect(x: 90, y: 90, width: 250, height: 250))
            ctx.setStrokeColor(color(0xFFFFFF, 0.55))
            ctx.setLineWidth(3)
            for k in 0..<3 {
                let r = 190.0 + Double(k) * 70
                ctx.strokeEllipse(in: CGRect(x: 215 - r, y: 215 - r * 0.45, width: r * 2, height: r * 0.9))
                ctx.setFillColor(color(0xFFFFFF, 0.95))
                let a = 0.6 + Double(k) * 0.9
                ctx.fillEllipse(in: CGRect(x: 215 + r * cos(a) - 12, y: 215 + r * 0.45 * sin(a) - 12, width: 24, height: 24))
            }
        case 3:  // rings around a point
            ctx.setStrokeColor(color(0xC9B6FF, 0.5))
            for k in 1...9 {
                ctx.setLineWidth(2 + Double(k % 3))
                let r = Double(k) * 30
                ctx.strokeEllipse(in: CGRect(x: 300 - r, y: 300 - r, width: r * 2, height: r * 2))
            }
            ctx.setFillColor(color(0xFFF3C4))
            ctx.fillEllipse(in: CGRect(x: 288 + 150, y: 288, width: 24, height: 24))
        default:  // lanterns in the dark
            let warm: [UInt32] = [0xFF7A59, 0xFFC857, 0x5CE1E6, 0xFF4F9A]
            for row in 0..<5 {
                for column in 0..<5 {
                    let x = 70.0 + Double(column) * 115 + Double(row % 2) * 30, y = 80.0 + Double(row) * 105
                    let c = warm[(row * 5 + column) % warm.count]
                    ctx.setFillColor(color(c, 0.25))
                    ctx.fillEllipse(in: CGRect(x: x - 26, y: y - 26, width: 52, height: 52))
                    ctx.setFillColor(color(c, 0.95))
                    ctx.fillEllipse(in: CGRect(x: x - 13, y: y - 13, width: 26, height: 26))
                }
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Pictures

    /// The title from its start rather than part way through its scrolling.
    private static func restartMarquee(_ manager: WindowManager) async {
        manager.restartMarqueeForTesting()
        try? await Task.sleep(for: .milliseconds(60))  // until the window server has the new frame
    }

    private static func showPreset(_ name: String, in vis: VisualizationWindowController) {
        if let url = vis.library.presets.first(where: { PresetLibrary.name($0).hasSuffix(name) }) { vis.show(url, blend: false) }
    }

    /// Windows one under another at `x`.
    private static func stack(_ windows: [SkinWindowController], x: CGFloat) -> [(CGImage, CGRect)] {
        var y = 0.0
        var result: [(CGImage, CGRect)] = []
        for c in windows {
            result += place(c, x: x, y: y)
            y += c.window.frame.height
        }
        return result
    }

    /// A window's capture at a spot of the picture (points, top-left origin).
    private static func place(_ c: SkinWindowController, x: CGFloat, y: CGFloat) -> [(CGImage, CGRect)] {
        guard let image = SelfTest.capture(c.window) else {
            print("screenshots: FAILED to capture \(c.id)")
            return []
        }
        return [(image, CGRect(origin: CGPoint(x: x, y: y), size: c.window.frame.size))]
    }

    /// The windows on a dark backdrop with rounded corners, at the captures' scale.
    private static func compose(_ shots: [(CGImage, CGRect)], margin: CGFloat = 36) -> CGImage? {
        guard let first = shots.first else { return nil }
        let scale = CGFloat(first.0.width) / first.1.width
        let bounds = shots.map(\.1).reduce(CGRect.null) { $0.union($1) }
        let width = Int((bounds.width + margin * 2) * scale), height = Int((bounds.height + margin * 2) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: canvas, cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
        ctx.clip()
        let backdrop = CGGradient(
            colorsSpace: space, colors: [CGColor(srgbRed: 0.24, green: 0.27, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        ctx.interpolationQuality = .none
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: 0.55))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for (image, frame) in shots {
            let x = (frame.minX - bounds.minX + margin) * scale
            let y = canvas.height - (frame.maxY - bounds.minY + margin) * scale
            ctx.draw(image, in: CGRect(x: x, y: y, width: frame.width * scale, height: frame.height * scale))
        }
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }

    private static func save(_ image: CGImage?, to url: URL) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("screenshots: FAILED \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("screenshots: \(url.lastPathComponent) \(image.width)x\(image.height) \(png.count / 1024) KB")
    }

    private static func wait(seconds: Double = 8, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
#endif
