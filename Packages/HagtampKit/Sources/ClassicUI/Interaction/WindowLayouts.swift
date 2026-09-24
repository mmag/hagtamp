import SkinKit

// Hit areas of the classic windows, from Webamp's CSS (MIT, see
// THIRD_PARTY_NOTICES.md). Regions are listed in priority order: the first
// one containing the pointer wins. Anything else is the window body, which
// moves the window (Winamp's "easy move").

public enum MainWindowLayout {
    public static let volume = SliderGeometry(axis: .horizontal, origin: 107, length: 65, thumb: 14)
    public static let balance = SliderGeometry(axis: .horizontal, origin: 177, length: 38, thumb: 14)
    public static let position = SliderGeometry(axis: .horizontal, origin: 16, length: 248, thumb: 29)
    public static let shadePosition = SliderGeometry(axis: .horizontal, origin: 226, length: 17, thumb: 3)

    public static let bodyCursor = SkinCursorName.normal
    public static let shadeBodyCursor = SkinCursorName.shadeNormal

    public static func regions(shade: Bool) -> [ControlRegion] {
        shade ? shadeRegions : normalRegions
    }

    static let normalRegions: [ControlRegion] = [
        ControlRegion(.options, 6, 3, 9, 9, .press, cursor: .mainMenu),
        ControlRegion(.minimize, 244, 3, 9, 9, cursor: .minimize),
        ControlRegion(.shade, 254, 3, 9, 9, cursor: .windowButton),
        ControlRegion(.close, 264, 3, 9, 9, cursor: .close),
        ControlRegion(.titleBar, 0, 0, 275, 14, .moveWindow, cursor: .titleBar),

        ControlRegion(.clutterOptions, 10, 25, 8, 8, .press, cursor: .normal),
        ControlRegion(.clutterAlwaysOnTop, 10, 33, 8, 7, cursor: .normal),
        ControlRegion(.clutterInfo, 10, 40, 8, 7, cursor: .normal),
        ControlRegion(.clutterDoubleSize, 10, 47, 8, 8, cursor: .normal),
        ControlRegion(.clutterVisualization, 10, 55, 8, 7, .press, cursor: .normal),

        ControlRegion(.time, 39, 26, 59, 13, .press, cursor: .normal),
        ControlRegion(.visualizer, 24, 43, 76, 16, .press, cursor: .normal),
        ControlRegion(.marquee, 111, 24, 155, 12, .press, cursor: .songName),

        ControlRegion(.volume, PixelRect(x: 107, y: 57, width: 68, height: 13), .slider(volume), cursor: .volumeBalance),
        ControlRegion(.balance, PixelRect(x: 177, y: 57, width: 38, height: 13), .slider(balance), cursor: .volumeBalance),
        ControlRegion(.equalizerToggle, 219, 58, 23, 12, cursor: .normal),
        ControlRegion(.playlistToggle, 242, 58, 23, 12, cursor: .normal),
        ControlRegion(.position, PixelRect(x: 16, y: 72, width: 248, height: 10), .slider(position), cursor: .positionBar),

        ControlRegion(.previous, 16, 88, 23, 18, cursor: .normal),
        ControlRegion(.play, 39, 88, 23, 18, cursor: .normal),
        ControlRegion(.pause, 62, 88, 23, 18, cursor: .normal),
        ControlRegion(.stop, 85, 88, 23, 18, cursor: .normal),
        ControlRegion(.next, 108, 88, 22, 18, cursor: .normal),
        ControlRegion(.eject, 136, 89, 22, 16, cursor: .normal),
        ControlRegion(.shuffle, 164, 89, 47, 15, cursor: .normal),
        ControlRegion(.repeatToggle, 210, 89, 28, 15, cursor: .normal),
        ControlRegion(.about, 253, 91, 13, 15, cursor: .normal),
    ]

    static let shadeRegions: [ControlRegion] = [
        ControlRegion(.options, 6, 3, 9, 9, .press, cursor: .shadeMenu),
        ControlRegion(.minimize, 244, 3, 9, 9, cursor: .minimize),
        ControlRegion(.shade, 254, 3, 9, 9, cursor: .windowButton),
        ControlRegion(.close, 264, 3, 9, 9, cursor: .close),
        ControlRegion(.visualizer, 79, 5, 38, 5, .press, cursor: .shadeNormal),
        ControlRegion(.time, 127, 4, 30, 6, .press, cursor: .shadeNormal),
        ControlRegion(.previous, 169, 2, 7, 10, cursor: .shadeNormal),
        ControlRegion(.play, 176, 2, 10, 10, cursor: .shadeNormal),
        ControlRegion(.pause, 186, 2, 9, 10, cursor: .shadeNormal),
        ControlRegion(.stop, 195, 2, 9, 10, cursor: .shadeNormal),
        ControlRegion(.next, 204, 2, 10, 10, cursor: .shadeNormal),
        ControlRegion(.eject, 215, 2, 10, 10, cursor: .shadeNormal),
        ControlRegion(.position, PixelRect(x: 226, y: 4, width: 17, height: 7), .slider(shadePosition), cursor: .shadePositionBar),
        ControlRegion(.titleBar, 0, 0, 275, 14, .moveWindow, cursor: .shadeNormal),
    ]
}

public enum EqualizerWindowLayout {
    /// Preamp and band sliders: 62 px track, 11 px thumb, maximum at the top.
    public static let band = SliderGeometry(axis: .vertical, origin: 38, length: 62, thumb: 11, invert: true, roundsDown: true)
    public static let shadeVolume = SliderGeometry(axis: .horizontal, origin: 61, length: 97, thumb: 3)
    public static let shadeBalance = SliderGeometry(axis: .horizontal, origin: 164, length: 43, thumb: 3)

    public static let bodyCursor = SkinCursorName.eqNormal
    public static let shadeBodyCursor = SkinCursorName.eqTitle

    public static func regions(shade: Bool) -> [ControlRegion] {
        shade ? shadeRegions : normalRegions
    }

    static let normalRegions: [ControlRegion] =
        [
            ControlRegion(.shade, 254, 3, 9, 9, cursor: .eqTitle),
            ControlRegion(.close, 264, 3, 9, 9, cursor: .eqClose),
            ControlRegion(.titleBar, 0, 0, 275, 14, .moveWindow, cursor: .eqTitle),
            ControlRegion(.equalizerOn, 14, 18, 26, 12, cursor: .eqNormal),
            ControlRegion(.equalizerAuto, 40, 18, 32, 12, cursor: .eqNormal),
            ControlRegion(.presets, 217, 18, 44, 12, .press, cursor: .eqNormal),
            ControlRegion(.preamp, PixelRect(x: 21, y: 38, width: 14, height: 63), .slider(band), cursor: .eqSlider),
            ControlRegion(.bandsMax, 45, 36, 22, 8, cursor: .eqNormal),
            ControlRegion(.bandsFlat, 45, 64, 22, 8, cursor: .eqNormal),
            ControlRegion(.bandsMin, 45, 95, 22, 8, cursor: .eqNormal),
        ]
        + (0..<10).map { i in
            ControlRegion(.band(i), PixelRect(x: 78 + i * 18, y: 38, width: 14, height: 63), .slider(band), cursor: .eqSlider)
        }

    static let shadeRegions: [ControlRegion] = [
        ControlRegion(.shade, 254, 3, 9, 9, cursor: .eqTitle),
        ControlRegion(.close, 264, 3, 9, 9, cursor: .eqClose),
        ControlRegion(.volume, PixelRect(x: 61, y: 3, width: 97, height: 8), .slider(shadeVolume), cursor: .eqTitle),
        ControlRegion(.balance, PixelRect(x: 164, y: 3, width: 43, height: 8), .slider(shadeBalance), cursor: .eqTitle),
        ControlRegion(.titleBar, 0, 0, 275, 14, .moveWindow, cursor: .eqTitle),
    ]
}

public enum PlaylistWindowLayout {
    public static let bodyCursor = SkinCursorName.playlistNormal
    public static let shadeBodyCursor = SkinCursorName.playlistShadeNormal

    public static func scrollBar(height: Int) -> SliderGeometry {
        SliderGeometry(axis: .vertical, origin: 20, length: height - 58, thumb: 18, roundsDown: true)
    }

    /// Left edge of a playlist menu button.
    public static func menuX(_ menu: PlaylistMenu, width: Int) -> Int {
        switch menu {
        case .add: 14
        case .remove: 43
        case .select: 72
        case .misc: 101
        case .list: width - 44
        }
    }

    /// Area of an open menu's item, counted from the top.
    public static func menuItemRect(_ menu: PlaylistMenu, item index: Int, width: Int, height: Int) -> PixelRect {
        let count = menu.items.count
        let buttonY = height - 30
        return PixelRect(x: menuX(menu, width: width), y: buttonY - (count - 1 - index) * 18, width: 22, height: 18)
    }

    public static func regions(width: Int, height: Int, shade: Bool) -> [ControlRegion] {
        let w = width, h = height
        if shade {
            return [
                ControlRegion(.resize, w - 29, 3, 9, 9, .press, cursor: .playlistShadeSize),
                ControlRegion(.shade, w - 21, 3, 9, 9, cursor: .playlistWindowButton),
                ControlRegion(.close, w - 11, 3, 9, 9, cursor: .playlistClose),
                ControlRegion(.titleBar, 0, 0, w, 14, .moveWindow, cursor: .playlistShadeNormal),
            ]
        }
        let right = w - 150, bottom = h - 38
        let transport: [Control] = [.previous, .play, .pause, .stop, .next, .eject]
        return [
            ControlRegion(.shade, w - 21, 3, 9, 9, cursor: .playlistWindowButton),
            ControlRegion(.close, w - 11, 3, 9, 9, cursor: .playlistClose),
            ControlRegion(.titleBar, 0, 0, w, 20, .moveWindow, cursor: .playlistTitleBar),
            ControlRegion(.trackList, 12, 20, w - 32, h - 58, .press, cursor: .playlistNormal),
            ControlRegion(.scrollBar, PixelRect(x: w - 15, y: 20, width: 8, height: h - 58), .slider(scrollBar(height: h)), cursor: .playlistScroll),
            ControlRegion(.resize, w - 20, h - 20, 20, 20, .press, cursor: .playlistSize),
            ControlRegion(.scrollUp, w - 15, bottom + 2, 8, 5, cursor: .playlistNormal),
            ControlRegion(.scrollDown, w - 15, bottom + 8, 8, 5, cursor: .playlistNormal),
            ControlRegion(.miniTime, right + 66, bottom + 23, 30, 6, .press, cursor: .playlistNormal),
        ]
            + PlaylistMenu.allCases.map { menu in
                ControlRegion(.menu(menu), menuX(menu, width: w), h - 30, 22, 18, .press, cursor: .playlistNormal)
            }
            + transport.enumerated().map { i, control in
                ControlRegion(control, right + 3 + i * 10, bottom + 22, 10, 10, cursor: .playlistNormal)
            }
    }
}

extension Array where Element == ControlRegion {
    /// The topmost control under a point, if any.
    public func hit(x: Int, y: Int) -> ControlRegion? {
        first { $0.rect.contains(x: x, y: y) }
    }

    public func region(for control: Control) -> ControlRegion? {
        first { $0.control == control }
    }
}
