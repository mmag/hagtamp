import AppKit
import ClassicUI
import SkinKit

@MainActor
final class MainWindowController: SkinWindowController {
    /// Seek bar position while it is being dragged; seeking happens on release.
    private var scrubPosition: Double?
    private var marqueeDragStartX = 0

    init(manager: WindowManager) {
        super.init(id: .main, manager: manager)
    }

    override func regions() -> [ControlRegion] { MainWindowLayout.regions(shade: shade) }
    override var bodyCursor: SkinCursorName { shade ? MainWindowLayout.shadeBodyCursor : MainWindowLayout.bodyCursor }
    override func pixelSize() -> (width: Int, height: Int) {
        (MainWindowRenderer.width, shade ? MainWindowRenderer.shadeHeight : MainWindowRenderer.height)
    }
    override func shapePolygons() -> [SkinRegions.Polygon]? {
        shade ? manager.skin.regions.mainShade : manager.skin.regions.main
    }
    override func renderBitmap() -> Bitmap { MainWindowRenderer.render(manager.skin, state()) }

    private func state() -> MainWindowState {
        let model = manager.model
        var s = MainWindowState()
        s.focused = isFocused
        s.shade = shade
        s.pressed = pressed
        s.status = model.status
        if model.status != .stopped, manager.timeVisible {
            let elapsed = Int(model.elapsed)
            if manager.timeMode == .remaining, let duration = model.duration {
                s.time = TimeDisplay(seconds: max(0, Int(duration) - elapsed), mode: .remaining)
            } else {
                s.time = TimeDisplay(seconds: elapsed)
            }
        }
        s.marqueeText = pressed == .clutterDoubleSize ? Marquee.doubleSizeText(enabled: manager.doubleSize) : manager.marqueeText
        s.marqueeOffset = pressed == .clutterDoubleSize ? 0 : manager.marqueeOffset
        if let track = model.displayedTrack {
            // Right-aligned in their boxes; longer values are cut by the box (1411 kbps shows "141").
            s.kbps = track.bitrate.map { String($0).leftPadded(to: 3) }
            s.khz = track.sampleRate.map { String(Int(($0 / 1000).rounded())).leftPadded(to: 2) }
            s.channels = track.channels
        }
        s.visualizer = manager.visualizerFrame
        s.working = model.buffering != nil
        s.volume = model.volume
        s.balance = model.balance
        s.position = scrubPosition ?? model.position
        s.shuffle = model.shuffle
        s.repeatEnabled = model.repeatEnabled
        s.equalizerOpen = manager.isVisible(.equalizer)
        s.playlistOpen = manager.isVisible(.playlist)
        s.doubleSize = manager.doubleSize
        s.alwaysOnTop = manager.alwaysOnTop
        return s
    }

    // MARK: - Sliders

    override func sliderValue(_ control: Control) -> Double {
        let model = manager.model
        switch control {
        case .volume: return model.volume
        case .balance: return (model.balance + 1) / 2
        case .position: return scrubPosition ?? model.position
        default: return 0
        }
    }

    override func sliderChanged(_ control: Control, value: Double) {
        let model = manager.model
        switch control {
        case .volume:
            model.volume = value
            manager.marqueeMessage = Marquee.volumeText(value)
        case .balance:
            model.balance = value * 2 - 1
            manager.marqueeMessage = Marquee.balanceText(model.balance)
        case .position:
            guard model.status != .stopped, let duration = model.duration else { return }
            scrubPosition = value
            manager.marqueeMessage = Marquee.seekText(position: value, duration: Int(duration))
        default:
            break
        }
        manager.render()
    }

    override func sliderEnded(_ control: Control, value: Double) {
        if control == .position, scrubPosition != nil {
            scrubPosition = nil
            manager.model.seek(to: value)
        }
        manager.marqueeMessage = nil
        manager.render()
    }

    // MARK: - Buttons

    override func buttonClicked(_ control: Control) {
        let model = manager.model
        switch control {
        case .minimize: NSApp.hide(nil)
        case .shade: manager.toggleShade(.main)
        case .close: NSApp.terminate(nil)
        case .clutterAlwaysOnTop: manager.toggleAlwaysOnTop()
        case .clutterDoubleSize: manager.toggleDoubleSize()
        case .equalizerToggle: manager.toggleEqualizer()
        case .playlistToggle: manager.togglePlaylist()
        case .previous: model.previous()
        case .play: model.play()
        case .pause: model.pause()
        case .stop: model.stop()
        case .next: model.next()
        case .shuffle: model.shuffle.toggle()
        case .repeatToggle: model.repeatEnabled.toggle()
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        case .eject: manager.openFiles()
        case .clutterInfo: model.displayedTrack.map(FileInfoPanel.show)
        default: break
        }
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        switch control {
        case .options, .clutterOptions:
            setPressed(control)
            manager.showMainMenu(for: event, in: window.skinView)
            setPressed(nil)
            return false
        case .time:
            manager.timeMode = manager.timeMode == .elapsed ? .remaining : .elapsed
            manager.render()
            return false
        case .clutterVisualization:
            setPressed(control)
            manager.showVisualizerMenu(for: event, in: window.skinView)
            setPressed(nil)
            return false
        case .visualizer:
            manager.cycleVisualizer()
            return false
        case .marquee:
            marqueeDragStartX = point.x
            manager.beginMarqueeDrag()
            return true
        default:
            return false
        }
    }

    override func pressDragged(_ control: Control, to point: SkinPoint, event: NSEvent) {
        if control == .marquee { manager.dragMarquee(by: point.x - marqueeDragStartX) }
    }

    override func pressEnded(_ control: Control, at point: SkinPoint, event: NSEvent) {
        switch control {
        case .marquee: manager.endMarqueeDrag()
        default: setPressed(nil)
        }
    }

    override func scrolled(by delta: CGFloat) {
        manager.model.volume = min(1, max(0, manager.model.volume + Double(delta) * 0.02))
    }

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        if regions().hit(x: point.x, y: point.y)?.control == .visualizer {
            manager.showVisualizerMenu(for: event, in: window.skinView)
        } else {
            manager.showMainMenu(for: event, in: window.skinView)
        }
    }
}

extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
