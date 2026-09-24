import AppKit
import SkinKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let lastSkinKey = "lastSkinPath"

    private let model = PlayerModel()
    private let navidrome = NavidromeService()
    private let radio = RadioResolver()
    private let localLibrary = LocalLibraryService()
    private lazy var windows = WindowManager(model: model, skin: .base, navidrome: navidrome, localLibrary: localLibrary)
    private lazy var preferences = PreferencesWindowController(player: model, navidrome: navidrome, library: localLibrary)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.resolvers = [navidrome, radio]
        radio.onTitle = { [weak model] title, url in model?.streamTitleChanged(title, for: url) }
        NSApp.mainMenu = makeMainMenu()
        if let path = Storage.defaults.string(forKey: Self.lastSkinKey) {
            loadSkin(from: URL(fileURLWithPath: path), remember: false)
        }
        windows.start()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windows.saveLayout()
        model.savePosition(force: true)
    }

    /// Finder "Open With": skins are applied, audio files are played.
    func application(_ application: NSApplication, open urls: [URL]) {
        windows.filesDropped(urls, on: .main)
    }

    // MARK: - Skins

    func loadSkin(from url: URL, remember: Bool = true) {
        do {
            windows.setSkin(try Skin.load(contentsOf: url))
            if remember { Storage.defaults.set(url.path, forKey: Self.lastSkinKey) }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't load skin “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func openSkin(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .zip, .zip]
        panel.canChooseDirectories = true
        panel.message = "Choose a skin (.wsz) or an unpacked skin folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSkin(from: url)
    }

    @objc func showPreferences(_ sender: Any?) {
        preferences.show()
    }

    @objc func useBaseSkin(_ sender: Any?) {
        windows.setSkin(.base)
        Storage.defaults.removeObject(forKey: Self.lastSkinKey)
    }

    // MARK: - Menu bar

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Hagtamp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Hagtamp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hagtamp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(submenu: appMenu, title: "Hagtamp")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(target: windows, "Play File…", #selector(WindowManager.openFiles), key: "o", modifiers: .command)
        fileMenu.addItem(withTitle: "Open Skin…", action: #selector(openSkin(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Use Base Skin", action: #selector(useBaseSkin(_:)), keyEquivalent: "")
        menu.addItem(submenu: fileMenu, title: "File")

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(target: windows, "Playlist Editor", #selector(WindowManager.togglePlaylist), key: "e", modifiers: .option)
        viewMenu.addItem(target: windows, "Equalizer", #selector(WindowManager.toggleEqualizer), key: "g", modifiers: .option)
        viewMenu.addItem(target: windows, "Album Art", #selector(WindowManager.toggleAlbumArt), key: "a", modifiers: .option)
        viewMenu.addItem(target: windows, "Local Library", #selector(WindowManager.toggleLocalLibrary), key: "m", modifiers: .option)
        viewMenu.addItem(target: windows, "Navidrome", #selector(WindowManager.toggleNavidromeLibrary), key: "l", modifiers: .option)
        viewMenu.addItem(.separator())
        viewMenu.addItem(target: windows, "Double Size", #selector(WindowManager.toggleDoubleSize), key: "d", modifiers: .command)
        viewMenu.addItem(target: windows, "Always On Top", #selector(WindowManager.toggleAlwaysOnTop), key: "a", modifiers: .control)
        menu.addItem(submenu: viewMenu, title: "View")

        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }

    func addItem(target: AnyObject, _ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        addItem(item)
    }
}
