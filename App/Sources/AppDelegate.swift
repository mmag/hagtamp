import AppKit
import SkinKit
import SkinRenderer
import UniformTypeIdentifiers

/// Stage 1 shell: shows the three classic windows rendered from a skin in a
/// fixed demo state. Player state and real window behaviour come next.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let lastSkinKey = "lastSkinPath"

    private var skin = Skin.base
    private var doubleSize = false

    private let mainWindow = SkinWindow()
    private let equalizerWindow = SkinWindow()
    private let playlistWindow = SkinWindow()
    private var windows: [SkinWindow] { [mainWindow, equalizerWindow, playlistWindow] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        for window in windows {
            window.onFocusChange = { [weak self] in self?.render() }
            window.skinView.onFileDrop = { [weak self] url in self?.loadSkin(from: url) }
        }
        if let path = UserDefaults.standard.string(forKey: Self.lastSkinKey) {
            loadSkin(from: URL(fileURLWithPath: path), remember: false)
        }
        render()
        layOutWindows()
        windows.reversed().forEach { $0.orderFront(nil) }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { loadSkin(from: url) }
    }

    // MARK: - Skins

    private func loadSkin(from url: URL, remember: Bool = true) {
        do {
            skin = try Skin.load(contentsOf: url)
            if remember { UserDefaults.standard.set(url.path, forKey: Self.lastSkinKey) }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            render()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't load skin “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openSkin(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .zip, .zip]
        panel.canChooseDirectories = true
        panel.message = "Choose a Winamp skin (.wsz) or an unpacked skin folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSkin(from: url)
    }

    @objc private func useBaseSkin(_ sender: Any?) {
        skin = .base
        UserDefaults.standard.removeObject(forKey: Self.lastSkinKey)
        render()
    }

    @objc private func toggleDoubleSize(_ sender: Any?) {
        doubleSize.toggle()
        render()
        layOutWindows()
    }

    // MARK: - Rendering

    private func render() {
        let scale = doubleSize ? 2 : 1

        var main = ReferenceScene.mainState
        main.focused = mainWindow.isKeyWindow
        main.doubleSize = doubleSize
        var mainBitmap = MainWindowRenderer.render(skin, main)
        if let region = skin.regions.main {
            mainBitmap.apply(mask: SkinRegions.mask(region, width: mainBitmap.width, height: mainBitmap.height))
        }
        mainWindow.show(mainBitmap, scale: scale)

        var equalizer = ReferenceScene.equalizerState
        equalizer.focused = equalizerWindow.isKeyWindow
        var equalizerBitmap = EqualizerWindowRenderer.render(skin, equalizer)
        if let region = skin.regions.equalizer {
            equalizerBitmap.apply(mask: SkinRegions.mask(region, width: equalizerBitmap.width, height: equalizerBitmap.height))
        }
        equalizerWindow.show(equalizerBitmap, scale: scale)

        var playlist = ReferenceScene.playlistState
        playlist.focused = playlistWindow.isKeyWindow
        playlistWindow.show(PlaylistWindowRenderer.render(skin, playlist), scale: scale)
    }

    private var placedOnScreen = false

    /// Stacks the windows like Winamp's default layout, keeping the main window in place.
    private func layOutWindows() {
        if !placedOnScreen, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            mainWindow.setFrameTopLeftPoint(NSPoint(x: (visible.minX + 80).rounded(), y: (visible.maxY - 80).rounded()))
            placedOnScreen = true
        }
        equalizerWindow.setFrameTopLeftPoint(NSPoint(x: mainWindow.frame.minX, y: mainWindow.frame.minY))
        playlistWindow.setFrameTopLeftPoint(NSPoint(x: mainWindow.frame.minX, y: equalizerWindow.frame.minY))
    }

    // MARK: - Menu

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Hagtamp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Hagtamp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hagtamp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(submenu: appMenu, title: "Hagtamp")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Skin…", action: #selector(openSkin(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Use Base Skin", action: #selector(useBaseSkin(_:)), keyEquivalent: "")
        menu.addItem(submenu: fileMenu, title: "File")

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Double Size", action: #selector(toggleDoubleSize(_:)), keyEquivalent: "d")
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
}
