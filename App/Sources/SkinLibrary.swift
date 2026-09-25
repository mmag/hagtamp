import AppKit
import ClassicUI
import SkinKit
import UniformTypeIdentifiers

/// Installed skins, in Application Support/Hagtamp/Skins like Winamp's Skins
/// folder. A skin opened from elsewhere is copied in so it stays listed.
@MainActor
enum SkinLibrary {
    static let lastSkinKey = "lastSkinPath"

    static var folder: URL {
        let folder = Storage.supportDirectory.appendingPathComponent("Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Skin archives (.wsz, .zip) and unpacked skin folders, by name.
    static func installed() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter(WindowManager.isSkin).sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    static func name(of url: URL) -> String {
        url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// The skin in use (nil: the base skin).
    static var current: URL? {
        Storage.defaults.string(forKey: lastSkinKey).map { URL(fileURLWithPath: $0) }
    }

    /// Loads a skin file or folder; a folder without MAIN.BMP isn't taken for a skin.
    static func load(_ url: URL) throws -> Skin {
        guard WindowManager.isSkin(url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                NSLocalizedDescriptionKey: "This folder isn't a skin: a skin folder has a MAIN.BMP in it."
            ])
        }
        return try Skin.load(contentsOf: url)
    }

    /// Copies a skin into the Skins folder unless it is there already; returns where it is.
    static func install(_ url: URL) -> URL {
        let target = folder.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath)
        guard url.standardizedFileURL.deletingLastPathComponent() != folder.standardizedFileURL else { return url }
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.copyItem(at: url, to: target)
        }
        return FileManager.default.fileExists(atPath: target.path) ? target : url
    }

    static var openPanelTypes: [UTType] { [UTType(filenameExtension: "wsz") ?? .zip, .zip] }

    /// The main window drawn with a skin, as the skin browser shows it.
    nonisolated static func thumbnail(of url: URL) -> Data? {
        guard let skin = url == baseSkinURL ? Skin.base : try? Skin.load(contentsOf: url) else { return nil }
        var state = ReferenceScene.mainState
        state.marqueeText = "Hagtamp"
        var bitmap = MainWindowRenderer.render(skin, state)
        if let region = skin.regions.main {
            bitmap.apply(mask: SkinRegions.mask(region, width: bitmap.width, height: bitmap.height))
        }
        return bitmap.pngData()
    }

    /// Stands for the base skin in lists.
    nonisolated static let baseSkinURL = URL(fileURLWithPath: "/base-skin")
}

/// Winamp's skin browser (Alt+S): every installed skin as it looks; a click puts it on.
@MainActor
final class SkinBrowserController {
    private var window: NSWindow?
    private let model = SkinBrowserModel()

    func show() {
        model.reload()
        if window == nil {
            let hosting = NSHostingView(rootView: SkinBrowserView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 540), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.contentView = hosting
            window.title = "Skins"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

import SwiftUI

@MainActor
@Observable
final class SkinBrowserModel {
    struct Item: Identifiable {
        let id: URL
        let name: String
        var thumbnail: NSImage?
    }

    var items: [Item] = []
    var current: URL?

    func reload() {
        let urls = [SkinLibrary.baseSkinURL] + SkinLibrary.installed()
        let old = Dictionary(items.map { ($0.id, $0.thumbnail) }) { a, _ in a }
        items = urls.map { Item(id: $0, name: $0 == SkinLibrary.baseSkinURL ? "Base Skin" : SkinLibrary.name(of: $0), thumbnail: old[$0] ?? nil) }
        current = SkinLibrary.current ?? SkinLibrary.baseSkinURL
        for url in urls where old[url] == nil {
            Task.detached(priority: .utility) {
                let data = SkinLibrary.thumbnail(of: url)
                await MainActor.run { [weak self] in
                    guard let self, let index = self.items.firstIndex(where: { $0.id == url }) else { return }
                    self.items[index].thumbnail = data.flatMap(NSImage.init(data:))
                }
            }
        }
    }

    func choose(_ item: Item) {
        let app = NSApp.delegate as? AppDelegate
        if item.id == SkinLibrary.baseSkinURL {
            app?.useBaseSkin(nil)
        } else {
            app?.loadSkin(from: item.id)
        }
        current = SkinLibrary.current ?? SkinLibrary.baseSkinURL
    }

    func addSkins() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SkinLibrary.openPanelTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose skins (.wsz) to add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where (try? SkinLibrary.load(url)) != nil { _ = SkinLibrary.install(url) }
        reload()
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([SkinLibrary.folder])
    }
}

struct SkinBrowserView: View {
    @Bindable var model: SkinBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 12)], spacing: 14) {
                    ForEach(model.items) { item in
                        VStack(spacing: 4) {
                            Group {
                                if let thumbnail = item.thumbnail {
                                    Image(nsImage: thumbnail).interpolation(.none)
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(width: 275, height: 116)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.current == item.id ? Color.accentColor : .clear, lineWidth: 3))
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                                .fontWeight(model.current == item.id ? .semibold : .regular)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.choose(item) }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Add Skins…") { model.addSkins() }
                Button("Show Skins Folder") { model.revealFolder() }
                Spacer()
                Text("\(model.items.count - 1) installed").foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(minWidth: 320, minHeight: 300)
    }
}
