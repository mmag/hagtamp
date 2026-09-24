import AppKit
import SwiftUI

/// The Preferences window (⌘,): a tab per area, like macOS settings
/// windows; it reopens on the tab last shown.
@MainActor
final class PreferencesWindowController {
    enum Tab: Int, CaseIterable {
        case general, library, navidrome, cache

        var title: String {
            switch self {
            case .general: "General"
            case .library: "Library"
            case .navidrome: "Navidrome"
            case .cache: "Cache"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .library: "music.note.list"
            case .navidrome: "server.rack"
            case .cache: "internaldrive"
            }
        }
    }

    static let identifier = NSUserInterfaceItemIdentifier("preferences")
    private let player: PlayerModel
    private let navidrome: NavidromeService
    private let library: LocalLibraryService
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(player: PlayerModel, navidrome: NavidromeService, library: LocalLibraryService) {
        self.player = player
        self.navidrome = navidrome
        self.library = library
    }

    /// Opens the window, on `tab` if given.
    func show(_ tab: Tab? = nil) {
        let window = self.window ?? makeWindow()
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let model = PreferencesModel(player: player, navidrome: navidrome, library: library)
        let tabs = PreferencesTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item(.general, GeneralPreferences(model: model)))
        tabs.addTabViewItem(item(.library, LibraryPreferences(model: model)))
        tabs.addTabViewItem(item(.navidrome, NavidromePreferences(model: model)))
        tabs.addTabViewItem(item(.cache, CachePreferences(model: model)))
        tabs.selectedTabViewItemIndex = Tab(rawValue: Storage.defaults.integer(forKey: PreferencesTabs.key))?.rawValue ?? 0
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.identifier = Self.identifier
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        self.tabs = tabs
        return window
    }

    private func item<Pane: View>(_ tab: Tab, _ pane: Pane) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: pane)
        hosting.sizingOptions = .preferredContentSize  // the window takes each tab's size
        hosting.title = tab.title
        let item = NSTabViewItem(viewController: hosting)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        return item
    }
}

/// Remembers the tab shown.
private final class PreferencesTabs: NSTabViewController {
    static let key = "preferencesTab"

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        Storage.defaults.set(selectedTabViewItemIndex, forKey: Self.key)
    }
}

@MainActor
@Observable
final class PreferencesModel {
    let player: PlayerModel
    var resumesPosition: Bool { didSet { player.resumesPosition = resumesPosition } }
    /// Percent; applied to the windows at once.
    var textPercent: Int {
        didSet { (NSApp.delegate as? AppDelegate)?.setTextScale(Double(textPercent) / 100) }
    }
    let navidrome: NavidromeService
    let library: LocalLibraryService
    private(set) var libraryFolders: [URL] = []
    private(set) var libraryStatus = ""
    var url: String
    var username: String
    var password: String
    /// A token is saved for the configured server; the password itself is not kept.
    var passwordSaved = false
    var quality: StreamQuality { didSet { navidrome.quality = quality } }
    var cacheLimitMB: Int { didSet { navidrome.cacheLimitMB = cacheLimitMB } }
    var status = ""
    var statusIsError = false
    var busy = false
    var cacheUsageMB = 0
    var offlineUsageMB = 0

    init(player: PlayerModel, navidrome: NavidromeService, library: LocalLibraryService) {
        self.player = player
        resumesPosition = player.resumesPosition
        textPercent = Int(((NSApp.delegate as? AppDelegate)?.textScale ?? 1.5) * 100)
        self.navidrome = navidrome
        self.library = library
        url = navidrome.server?.url.absoluteString ?? ""
        username = navidrome.server?.username ?? ""
        password = ""
        passwordSaved = navidrome.isConfigured
        quality = navidrome.quality
        cacheLimitMB = navidrome.cacheLimitMB
        status = navidrome.isConfigured ? "Saved" : "Not set up"
        refreshUsage()
        refreshLibrary()
        library.onStatusChange = { [weak self] in self?.refreshLibrary() }
    }

    func refreshLibrary() {
        libraryFolders = library.folders
        libraryStatus = library.statusText
    }

    private var serverURL: URL? {
        var text = url.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        return URL(string: text).flatMap { $0.host == nil ? nil : $0 }
    }

    /// Checks the credentials, and saves them when they work.
    func connect() {
        guard let serverURL else {
            report("Enter the server address, e.g. https://music.example.com", error: true)
            return
        }
        let user = username.trimmingCharacters(in: .whitespaces), password = password
        // An empty field keeps the saved login (for this server and user).
        let credentials = password.isEmpty ? navidrome.savedCredentials(url: serverURL, username: user) : .token(for: password)
        guard let credentials else {
            report("Enter the password", error: true)
            return
        }
        busy = true
        report("Connecting…", error: false)
        Task {
            defer { busy = false }
            do {
                try await NavidromeService.test(url: serverURL, username: user, credentials: credentials)
                navidrome.configure(url: serverURL, username: user, credentials: credentials)
                self.password = ""
                passwordSaved = true
                report("Connected and saved", error: false)
            } catch {
                report(error.localizedDescription, error: true)
            }
        }
    }

    func clearCache() {
        Task {
            await navidrome.audioCache.clear()
            refreshUsage()
        }
    }

    func refreshUsage() {
        Task {
            cacheUsageMB = Int(await navidrome.audioCache.usage() / 1_000_000)
            offlineUsageMB = Int(await navidrome.audioCache.offlineUsage() / 1_000_000)
        }
    }

    /// "2 albums, 1 playlist: 120 MB…" (right-click one in the Navidrome window to keep it).
    var offlineSummary: String {
        let pins = navidrome.offlinePins
        let albums = pins.filter { $0.kind == .album }.count, playlists = pins.count - albums
        guard !pins.isEmpty else { return "To keep an album or playlist offline, right-click it in the Navidrome window." }
        let parts = [(albums, "album"), (playlists, "playlist")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.joined(separator: ", ") + ": \(offlineUsageMB) MB, not counted in the cache limit."
    }

    func showInFinder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func report(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

/// One tab: a grouped form as tall as its content.
private struct PreferencesPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

private struct GeneralPreferences: View {
    @Bindable var model: PreferencesModel

    var body: some View {
        PreferencesPane {
            Section("Playback") {
                Toggle("Continue the track where it was when Hagtamp quit", isOn: $model.resumesPosition)
            }
            Section("Appearance") {
                Picker("Text size", selection: $model.textPercent) {
                    ForEach([100, 125, 150, 175, 200], id: \.self) { percent in
                        Text(percent == 100 ? "100% (classic)" : "\(percent)%").tag(percent)
                    }
                }
                Caption("The playlist, library lists and lyrics.")
            }
        }
    }
}

private struct LibraryPreferences: View {
    @Bindable var model: PreferencesModel

    var body: some View {
        PreferencesPane {
            Section("Music folders") {
                if model.libraryFolders.isEmpty {
                    Text("Add the folders that hold your music.").foregroundStyle(.secondary)
                }
                ForEach(model.libraryFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { model.library.removeFolder(folder) }
                    }
                }
                HStack {
                    Button("Add Folder…") { model.library.addFolders() }
                    Button("Rescan") { model.library.rescan() }
                        .disabled(model.libraryFolders.isEmpty)
                    Spacer()
                    Text(model.libraryStatus).foregroundStyle(.secondary)
                }
                Caption("New and changed files in these folders are picked up on their own.")
            }
        }
    }
}

private struct NavidromePreferences: View {
    @Bindable var model: PreferencesModel

    var body: some View {
        PreferencesPane {
            Section("Server") {
                TextField("Address", text: $model.url, prompt: Text(verbatim: "music.example.com"))
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password, prompt: Text(model.passwordSaved ? "Saved" : ""))
                HStack {
                    Button("Connect") { model.connect() }
                        .disabled(model.busy)
                        .keyboardShortcut(.defaultAction)
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status)
                        .foregroundStyle(model.statusIsError ? .red : .secondary)
                        .lineLimit(2)
                }
            }
            Section("Streaming") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Caption("Tracks start playing while they download and stay in the cache. Lower quality downloads faster.")
            }
        }
    }
}

private struct CachePreferences: View {
    @Bindable var model: PreferencesModel

    var body: some View {
        PreferencesPane {
            Section("Cache") {
                Stepper(value: $model.cacheLimitMB, in: 200...100_000, step: 500) {
                    Text("Limit: \(model.cacheLimitMB) MB")
                }
                HStack {
                    Text("Used: \(model.cacheUsageMB) MB")
                    Spacer()
                    Button("Show in Finder") { model.showInFinder(model.navidrome.audioCache.directory) }
                    Button("Clear Cache") { model.clearCache() }
                }
                Caption("Navidrome tracks played or fetched ahead; the oldest go first when the cache is full.")
            }
            Section("Kept offline") {
                HStack {
                    Text(model.offlineSummary).foregroundStyle(.secondary)
                    Spacer()
                    if let folder = model.navidrome.audioCache.offlineDirectory, !model.navidrome.offlinePins.isEmpty {
                        Button("Show in Finder") { model.showInFinder(folder) }
                    }
                }
            }
        }
        .onAppear { model.refreshUsage() }
    }
}
