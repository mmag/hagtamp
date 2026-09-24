import AppKit
import ClassicUI
import PlayerCore
import SkinKit
import UniformTypeIdentifiers

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
        NSMenu.popUpContextMenu(presetsMenu(), with: event, for: window.skinView)
        setPressed(nil)
        return false
    }

    // MARK: - Presets

    /// Winamp's PRESETS menu: Load / Save / Delete.
    private func presetsMenu() -> NSMenu {
        let model = manager.model
        let menu = NSMenu()
        menu.autoenablesItems = false

        let load = NSMenu()
        load.autoenablesItems = false
        load.addItem(NSMenuItem(title: "Default") { model.apply(.flat) })
        load.addItem(.separator())
        for preset in EqualizerPreset.builtIn {
            load.addItem(NSMenuItem(title: preset.name) { model.apply(preset) })
        }
        if !model.userPresets.isEmpty {
            load.addItem(.separator())
            for preset in model.userPresets {
                load.addItem(NSMenuItem(title: preset.name) { model.apply(preset) })
            }
        }
        load.addItem(.separator())
        load.addItem(NSMenuItem(title: "From EQF…") { [weak self] in self?.loadEQF() })
        menu.addItem(submenu: load, title: "Load")

        let save = NSMenu()
        save.addItem(NSMenuItem(title: "Preset…") { [weak self] in self?.savePreset() })
        save.addItem(NSMenuItem(title: "To EQF…") { [weak self] in self?.saveEQF() })
        menu.addItem(submenu: save, title: "Save")

        let delete = NSMenu()
        delete.autoenablesItems = false
        for preset in model.userPresets {
            delete.addItem(NSMenuItem(title: preset.name) { model.deleteUserPreset(named: preset.name) })
        }
        let deleteItem = menu.addItem(submenu: delete, title: "Delete")
        deleteItem.isEnabled = !model.userPresets.isEmpty
        return menu
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save equalizer preset"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { manager.model.saveUserPreset(named: name) }
    }

    private static var eqfTypes: [UTType] {
        ["eqf", "q1"].compactMap { UTType(filenameExtension: $0) }
    }

    private func loadEQF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.eqfTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let preset = try EQFFile.parse(Data(contentsOf: url)).first else { return }
            manager.model.apply(preset)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func saveEQF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.eqfTypes
        panel.nameFieldStringValue = "preset.eqf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let model = manager.model
        let preset = EqualizerPreset(name: url.deletingPathExtension().lastPathComponent, bands: model.bands, preamp: model.preamp)
        do {
            try EQFFile.data(for: [preset]).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    override func contextMenuRequested(at point: SkinPoint, event: NSEvent) {
        manager.showMainMenu(for: event, in: window.skinView)
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(submenu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return item
    }
}
