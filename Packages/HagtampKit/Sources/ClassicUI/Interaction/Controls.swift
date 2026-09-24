import SkinKit

/// Everything the pointer can press, drag or click in the classic windows.
public enum Control: Hashable, Sendable {
    // Title bars
    case titleBar
    case options, minimize, shade, close

    // Main window
    case clutterOptions, clutterAlwaysOnTop, clutterInfo, clutterDoubleSize, clutterVisualization
    case time, visualizer, marquee
    case volume, balance, position
    case equalizerToggle, playlistToggle
    case previous, play, pause, stop, next, eject
    case shuffle, repeatToggle
    case about

    // Equalizer
    case equalizerOn, equalizerAuto, presets
    case preamp, band(Int)
    case bandsMax, bandsFlat, bandsMin

    // Playlist
    case trackList, scrollBar, scrollUp, scrollDown, resize
    case menu(PlaylistMenu)
    case miniTime
}

/// The pop-up button menus at the bottom of the playlist.
public enum PlaylistMenu: CaseIterable, Sendable {
    case add, remove, select, misc, list

    /// Items from top to bottom; the last one sits over the button itself.
    public var items: [PlaylistMenuItem] {
        switch self {
        case .add: [.addURL, .addDirectory, .addFile]
        case .remove: [.removeMisc, .removeAll, .crop, .removeSelected]
        case .select: [.invertSelection, .selectNone, .selectAll]
        case .misc: [.sortList, .fileInfo, .miscOptions]
        case .list: [.newList, .saveList, .loadList]
        }
    }
}

public enum PlaylistMenuItem: Sendable {
    case addURL, addDirectory, addFile
    case removeMisc, removeAll, crop, removeSelected
    case invertSelection, selectNone, selectAll
    case sortList, fileInfo, miscOptions
    case newList, saveList, loadList
}

/// How a control reacts to the pointer.
public enum ControlBehavior: Sendable {
    /// Acts on release, only if the pointer is still inside.
    case button
    /// Value follows the pointer while dragging.
    case slider(SliderGeometry)
    /// Moves the window (title bars and, with easy move, the window body).
    case moveWindow
    /// Acts on press (menus, click-to-toggle displays, drags with own logic).
    case press
}

/// A control's hit area, behaviour and the skin cursor shown over it.
public struct ControlRegion: Sendable {
    public let control: Control
    public let rect: PixelRect
    public let behavior: ControlBehavior
    public let cursor: SkinCursorName

    public init(_ control: Control, _ rect: PixelRect, _ behavior: ControlBehavior, cursor: SkinCursorName) {
        self.control = control
        self.rect = rect
        self.behavior = behavior
        self.cursor = cursor
    }

    init(_ control: Control, _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ behavior: ControlBehavior = .button, cursor: SkinCursorName) {
        self.init(control, PixelRect(x: x, y: y, width: width, height: height), behavior, cursor: cursor)
    }
}

/// Track and thumb of a slider along one axis, in window pixels.
public struct SliderGeometry: Sendable, Equatable {
    public enum Axis: Sendable { case horizontal, vertical }

    public let axis: Axis
    /// Where the track starts along the axis.
    public let origin: Int
    public let length: Int
    public let thumb: Int
    /// Vertical sliders are at their maximum at the top.
    public let invert: Bool
    /// Round thumb positions down instead of to nearest (Webamp's vertical slider).
    public let roundsDown: Bool

    public init(axis: Axis, origin: Int, length: Int, thumb: Int, invert: Bool = false, roundsDown: Bool = false) {
        self.axis = axis
        self.origin = origin
        self.length = length
        self.thumb = thumb
        self.invert = invert
        self.roundsDown = roundsDown
    }

    public var travel: Int { max(0, length - thumb) }

    /// Thumb start along the axis for a value in 0...1.
    public func thumbPosition(_ value: Double) -> Int {
        let v = min(1, max(0, value))
        let offset = Double(travel) * (invert ? 1 - v : v)
        return origin + Int(roundsDown ? offset.rounded(.down) : offset.rounded())
    }

    /// Where on the thumb the pointer holds it: the pressed point when the
    /// press lands on the thumb, otherwise its centre (the thumb jumps there).
    public func grabOffset(pointer: Int, value: Double) -> Int {
        let start = thumbPosition(value)
        return (start..<start + thumb).contains(pointer) ? pointer - start : thumb / 2
    }

    /// Value for a pointer position, holding the thumb at `grab`.
    public func value(pointer: Int, grab: Int) -> Double {
        guard travel > 0 else { return 0 }
        let v = min(1, max(0, Double(pointer - grab - origin) / Double(travel)))
        return invert ? 1 - v : v
    }
}
