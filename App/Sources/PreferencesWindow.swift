import AppKit
import SwiftUI

/// The Preferences window (⌘,): playback, local library folders, Navidrome server, streaming and cache.
@MainActor
final class PreferencesWindowController {
    private let player: PlayerModel
    private let navidrome: NavidromeService
    private let library: LocalLibraryService
    private var window: NSWindow?

    init(player: PlayerModel, navidrome: NavidromeService, library: LocalLibraryService) {
        self.player = player
        self.navidrome = navidrome
        self.library = library
    }

    func show() {
        if window == nil {
            // A grouped Form scrolls and has no height of its own, so the window gets an explicit size.
            let model = PreferencesModel(player: player, navidrome: navidrome, library: library)
            let hosting = NSHostingView(rootView: PreferencesView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: PreferencesView.size.width, height: PreferencesView.size.height),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = hosting
            window.title = "Preferences"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
@Observable
final class PreferencesModel {
    let player: PlayerModel
    var resumesPosition: Bool { didSet { player.resumesPosition = resumesPosition } }
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

    /// "Kept offline: 2 albums, 1 playlist" (right-click one in the Navidrome window).
    var offlineSummary: String {
        let pins = navidrome.offlinePins
        let albums = pins.filter { $0.kind == .album }.count, playlists = pins.count - albums
        guard !pins.isEmpty else { return "To keep an album or playlist offline, right-click it in the Navidrome window." }
        let parts = [(albums, "album"), (playlists, "playlist")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return "Kept offline: " + parts.joined(separator: ", ") + ", \(offlineUsageMB) MB, apart from the cache."
    }

    private func report(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

struct PreferencesView: View {
    static let size = CGSize(width: 460, height: 730)

    @Bindable var model: PreferencesModel

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Continue the track where it was when Hagtamp quit", isOn: $model.resumesPosition)
            }
            Section("Local library") {
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
            }
            Section("Navidrome server") {
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
                Text("Tracks start playing while they download and stay in the cache. Lower quality downloads faster.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cache") {
                Stepper(value: $model.cacheLimitMB, in: 200...100_000, step: 500) {
                    Text("Limit: \(model.cacheLimitMB) MB")
                }
                HStack {
                    Text("Used: \(model.cacheUsageMB) MB")
                    Spacer()
                    Button("Clear Cache") { model.clearCache() }
                }
                Text(model.offlineSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { model.refreshUsage() }
    }
}
