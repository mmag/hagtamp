import AppKit
import ClassicUI
import PlayerCore

/// Winamp's main menu (options button, clutter bar "O", right click), with
/// its shortcuts shown the way Winamp lists them.
extension WindowManager {
    func showMainMenu(for event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(mainMenu(), with: event, for: view)
    }

    func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSApp.delegate as? AppDelegate
        menu.addItem(Self.item("About Hagtamp…") { NSApp.orderFrontStandardAboutPanel(nil) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Play File…", key: "l") { [weak self] in self?.openFiles() })
        menu.addItem(Self.item("Play URL…", key: "l", .control) { [weak self] in self?.playURL() })
        menu.addItem(.separator())
        menu.addItem(Self.item("Main Window", checked: true, key: "w", .option) {})
        menu.addItem(Self.item("Playlist Editor", checked: isVisible(.playlist), key: "e", .option) { [weak self] in self?.togglePlaylist() })
        menu.addItem(Self.item("Equalizer", checked: isVisible(.equalizer), key: "g", .option) { [weak self] in self?.toggleEqualizer() })
        menu.addItem(Self.item("Album Art", checked: isVisible(.albumArt), key: "a", .option) { [weak self] in self?.toggleAlbumArt() })
        menu.addItem(Self.item("Local Library", checked: isVisible(.localLibrary), key: "m", .option) { [weak self] in self?.toggleLocalLibrary() })
        menu.addItem(Self.item("Navidrome", checked: isVisible(.navidromeLibrary), key: "l", .option) { [weak self] in self?.toggleNavidromeLibrary() })
        menu.addItem(.separator())
        menu.addItem(Self.submenu("Skins", skinsMenu()))
        menu.addItem(Self.submenu("Options", optionsMenu()))
        menu.addItem(Self.submenu("Playback", playbackMenu()))
        menu.addItem(Self.submenu("Visualization", visualizerMenu()))
        menu.addItem(.separator())
        menu.addItem(Self.item("Preferences…", key: "p", .control) { app?.showPreferences(nil) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Exit") { NSApp.terminate(nil) })
        return menu
    }

    func skinsMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSApp.delegate as? AppDelegate
        let current = SkinLibrary.current?.standardizedFileURL
        menu.addItem(Self.item("Skin Browser…", key: "s", .option) { app?.showSkinBrowser(nil) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Base Skin", checked: current == nil) { app?.useBaseSkin(nil) })
        for skin in SkinLibrary.installed() {
            menu.addItem(Self.item(SkinLibrary.name(of: skin), checked: skin.standardizedFileURL == current) { app?.loadSkin(from: skin) })
        }
        menu.addItem(.separator())
        menu.addItem(Self.item("Open Skin…") { app?.openSkin(nil) })
        return menu
    }

    func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(Self.item("Time Elapsed", checked: timeMode == .elapsed, key: "t", .control) { [weak self] in self?.timeMode = .elapsed })
        menu.addItem(Self.item("Time Remaining", checked: timeMode == .remaining, key: "t", .control) { [weak self] in self?.timeMode = .remaining })
        menu.addItem(.separator())
        menu.addItem(Self.item("Double Size", checked: doubleSize, key: "d", .control) { [weak self] in self?.toggleDoubleSize() })
        menu.addItem(Self.item("Always On Top", checked: alwaysOnTop, key: "a", .control) { [weak self] in self?.toggleAlwaysOnTop() })
        menu.addItem(.separator())
        menu.addItem(Self.item("Repeat", checked: model.repeatEnabled, key: "r") { [weak self] in self?.model.repeatEnabled.toggle() })
        menu.addItem(Self.item("Shuffle", checked: model.shuffle, key: "s") { [weak self] in self?.model.shuffle.toggle() })
        return menu
    }

    func playbackMenu() -> NSMenu {
        let menu = NSMenu()
        let model = self.model
        menu.addItem(Self.item("Previous", key: "z") { model.previous() })
        menu.addItem(Self.item("Play", key: "x") { model.play() })
        menu.addItem(Self.item("Pause", key: "c") { model.pause() })
        menu.addItem(Self.item("Stop", key: "v") { model.stop() })
        menu.addItem(Self.item("Next", key: "b") { model.next() })
        menu.addItem(.separator())
        menu.addItem(Self.item("Stop with Fadeout", key: "v", .shift) { model.fadeOutAndStop() })
        menu.addItem(Self.item("Stop After Current", checked: model.stopsAfterCurrent, key: "v", .control) { model.stopsAfterCurrent.toggle() })
        menu.addItem(Self.item("Back 5 Seconds", key: "\u{F702}", []) { [weak self] in self?.seek(bySeconds: -5) })
        menu.addItem(Self.item("Forward 5 Seconds", key: "\u{F703}", []) { [weak self] in self?.seek(bySeconds: 5) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Start of List", key: "z", .control) { model.startOfList() })
        menu.addItem(Self.item("10 Tracks Back") { model.skip(tracks: -10) })
        menu.addItem(Self.item("10 Tracks Forward") { model.skip(tracks: 10) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Jump to Time…", key: "j", .control) { [weak self] in self?.jumpToTime() })
        menu.addItem(Self.item("Jump to File…", key: "j") { [weak self] in self?.showJumpToFile() })
        return menu
    }

    /// A menu item running `handler`; `key` is only shown (the windows handle the keys).
    static func item(
        _ title: String, checked: Bool = false, key: String = "", _ modifiers: NSEvent.ModifierFlags = [],
        handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, checked: checked, handler: handler)
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Dialogs

    /// Winamp's "Play URL" (Ctrl+L): a stream or file address replaces the playlist and plays.
    func playURL() {
        guard let url = Self.askForURL(title: "Play URL", message: "Enter the address of a stream (internet radio) or a file.") else { return }
        model.load(tracks: [TrackInfo(url: url)], play: true)
    }

    static func askForURL(title: String, message: String) -> URL? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "http://"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil
        else { return nil }
        return url
    }

    /// Winamp's "Jump to time" (Ctrl+J): minutes:seconds into the current track.
    func jumpToTime() {
        guard let duration = model.duration, duration > 0, model.status != .stopped else { return }
        let alert = NSAlert()
        alert.messageText = "Jump to Time"
        alert.informativeText = "Track length: \(Marquee.timeString(Int(duration)))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = Marquee.timeString(Int(model.elapsed))
        alert.accessoryView = field
        alert.addButton(withTitle: "Jump")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let seconds = Self.seconds(from: field.stringValue) else { return }
        model.seek(to: min(1, seconds / duration))
    }

    /// "1:23", "83" or "1:02:03".
    static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}
