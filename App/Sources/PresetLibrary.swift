import AppKit
import LibraryKit
import Milkdrop
import SwiftUI

/// Presets (.milk): the ones that come with the app, then the user's in
/// Application Support/Hagtamp/Presets (subfolders too), by name. The list is
/// made in the background, so thousands of presets don't hold up the app,
/// and follows the folder as files come and go. Presets found too heavy to
/// draw in time are remembered and left out of the automatic choice.
@MainActor
final class PresetLibrary {
    static var userFolder: URL {
        let folder = Storage.supportDirectory.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var bundledFolder: URL? { Bundle.main.url(forResource: "Presets", withExtension: nil) }
    private static let heavyKey = "visualization.heavyPresets"

    private(set) var presets: [URL] = []
    /// The list has been read at least once.
    private(set) var isLoaded = false
    /// File names of presets that couldn't keep up with the display.
    private(set) var heavy = Set(Storage.defaults.stringArray(forKey: heavyKey) ?? [])
    /// Called when the list or the heavy marks change.
    var onChange: (() -> Void)?
    private var generation = 0
    private var watcher: FolderWatcher?

    init() {
        reload()
        watcher = FolderWatcher([Self.userFolder], latency: 1, extensions: ["milk"]) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        generation += 1
        let generation = generation
        let folders = [Self.bundledFolder, Self.userFolder].compactMap { $0 }
        Task.detached(priority: .userInitiated) {
            let list = Self.list(in: folders)
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.presets = list
                self.isLoaded = true
                self.onChange?()
            }
        }
    }

    /// The .milk files under `folders`, sorted by name (each name worked out
    /// once: sorting 50,000 of them otherwise takes seconds).
    nonisolated static func list(in folders: [URL]) -> [URL] {
        folders.flatMap { folder in
            (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension.lowercased() == "milk" }
        }
        .map { (url: $0, name: name($0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map(\.url)
    }

    nonisolated static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Where a preset lives, for the browser: "Hagtamp" for the bundled ones,
    /// the subfolder of the user's folder, or nothing at its top.
    static func folderLabel(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if let bundled = bundledFolder?.standardizedFileURL.path, parent.hasPrefix(bundled) { return "Hagtamp" }
        let user = userFolder.standardizedFileURL.path
        return parent.hasPrefix(user) ? String(parent.dropFirst(user.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
    }

    func load(_ url: URL) -> MilkdropPreset? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return MilkdropPreset.parse(text, name: Self.name(url))
    }

    // MARK: - Heavy presets

    func isHeavy(_ url: URL) -> Bool { heavy.contains(url.lastPathComponent) }

    func markHeavy(_ url: URL) {
        guard heavy.insert(url.lastPathComponent).inserted else { return }
        Storage.defaults.set(heavy.sorted(), forKey: Self.heavyKey)
        onChange?()
    }

    func forgetHeavy() {
        heavy = []
        Storage.defaults.removeObject(forKey: Self.heavyKey)
        onChange?()
    }

    /// What the automatic choice may take: all but the heavy presets (all of them if that is all there is).
    var candidates: [URL] {
        let light = presets.filter { !isHeavy($0) }
        return light.isEmpty ? presets : light
    }
}

// MARK: - Browser

/// A window listing every preset, with a search field: a double-click or
/// Return shows one. Presets found too slow carry a mark.
@MainActor
final class PresetBrowserController {
    private var window: NSWindow?
    let model: PresetBrowserModel

    init(library: PresetLibrary, choose: @escaping @MainActor (URL) -> Void) {
        model = PresetBrowserModel(library: library, choose: choose)
    }

    var isShown: Bool { window?.isVisible == true }

    func show(current: URL?) {
        model.reload()
        model.current = current
        model.selection = current
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: PresetBrowserView(model: model))
            window.title = "Presets"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() { window?.close() }
}

@MainActor
@Observable
final class PresetBrowserModel {
    struct Item: Identifiable, Hashable {
        let id: URL
        let name: String
        let folder: String
        let heavy: Bool
        /// Name and folder without case or accents, made once: searching
        /// 50,000 presets stays quick enough to follow typing.
        let searchKey: String
    }

    private let library: PresetLibrary
    private let chooseAction: @MainActor (URL) -> Void
    private(set) var items: [Item] = [] {
        didSet { refilter() }
    }
    var query = "" {
        didSet { refilter() }
    }
    private(set) var filtered: [Item] = []
    var current: URL?
    var selection: URL?

    init(library: PresetLibrary, choose: @escaping @MainActor (URL) -> Void) {
        self.library = library
        self.chooseAction = choose
    }

    func reload() {
        items = library.presets.map { url in
            let name = PresetLibrary.name(url), folder = PresetLibrary.folderLabel(url)
            return Item(id: url, name: name, folder: folder, heavy: library.isHeavy(url), searchKey: Self.fold(name + " " + folder))
        }
    }

    private func refilter() {
        let query = Self.fold(query.trimmingCharacters(in: .whitespaces))
        filtered = query.isEmpty ? items : items.filter { $0.searchKey.contains(query) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    var hasHeavy: Bool { !library.heavy.isEmpty }

    func choose(_ url: URL) {
        current = url
        chooseAction(url)
    }

    func forgetHeavy() { library.forgetHeavy() }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([PresetLibrary.userFolder])
    }
}

struct PresetBrowserView: View {
    @Bindable var model: PresetBrowserModel

    var body: some View {
        let filtered = model.filtered
        VStack(spacing: 0) {
            TextField("Search presets", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            ScrollViewReader { proxy in
                List(filtered, selection: $model.selection) { item in
                    HStack(spacing: 8) {
                        Text(item.name)
                            .fontWeight(item.id == model.current ? .semibold : .regular)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if item.heavy {
                            Text("slow").font(.caption).foregroundStyle(.orange)
                        }
                        if !item.folder.isEmpty {
                            Text(item.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(item.id)
                }
                // Double-click or Return shows the preset.
                .contextMenu(forSelectionType: URL.self) { _ in
                } primaryAction: { urls in
                    if let url = urls.first { model.choose(url) }
                }
                .onAppear { if let current = model.current { proxy.scrollTo(current, anchor: .center) } }
            }
            Divider()
            HStack {
                Button("Show Presets Folder") { model.revealFolder() }
                Button("Forget Slow Marks") { model.forgetHeavy() }
                    .disabled(!model.hasHeavy)
                Spacer()
                Text(filtered.count == model.items.count ? "\(model.items.count) presets" : "\(filtered.count) of \(model.items.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
