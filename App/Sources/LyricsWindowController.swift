import AppKit
import ClassicUI
import PlayerCore
import SkinKit

/// Optional window with the words of the current track, in a generic skinned
/// frame: from Navidrome (and its lyrics plugins), or a local file's .lrc or
/// lyrics tag. Synced lyrics follow the song; a click on a line jumps there.
@MainActor
final class LyricsWindowController: SkinWindowController {
    private var widthSteps = 0
    private var heightSteps = 6
    private var resizeStart: (mouse: NSPoint, width: Int, height: Int)?
    private enum Loaded {
        case loading
        case done(Lyrics?)
    }
    /// Lyrics by track, looked up once.
    private var loaded: [URL: Loaded] = [:]
    private var shownTrack: URL?
    private var firstRow = 0
    /// After a manual scroll, following the song waits a moment.
    private var followAgainAt = Date.distantPast

    init(manager: WindowManager) {
        super.init(id: .lyrics, manager: manager)
    }

    private var width: Int { GenWindowRenderer.baseWidth + widthSteps * 25 }
    private var height: Int { GenWindowRenderer.baseHeight + heightSteps * 29 }
    private var content: PixelRect { GenWindowRenderer.contentRect(width: width, height: height) }

    override func regions() -> [ControlRegion] {
        GenWindowLayout.regions(width: width, height: height) + [ControlRegion(.trackList, content, .press, cursor: .normal)]
    }
    override func pixelSize() -> (width: Int, height: Int) { (width, height) }
    override func titleBarDoubleClicked() {}  // generic windows have no shade mode

    override func savedState() -> [String: Int] { ["width": widthSteps, "height": heightSteps] }

    override func restore(_ state: [String: Int]) {
        widthSteps = max(0, state["width"] ?? widthSteps)
        heightSteps = max(0, state["height"] ?? heightSteps)
    }

    // MARK: - State

    private var track: TrackInfo? { manager.model.displayedTrack }

    private var lyrics: Lyrics? {
        guard let url = track?.url, case .done(let lyrics)? = loaded[url] else { return nil }
        return lyrics
    }

    private func layout(_ lyrics: Lyrics) -> LyricsLayout {
        LyricsLayout(lines: lyrics.lines.map(\.text), width: width, height: height, fontName: manager.skin.playlistStyle.font)
    }

    override func renderBitmap() -> Bitmap {
        var frame = GenWindowState(title: "Lyrics")
        frame.focused = isFocused
        frame.pressed = pressed
        frame.widthSteps = widthSteps
        frame.heightSteps = heightSteps
        var state = LyricsWindowState(frame: frame)

        let url = track?.url
        if url != shownTrack {
            shownTrack = url
            firstRow = 0
            followAgainAt = .distantPast
        }
        load(track)
        switch url.flatMap({ loaded[$0] }) {
        case nil: state.message = "Nothing to play"
        case .loading?: state.message = "Loading lyrics…"
        case .done(nil)?: state.message = "No lyrics for this track"
        case .done(let lyrics?)?:
            state.lines = lyrics.lines.map(\.text)
            let layout = layout(lyrics)
            if manager.model.status != .stopped, let current = lyrics.lineIndex(at: manager.model.elapsed) {
                state.current = current
                if Date() >= followAgainAt { firstRow = layout.firstRow(centering: current) }
            }
            firstRow = min(max(0, firstRow), layout.maxFirstRow)
            state.firstRow = firstRow
        }
        return LyricsRenderer.render(manager.skin, state)
    }

    private func load(_ track: TrackInfo?) {
        guard let track, loaded[track.url] == nil else { return }
        loaded[track.url] = .loading
        Task { [weak self] in
            let lyrics = await self?.manager.lyrics(for: track)
            self?.loaded[track.url] = .done(lyrics)
            self?.manager.render()
        }
    }

    /// Forgets lookups that found nothing (a lyrics plugin may know more by now).
    func reloadMissing() {
        loaded = loaded.filter { if case .done(nil) = $0.value { false } else { true } }
    }

    // MARK: - Pointer

    override func buttonClicked(_ control: Control) {
        if control == .close { manager.hideExtra(self) }
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        if control == .resize {
            resizeStart = (NSEvent.mouseLocation, widthSteps, heightSteps)
            return true
        }
        // A click on a synced line plays from there.
        guard control == .trackList, let lyrics, let line = layout(lyrics).line(atY: point.y, firstRow: firstRow),
            let start = lyrics.lines[line].start, let duration = manager.model.duration, duration > 0
        else { return false }
        manager.model.seek(to: start / duration)
        followAgainAt = .distantPast
        return false
    }

    override func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {
        guard control == .resize, let start = resizeStart else { return }
        let now = NSEvent.mouseLocation
        let scale = CGFloat(manager.scale)
        let dx = (now.x - start.mouse.x) / scale, dy = (start.mouse.y - now.y) / scale
        let newWidth = max(0, start.width + Int((dx / 25).rounded()))
        let newHeight = max(0, start.height + Int((dy / 29).rounded()))
        guard newWidth != widthSteps || newHeight != heightSteps else { return }
        widthSteps = newWidth
        heightSteps = newHeight
        manager.windowSizeChanged()
    }

    override func pressEnded(_ control: Control, at point: SkinPoint, event: NSEvent) {
        resizeStart = nil
    }

    override func scrolled(by delta: CGFloat) {
        guard let lyrics else { return }
        firstRow = min(max(0, firstRow - Int(delta.rounded())), layout(lyrics).maxFirstRow)
        followAgainAt = Date().addingTimeInterval(4)
        manager.render()
    }

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        manager.showMainMenu(for: event, in: window.skinView)
    }

    /// Self test: a click on a lyrics line.
    func clickLineForTesting(_ line: Int) {
        guard let lyrics, let row = layout(lyrics).rows.firstIndex(where: { $0.line == line }) else { return }
        firstRow = min(row, layout(lyrics).maxFirstRow)
        let y = layout(lyrics).area.y + (row - firstRow) * LyricsLayout.rowHeight + 2
        _ = pressBegan(.trackList, at: SkinPoint(x: content.x + 20, y: y), event: NSEvent())
    }

    /// For the self test.
    var summary: String {
        let state: String
        switch shownTrack.flatMap({ loaded[$0] }) {
        case nil: state = "none"
        case .loading?: state = "loading"
        case .done(nil)?: state = "no lyrics"
        case .done(let lyrics?)?:
            let current = manager.model.status == .stopped ? nil : lyrics.lineIndex(at: manager.model.elapsed)
            state = "lines=\(lyrics.lines.count) synced=\(lyrics.isSynced) current=\(current.map(String.init) ?? "-") firstRow=\(firstRow)"
        }
        return state
    }
}
