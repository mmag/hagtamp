import SkinKit

public enum MediaLibraryButton: CaseIterable, Sendable {
    /// `setup` gets the library's own title ("Preferences…", "Add Folder…").
    case play, enqueue, clearSearch, setup
}

/// Everything a library window shows.
public struct MediaLibraryState: Sendable {
    public var frame: GenWindowState
    /// Views (Library, Recently Added, …).
    public var sidebar: ListViewModel
    public var search = ""
    public var searchFocused = false
    public var caretVisible = true
    /// None, one list, or two side by side (artists | albums).
    public var upper: [ListViewModel]
    public var tracks: ListViewModel
    public var status = ""
    public var pressedButton: MediaLibraryButton?
    /// Title of a button next to Play/Enqueue for setting the library up (nil: none).
    public var setupButton: String?

    public init(frame: GenWindowState, sidebar: ListViewModel, upper: [ListViewModel], tracks: ListViewModel) {
        self.frame = frame
        self.sidebar = sidebar
        self.upper = upper
        self.tracks = tracks
    }
}

/// Where everything goes, shared by rendering and hit-testing.
public struct MediaLibraryLayout: Sendable {
    public let content: PixelRect
    public let sidebar: PixelRect
    public let searchLabel: PixelRect
    public let searchField: PixelRect
    public let upper: [PixelRect]
    public let tracks: PixelRect
    public let buttons: [MediaLibraryButton: PixelRect]
    public let status: PixelRect

    public init(width: Int, height: Int, upperCount: Int, showsSetupButton: Bool) {
        let c = GenWindowRenderer.contentRect(width: width, height: height)
        content = c
        let listsBottom = c.maxY - 20
        sidebar = PixelRect(x: c.x, y: c.y, width: 96, height: listsBottom - c.y)
        let x0 = sidebar.maxX + 3, rightWidth = c.maxX - x0
        let clear = PixelRect(x: c.maxX - 42, y: c.y, width: 42, height: 15)
        searchLabel = PixelRect(x: x0, y: c.y, width: 38, height: 15)
        searchField = PixelRect(x: x0 + 40, y: c.y, width: clear.x - 3 - (x0 + 40), height: 15)
        let upperTop = c.y + 18
        let upperHeight = upperCount == 0 ? -3 : (listsBottom - upperTop - 3) * 45 / 100
        if upperCount == 0 {
            upper = []
        } else if upperCount >= 2 {
            let w = (rightWidth - 3) / 2
            upper = [
                PixelRect(x: x0, y: upperTop, width: w, height: upperHeight),
                PixelRect(x: x0 + w + 3, y: upperTop, width: rightWidth - w - 3, height: upperHeight),
            ]
        } else {
            upper = [PixelRect(x: x0, y: upperTop, width: rightWidth, height: upperHeight)]
        }
        tracks = PixelRect(x: x0, y: upperTop + upperHeight + 3, width: rightWidth, height: listsBottom - (upperTop + upperHeight + 3))
        let buttonY = c.maxY - 16
        var buttons: [MediaLibraryButton: PixelRect] = [
            .clearSearch: clear,
            .play: PixelRect(x: c.x, y: buttonY, width: 44, height: 15),
            .enqueue: PixelRect(x: c.x + 47, y: buttonY, width: 58, height: 15),
        ]
        var statusX = c.x + 110
        if showsSetupButton {
            buttons[.setup] = PixelRect(x: c.x + 108, y: buttonY, width: 76, height: 15)
            statusX = c.x + 190
        }
        self.buttons = buttons
        status = PixelRect(x: statusX, y: buttonY, width: max(0, c.maxX - statusX), height: 15)
    }
}

public enum MediaLibraryRenderer {
    public static func render(_ skin: Skin, _ state: MediaLibraryState) -> Bitmap {
        var frame = state.frame
        let colors = skin.genExColors ?? Skin.base.genExColors!
        frame.contentColor = colors.windowBackground
        var canvas = GenWindowRenderer.render(skin, frame)
        let layout = MediaLibraryLayout(
            width: frame.pixelWidth, height: frame.pixelHeight, upperCount: state.upper.count,
            showsSetupButton: state.setupButton != nil)
        let font = skin.playlistStyle.font

        GenControls.drawList(&canvas, skin, colors, layout.sidebar, state.sidebar)
        SystemText.draw(&canvas, "Search:", in: layout.searchLabel, color: colors.windowText, fontName: font)
        GenControls.drawTextField(
            &canvas, skin, colors, layout.searchField, text: state.search, placeholder: "Artists, albums, songs",
            focused: state.searchFocused, caretVisible: state.caretVisible)
        for (model, rect) in zip(state.upper, layout.upper) {
            GenControls.drawList(&canvas, skin, colors, rect, model)
        }
        GenControls.drawList(&canvas, skin, colors, layout.tracks, state.tracks)
        for (button, rect) in layout.buttons {
            let title =
                switch button {
                case .play: "Play"
                case .enqueue: "Enqueue"
                case .clearSearch: "Clear"
                case .setup: state.setupButton ?? ""
                }
            GenControls.drawButton(&canvas, skin, colors, rect, title: title, pressed: state.pressedButton == button)
        }
        SystemText.draw(&canvas, state.status, in: layout.status, color: colors.windowText, fontName: font)
        return canvas
    }
}
