import AppKit
import ClassicUI
import SkinKit

@MainActor
final class EqualizerWindowController: SkinWindowController {
    init(manager: WindowManager) {
        super.init(id: .equalizer, manager: manager)
    }

    override func regions() -> [ControlRegion] { EqualizerWindowLayout.regions(shade: shade) }
    override var bodyCursor: SkinCursorName {
        shade ? EqualizerWindowLayout.shadeBodyCursor : EqualizerWindowLayout.bodyCursor
    }
    override func pixelSize() -> (width: Int, height: Int) {
        (EqualizerWindowRenderer.width, shade ? EqualizerWindowRenderer.shadeHeight : EqualizerWindowRenderer.height)
    }
    override func shapePolygons() -> [SkinRegions.Polygon]? {
        shade ? manager.skin.regions.equalizerShade : manager.skin.regions.equalizer
    }
    override func renderBitmap() -> Bitmap { EqualizerWindowRenderer.render(manager.skin, state()) }

    private func state() -> EqualizerWindowState {
        let model = manager.model
        var s = EqualizerWindowState()
        s.focused = isFocused
        s.shade = shade
        s.pressed = pressed
        s.enabled = model.equalizerEnabled
        s.auto = model.equalizerAuto
        s.preamp = model.preamp
        s.bands = model.bands
        s.volume = model.volume
        s.balance = model.balance
        return s
    }

    // MARK: - Sliders

    override func sliderValue(_ control: Control) -> Double {
        let model = manager.model
        switch control {
        case .preamp: return model.preamp
        case .band(let i): return model.bands[i]
        case .volume: return model.volume
        case .balance: return (model.balance + 1) / 2
        default: return 0
        }
    }

    override func sliderChanged(_ control: Control, value: Double) {
        let model = manager.model
        switch control {
        case .preamp:
            model.preamp = value
            manager.marqueeMessage = Marquee.equalizerText(band: nil, value: value)
        case .band(let i):
            model.bands[i] = value
            manager.marqueeMessage = Marquee.equalizerText(band: i, value: value)
        case .volume:
            model.volume = value
            manager.marqueeMessage = Marquee.volumeText(value)
        case .balance:
            model.balance = value * 2 - 1
            manager.marqueeMessage = Marquee.balanceText(model.balance)
        default:
            break
        }
    }

    override func sliderEnded(_ control: Control, value: Double) {
        manager.marqueeMessage = nil
    }

    /// Dragging across the bands sets each one the pointer passes, like Winamp.
    override func mouseDragged(to point: SkinPoint, event: NSEvent) {
        if case .band(let current)? = pressed,
            let target = EqualizerWindowRenderer.bandX.firstIndex(where: { (0..<14).contains(point.x - $0) }),
            target != current
        {
            retargetSlider(to: .band(target), geometry: EqualizerWindowLayout.band, grab: EqualizerWindowLayout.band.thumb / 2)
        }
        super.mouseDragged(to: point, event: event)
    }

    // MARK: - Buttons

    override func buttonClicked(_ control: Control) {
        let model = manager.model
        switch control {
        case .shade: manager.toggleShade(.equalizer)
        case .close: manager.setVisible(.equalizer, false)
        case .equalizerOn: model.equalizerEnabled.toggle()
        case .equalizerAuto: model.equalizerAuto.toggle()
        case .bandsMax: model.bands = Array(repeating: 1, count: 10)
        case .bandsFlat: model.bands = Array(repeating: 0.5, count: 10)
        case .bandsMin: model.bands = Array(repeating: 0, count: 10)
        default: break
        }
    }

    override func pressBegan(_ control: Control, at point: SkinPoint, event: NSEvent) -> Bool {
        guard control == .presets else { return false }
        setPressed(.presets)
        let menu = NSMenu()
        for title in ["Load", "Save", "Delete"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false  // presets: stage 3
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        NSMenu.popUpContextMenu(menu, with: event, for: window.skinView)
        setPressed(nil)
        return false
    }

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        manager.showMainMenu(for: event, in: window.skinView)
    }
}
