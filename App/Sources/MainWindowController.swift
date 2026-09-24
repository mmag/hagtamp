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
        if model.status != .stopped, manager.timeVisible, let track = model.currentTrack {
            let elapsed = Int(model.elapsed)
            s.time =
                manager.timeMode == .elapsed
                ? TimeDisplay(seconds: elapsed) : TimeDisplay(seconds: track.duration - elapsed, mode: .remaining)
        }
        s.marqueeText = pressed == .clutterDoubleSize ? Marquee.doubleSizeText(enabled: manager.doubleSize) : manager.marqueeText
        s.marqueeOffset = pressed == .clutterDoubleSize ? 0 : manager.marqueeOffset
        if let track = model.currentTrack {
            // Numbers are right-aligned in their boxes.
            s.kbps = String(track.kbps).leftPadded(to: 3)
            s.khz = String(track.khz).leftPadded(to: 2)
            s.channels = track.channels
        }
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
            guard model.status != .stopped, let track = model.currentTrack else { return }
            scrubPosition = value
            manager.marqueeMessage = Marquee.seekText(position: value, duration: track.duration)
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
        default: break  // eject, file info: stage 3/4
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
            // Visualization menu: stage 3. Show the button pressed while held.
            setPressed(control)
            return true
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
        manager.showMainMenu(for: event, in: window.skinView)
    }
}

extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
