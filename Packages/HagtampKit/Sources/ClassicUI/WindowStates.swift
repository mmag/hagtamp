import SkinKit

/// Everything the renderers need to draw a frame. These are plain snapshots
/// produced by the UI layer; renderers never hold state themselves.

public enum PlaybackStatus: Sendable {
    case stopped, playing, paused
}

public enum TimeDisplayMode: Sendable {
    case elapsed, remaining
}

/// Time shown by the main window's big digits and the mini time displays.
public struct TimeDisplay: Sendable, Equatable {
    public var seconds: Int
    public var mode: TimeDisplayMode

    public init(seconds: Int, mode: TimeDisplayMode = .elapsed) {
        self.seconds = seconds
        self.mode = mode
    }

    /// Minutes and seconds as four digits; minutes wrap at 100 like Winamp.
    var digits: [Int] {
        let s = max(0, seconds)
        let minutes = (s / 60) % 100
        return [minutes / 10, minutes % 10, (s % 60) / 10, s % 10]
    }
}

public struct MainWindowState: Sendable {
    public var focused = true
    public var shade = false
    /// The control held down by the pointer (drawn pressed).
    public var pressed: Control?
    public var status = PlaybackStatus.stopped
    /// Nil while stopped; hidden during the "off" phase of the pause blink.
    public var time: TimeDisplay?
    /// Text of the scrolling song title display (already formatted).
    public var marqueeText = "Hagtamp"
    /// Horizontal scroll of the marquee in pixels.
    public var marqueeOffset = 0
    public var kbps: String?
    public var khz: String?
    /// 1 = mono, 2 = stereo, nil = unknown / stopped.
    public var channels: Int?
    /// 0...1
    public var volume = 200.0 / 255.0
    /// -1...1
    public var balance = 0.0
    /// Playback position 0...1; nil hides the seek bar thumb.
    public var position: Double?
    public var shuffle = false
    public var repeatEnabled = false
    public var equalizerOpen = false
    public var playlistOpen = false
    public var doubleSize = false
    public var alwaysOnTop = false
    /// Stream buffering ("working") indicator.
    public var working = false
    /// Current visualizer frame (76x16, or 38x5 in shade mode); nil leaves the skin's background.
    public var visualizer: Bitmap?

    public init() {}
}

public struct EqualizerWindowState: Sendable {
    public var focused = false
    public var shade = false
    public var pressed: Control?
    public var enabled = true
    public var auto = false
    /// Slider positions 0...1, 0.5 = 0 dB.
    public var preamp = 0.5
    public var bands = [Double](repeating: 0.5, count: 10)
    /// Shown by the shade mode sliders.
    public var volume = 200.0 / 255.0
    public var balance = 0.0

    public init() {}
}

public struct PlaylistRow: Sendable, Equatable {
    public var title: String
    public var duration: String

    public init(title: String, duration: String) {
        self.title = title
        self.duration = duration
    }
}

public struct PlaylistWindowState: Sendable {
    public var focused = false
    public var shade = false
    public var pressed: Control?
    /// Extra size in 25 px (width) and 29 px (height) steps.
    public var widthSteps = 0
    public var heightSteps = 0
    public var rows: [PlaylistRow] = []
    public var firstVisibleRow = 0
    public var selectedRows: Set<Int> = []
    public var currentRow: Int?
    /// e.g. "4:00/12:36"
    public var runningTime = ""
    /// Nil shows the blank mini time (stopped, or the "off" phase of the pause blink).
    public var miniTime: TimeDisplay?
    /// The bottom-bar menu that is popped up, and the item under the pointer.
    public var openMenu: PlaylistMenu?
    public var hoveredMenuItem: Int?
    /// Current track as shown in shade mode ("1. Artist - Title"), with its length.
    public var currentTitle: String?
    public var currentDuration = ""

    public init() {}

    public var pixelWidth: Int { PlaylistWindowRenderer.baseWidth + widthSteps * 25 }
    public var pixelHeight: Int { shade ? 14 : PlaylistWindowRenderer.baseHeight + heightSteps * 29 }
}
