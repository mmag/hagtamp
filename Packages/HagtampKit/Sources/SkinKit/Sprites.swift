// Sprite coordinates of the classic skin format.
//
// Ported from Webamp's skinSprites.ts (MIT, Copyright (c) 2015 Jordan
// Eldredge), see THIRD_PARTY_NOTICES.md. Names follow the files of a skin so
// they can be cross-checked against skinning documentation.

/// A bitmap of the classic skin format, named after its file.
public enum SkinSheet: String, CaseIterable, Sendable {
    case main = "MAIN"
    case cbuttons = "CBUTTONS"
    case titlebar = "TITLEBAR"
    case shufrep = "SHUFREP"
    case volume = "VOLUME"
    case balance = "BALANCE"
    case posbar = "POSBAR"
    case playpaus = "PLAYPAUS"
    case monoster = "MONOSTER"
    case numbers = "NUMBERS"
    /// Optional replacement for NUMBERS with a proper minus sign.
    case numsEx = "NUMS_EX"
    case text = "TEXT"
    case eqmain = "EQMAIN"
    case eqEx = "EQ_EX"
    case pledit = "PLEDIT"
    case gen = "GEN"
    case genex = "GENEX"
}

public struct Sprite: Hashable, Sendable, CustomStringConvertible {
    public let sheet: SkinSheet
    public let rect: PixelRect

    public init(_ sheet: SkinSheet, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.sheet = sheet
        rect = PixelRect(x: x, y: y, width: width, height: height)
    }

    public var width: Int { rect.width }
    public var height: Int { rect.height }

    public var description: String { "\(sheet.rawValue)\(rect)" }
}

extension Sprite {
    public enum Main {
        public static let background = Sprite(.main, 0, 0, 275, 116)
    }

    public enum CButtons {
        public static let previous = Sprite(.cbuttons, 0, 0, 23, 18)
        public static let previousPressed = Sprite(.cbuttons, 0, 18, 23, 18)
        public static let play = Sprite(.cbuttons, 23, 0, 23, 18)
        public static let playPressed = Sprite(.cbuttons, 23, 18, 23, 18)
        public static let pause = Sprite(.cbuttons, 46, 0, 23, 18)
        public static let pausePressed = Sprite(.cbuttons, 46, 18, 23, 18)
        public static let stop = Sprite(.cbuttons, 69, 0, 23, 18)
        public static let stopPressed = Sprite(.cbuttons, 69, 18, 23, 18)
        public static let next = Sprite(.cbuttons, 92, 0, 22, 18)
        public static let nextPressed = Sprite(.cbuttons, 92, 18, 22, 18)
        public static let eject = Sprite(.cbuttons, 114, 0, 22, 16)
        public static let ejectPressed = Sprite(.cbuttons, 114, 16, 22, 16)
    }

    public enum TitleBar {
        public static let active = Sprite(.titlebar, 27, 0, 275, 14)
        public static let inactive = Sprite(.titlebar, 27, 15, 275, 14)
        public static let easterEggActive = Sprite(.titlebar, 27, 57, 275, 14)
        public static let easterEggInactive = Sprite(.titlebar, 27, 72, 275, 14)
        public static let shadeActive = Sprite(.titlebar, 27, 29, 275, 14)
        public static let shadeInactive = Sprite(.titlebar, 27, 42, 275, 14)

        public static let options = Sprite(.titlebar, 0, 0, 9, 9)
        public static let optionsPressed = Sprite(.titlebar, 0, 9, 9, 9)
        public static let minimize = Sprite(.titlebar, 9, 0, 9, 9)
        public static let minimizePressed = Sprite(.titlebar, 9, 9, 9, 9)
        public static let close = Sprite(.titlebar, 18, 0, 9, 9)
        public static let closePressed = Sprite(.titlebar, 18, 9, 9, 9)
        public static let shade = Sprite(.titlebar, 0, 18, 9, 9)
        public static let shadePressed = Sprite(.titlebar, 9, 18, 9, 9)
        /// The shade button as drawn in shade mode ("unshade").
        public static let unshade = Sprite(.titlebar, 0, 27, 9, 9)
        public static let unshadePressed = Sprite(.titlebar, 9, 27, 9, 9)

        public static let clutterBar = Sprite(.titlebar, 304, 0, 8, 43)
        public static let clutterBarDisabled = Sprite(.titlebar, 312, 0, 8, 43)
        public static let clutterO = Sprite(.titlebar, 304, 47, 8, 8)
        public static let clutterA = Sprite(.titlebar, 312, 55, 8, 7)
        public static let clutterI = Sprite(.titlebar, 320, 62, 8, 7)
        public static let clutterD = Sprite(.titlebar, 328, 69, 8, 8)
        public static let clutterV = Sprite(.titlebar, 336, 77, 8, 7)

        public static let shadePositionBackground = Sprite(.titlebar, 0, 36, 17, 7)
        public static let shadePositionThumb = Sprite(.titlebar, 20, 36, 3, 7)
        public static let shadePositionThumbLeft = Sprite(.titlebar, 17, 36, 3, 7)
        public static let shadePositionThumbRight = Sprite(.titlebar, 23, 36, 3, 7)
    }

    public enum ShufRep {
        public static let shuffle = Sprite(.shufrep, 28, 0, 47, 15)
        public static let shufflePressed = Sprite(.shufrep, 28, 15, 47, 15)
        public static let shuffleOn = Sprite(.shufrep, 28, 30, 47, 15)
        public static let shuffleOnPressed = Sprite(.shufrep, 28, 45, 47, 15)
        public static let repeatOff = Sprite(.shufrep, 0, 0, 28, 15)
        public static let repeatPressed = Sprite(.shufrep, 0, 15, 28, 15)
        public static let repeatOn = Sprite(.shufrep, 0, 30, 28, 15)
        public static let repeatOnPressed = Sprite(.shufrep, 0, 45, 28, 15)

        public static let eq = Sprite(.shufrep, 0, 61, 23, 12)
        public static let eqOn = Sprite(.shufrep, 0, 73, 23, 12)
        public static let eqPressed = Sprite(.shufrep, 46, 61, 23, 12)
        public static let eqOnPressed = Sprite(.shufrep, 46, 73, 23, 12)
        public static let playlist = Sprite(.shufrep, 23, 61, 23, 12)
        public static let playlistOn = Sprite(.shufrep, 23, 73, 23, 12)
        public static let playlistPressed = Sprite(.shufrep, 69, 61, 23, 12)
        public static let playlistOnPressed = Sprite(.shufrep, 69, 73, 23, 12)
    }

    public enum Volume {
        /// 28 frames of 68x15 stacked vertically; 13 rows of each are visible.
        public static let background = Sprite(.volume, 0, 0, 68, 420)
        public static let thumb = Sprite(.volume, 15, 422, 14, 11)
        public static let thumbPressed = Sprite(.volume, 0, 422, 14, 11)
    }

    public enum Balance {
        /// 28 frames of 38x15 stacked vertically, starting at x = 9.
        public static let background = Sprite(.balance, 9, 0, 38, 420)
        public static let thumb = Sprite(.balance, 15, 422, 14, 11)
        public static let thumbPressed = Sprite(.balance, 0, 422, 14, 11)
    }

    public enum PosBar {
        public static let background = Sprite(.posbar, 0, 0, 248, 10)
        public static let thumb = Sprite(.posbar, 248, 0, 29, 10)
        public static let thumbPressed = Sprite(.posbar, 278, 0, 29, 10)
    }

    public enum PlayPaus {
        public static let playing = Sprite(.playpaus, 0, 0, 9, 9)
        public static let paused = Sprite(.playpaus, 9, 0, 9, 9)
        public static let stopped = Sprite(.playpaus, 18, 0, 9, 9)
        /// Only the leftmost 3 columns of these are shown, left of the status icon.
        public static let notWorking = Sprite(.playpaus, 36, 0, 9, 9)
        public static let working = Sprite(.playpaus, 39, 0, 9, 9)
    }

    public enum MonoSter {
        public static let stereo = Sprite(.monoster, 0, 12, 29, 12)
        public static let stereoOn = Sprite(.monoster, 0, 0, 29, 12)
        public static let mono = Sprite(.monoster, 29, 12, 27, 12)
        public static let monoOn = Sprite(.monoster, 29, 0, 27, 12)
    }

    public enum Numbers {
        public static func digit(_ n: Int) -> Sprite { Sprite(.numbers, n * 9, 0, 9, 13) }
        public static let noMinus = Sprite(.numbers, 9, 6, 5, 1)
        public static let minus = Sprite(.numbers, 20, 6, 5, 1)
    }

    public enum NumsEx {
        public static func digit(_ n: Int) -> Sprite { Sprite(.numsEx, n * 9, 0, 9, 13) }
        public static let noMinus = Sprite(.numsEx, 90, 0, 9, 13)
        public static let minus = Sprite(.numsEx, 99, 0, 9, 13)
    }

    public enum EqMain {
        public static let background = Sprite(.eqmain, 0, 0, 275, 116)
        public static let titleBar = Sprite(.eqmain, 0, 149, 275, 14)
        public static let titleBarActive = Sprite(.eqmain, 0, 134, 275, 14)
        /// 28 frames of 14x63 in two rows of 14, 15 px apart horizontally and 65 px vertically.
        public static let sliderBackground = Sprite(.eqmain, 13, 164, 209, 129)
        public static let sliderThumb = Sprite(.eqmain, 0, 164, 11, 11)
        public static let sliderThumbPressed = Sprite(.eqmain, 0, 176, 11, 11)
        public static let close = Sprite(.eqmain, 0, 116, 9, 9)
        public static let closePressed = Sprite(.eqmain, 0, 125, 9, 9)
        /// Part of the title bar image, used when EQ_EX.BMP is missing.
        public static let maximizePressedFallback = Sprite(.eqmain, 254, 152, 9, 9)

        public static let on = Sprite(.eqmain, 10, 119, 26, 12)
        public static let onPressed = Sprite(.eqmain, 128, 119, 26, 12)
        public static let onSelected = Sprite(.eqmain, 69, 119, 26, 12)
        public static let onSelectedPressed = Sprite(.eqmain, 187, 119, 26, 12)
        public static let auto = Sprite(.eqmain, 36, 119, 32, 12)
        public static let autoPressed = Sprite(.eqmain, 154, 119, 32, 12)
        public static let autoSelected = Sprite(.eqmain, 95, 119, 32, 12)
        public static let autoSelectedPressed = Sprite(.eqmain, 213, 119, 32, 12)

        public static let graphBackground = Sprite(.eqmain, 0, 294, 113, 19)
        /// One column of 19 colours, one per graph row.
        public static let graphLineColors = Sprite(.eqmain, 115, 294, 1, 19)
        public static let preampLine = Sprite(.eqmain, 0, 314, 113, 1)
        public static let presets = Sprite(.eqmain, 224, 164, 44, 12)
        public static let presetsPressed = Sprite(.eqmain, 224, 176, 44, 12)
    }

    public enum EqEx {
        public static let shadeActive = Sprite(.eqEx, 0, 0, 275, 14)
        public static let shadeInactive = Sprite(.eqEx, 0, 15, 275, 14)
        public static let shadeVolumeThumbLeft = Sprite(.eqEx, 1, 30, 3, 7)
        public static let shadeVolumeThumbCenter = Sprite(.eqEx, 4, 30, 3, 7)
        public static let shadeVolumeThumbRight = Sprite(.eqEx, 7, 30, 3, 7)
        public static let shadeBalanceThumbLeft = Sprite(.eqEx, 11, 30, 3, 7)
        public static let shadeBalanceThumbCenter = Sprite(.eqEx, 14, 30, 3, 7)
        public static let shadeBalanceThumbRight = Sprite(.eqEx, 17, 30, 3, 7)
        public static let maximizePressed = Sprite(.eqEx, 1, 38, 9, 9)
        public static let minimizePressed = Sprite(.eqEx, 1, 47, 9, 9)
        public static let shadeClose = Sprite(.eqEx, 11, 38, 9, 9)
        public static let shadeClosePressed = Sprite(.eqEx, 11, 47, 9, 9)
    }

    public enum PlEdit {
        public static let topLeft = Sprite(.pledit, 0, 21, 25, 20)
        public static let topTitle = Sprite(.pledit, 26, 21, 100, 20)
        public static let topTile = Sprite(.pledit, 127, 21, 25, 20)
        public static let topRight = Sprite(.pledit, 153, 21, 25, 20)
        public static let topLeftActive = Sprite(.pledit, 0, 0, 25, 20)
        public static let topTitleActive = Sprite(.pledit, 26, 0, 100, 20)
        public static let topTileActive = Sprite(.pledit, 127, 0, 25, 20)
        public static let topRightActive = Sprite(.pledit, 153, 0, 25, 20)

        public static let leftTile = Sprite(.pledit, 0, 42, 12, 29)
        public static let rightTile = Sprite(.pledit, 31, 42, 20, 29)
        public static let bottomTile = Sprite(.pledit, 179, 0, 25, 38)
        public static let bottomLeft = Sprite(.pledit, 0, 72, 125, 38)
        public static let bottomRight = Sprite(.pledit, 126, 72, 150, 38)
        public static let visualizerBackground = Sprite(.pledit, 205, 0, 75, 38)

        public static let scrollThumb = Sprite(.pledit, 52, 53, 8, 18)
        public static let scrollThumbPressed = Sprite(.pledit, 61, 53, 8, 18)

        public static let shadeBackground = Sprite(.pledit, 72, 57, 25, 14)
        public static let shadeLeft = Sprite(.pledit, 72, 42, 25, 14)
        public static let shadeRight = Sprite(.pledit, 99, 57, 50, 14)
        public static let shadeRightActive = Sprite(.pledit, 99, 42, 50, 14)

        public static let closePressed = Sprite(.pledit, 52, 42, 9, 9)
        public static let shadePressed = Sprite(.pledit, 62, 42, 9, 9)
        public static let unshadePressed = Sprite(.pledit, 150, 42, 9, 9)

        // Pop-up menus of the bottom bar: each item as idle / hovered.
        public static let addURL = Sprite(.pledit, 0, 111, 22, 18)
        public static let addURLHover = Sprite(.pledit, 23, 111, 22, 18)
        public static let addDir = Sprite(.pledit, 0, 130, 22, 18)
        public static let addDirHover = Sprite(.pledit, 23, 130, 22, 18)
        public static let addFile = Sprite(.pledit, 0, 149, 22, 18)
        public static let addFileHover = Sprite(.pledit, 23, 149, 22, 18)
        public static let removeAll = Sprite(.pledit, 54, 111, 22, 18)
        public static let removeAllHover = Sprite(.pledit, 77, 111, 22, 18)
        public static let crop = Sprite(.pledit, 54, 130, 22, 18)
        public static let cropHover = Sprite(.pledit, 77, 130, 22, 18)
        public static let removeSelected = Sprite(.pledit, 54, 149, 22, 18)
        public static let removeSelectedHover = Sprite(.pledit, 77, 149, 22, 18)
        public static let removeMisc = Sprite(.pledit, 54, 168, 22, 18)
        public static let removeMiscHover = Sprite(.pledit, 77, 168, 22, 18)
        public static let invertSelection = Sprite(.pledit, 104, 111, 22, 18)
        public static let invertSelectionHover = Sprite(.pledit, 127, 111, 22, 18)
        public static let selectNone = Sprite(.pledit, 104, 130, 22, 18)
        public static let selectNoneHover = Sprite(.pledit, 127, 130, 22, 18)
        public static let selectAll = Sprite(.pledit, 104, 149, 22, 18)
        public static let selectAllHover = Sprite(.pledit, 127, 149, 22, 18)
        public static let sortList = Sprite(.pledit, 154, 111, 22, 18)
        public static let sortListHover = Sprite(.pledit, 177, 111, 22, 18)
        public static let fileInfo = Sprite(.pledit, 154, 130, 22, 18)
        public static let fileInfoHover = Sprite(.pledit, 177, 130, 22, 18)
        public static let miscOptions = Sprite(.pledit, 154, 149, 22, 18)
        public static let miscOptionsHover = Sprite(.pledit, 177, 149, 22, 18)
        public static let newList = Sprite(.pledit, 204, 111, 22, 18)
        public static let newListHover = Sprite(.pledit, 227, 111, 22, 18)
        public static let saveList = Sprite(.pledit, 204, 130, 22, 18)
        public static let saveListHover = Sprite(.pledit, 227, 130, 22, 18)
        public static let loadList = Sprite(.pledit, 204, 149, 22, 18)
        public static let loadListHover = Sprite(.pledit, 227, 149, 22, 18)
        public static let addMenuBar = Sprite(.pledit, 48, 111, 3, 54)
        public static let removeMenuBar = Sprite(.pledit, 100, 111, 3, 72)
        public static let selectMenuBar = Sprite(.pledit, 150, 111, 3, 54)
        public static let miscMenuBar = Sprite(.pledit, 200, 111, 3, 54)
        public static let listMenuBar = Sprite(.pledit, 250, 111, 3, 54)
    }

    /// Controls of generic-window content (media library).
    public enum GenEx {
        public static let button = Sprite(.genex, 0, 0, 47, 15)
        public static let buttonPressed = Sprite(.genex, 0, 15, 47, 15)
        /// Caps and middle of a button stretched to any width.
        public static let buttonCap = 4
        public static let scrollUp = Sprite(.genex, 0, 31, 14, 14)
        public static let scrollDown = Sprite(.genex, 14, 31, 14, 14)
        public static let scrollUpPressed = Sprite(.genex, 28, 31, 14, 14)
        public static let scrollDownPressed = Sprite(.genex, 42, 31, 14, 14)
        public static let scrollLeft = Sprite(.genex, 0, 45, 14, 14)
        public static let scrollRight = Sprite(.genex, 14, 45, 14, 14)
        public static let verticalThumb = Sprite(.genex, 56, 31, 14, 28)
        public static let verticalThumbPressed = Sprite(.genex, 70, 31, 14, 28)
        public static let horizontalThumb = Sprite(.genex, 84, 31, 28, 14)
        public static let horizontalThumbPressed = Sprite(.genex, 84, 45, 28, 14)
    }

    public enum Gen {
        public static let topLeftActive = Sprite(.gen, 0, 0, 25, 20)
        public static let topLeftEndActive = Sprite(.gen, 26, 0, 25, 20)
        public static let topCenterFillActive = Sprite(.gen, 52, 0, 25, 20)
        public static let topRightEndActive = Sprite(.gen, 78, 0, 25, 20)
        public static let topLeftRightFillActive = Sprite(.gen, 104, 0, 25, 20)
        public static let topRightActive = Sprite(.gen, 130, 0, 25, 20)
        public static let topLeft = Sprite(.gen, 0, 21, 25, 20)
        public static let topLeftEnd = Sprite(.gen, 26, 21, 25, 20)
        public static let topCenterFill = Sprite(.gen, 52, 21, 25, 20)
        public static let topRightEnd = Sprite(.gen, 78, 21, 25, 20)
        public static let topLeftRightFill = Sprite(.gen, 104, 21, 25, 20)
        public static let topRight = Sprite(.gen, 130, 21, 25, 20)
        public static let bottomLeft = Sprite(.gen, 0, 42, 125, 14)
        public static let bottomRight = Sprite(.gen, 0, 57, 125, 14)
        public static let bottomFill = Sprite(.gen, 127, 72, 25, 14)
        public static let middleLeft = Sprite(.gen, 127, 42, 11, 29)
        public static let middleLeftBottom = Sprite(.gen, 158, 42, 11, 24)
        public static let middleRight = Sprite(.gen, 139, 42, 8, 29)
        public static let middleRightBottom = Sprite(.gen, 170, 42, 8, 24)
        public static let closePressed = Sprite(.gen, 148, 42, 9, 9)
    }
}
