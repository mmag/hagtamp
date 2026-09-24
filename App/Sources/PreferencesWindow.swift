import AppKit
import SwiftUI

/// The Preferences window (⌘,): Navidrome server, streaming and cache.
@MainActor
final class PreferencesWindowController {
    private let navidrome: NavidromeService
    private var window: NSWindow?

    init(navidrome: NavidromeService) {
        self.navidrome = navidrome
    }

    func show() {
        if window == nil {
            // A grouped Form scrolls and has no height of its own, so the window gets an explicit size.
            let hosting = NSHostingView(rootView: PreferencesView(model: PreferencesModel(navidrome: navidrome)))
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
    let navidrome: NavidromeService
    var url: String
    var username: String
    var password: String
    var quality: StreamQuality { didSet { navidrome.quality = quality } }
    var cacheLimitMB: Int { didSet { navidrome.cacheLimitMB = cacheLimitMB } }
    var status = ""
    var statusIsError = false
    var busy = false
    var cacheUsageMB = 0

    init(navidrome: NavidromeService) {
        self.navidrome = navidrome
        url = navidrome.server?.url.absoluteString ?? ""
        username = navidrome.server?.username ?? ""
        password = navidrome.password ?? ""
        quality = navidrome.quality
        cacheLimitMB = navidrome.cacheLimitMB
        status = navidrome.isConfigured ? "Saved" : "Not set up"
        refreshUsage()
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
        busy = true
        report("Connecting…", error: false)
        let user = username.trimmingCharacters(in: .whitespaces), password = password
        Task {
            defer { busy = false }
            do {
                try await NavidromeService.test(url: serverURL, username: user, password: password)
                navidrome.configure(url: serverURL, username: user, password: password)
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
        Task { cacheUsageMB = Int(await navidrome.audioCache.usage() / 1_000_000) }
    }

    private func report(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }
}

struct PreferencesView: View {
    static let size = CGSize(width: 460, height: 520)

    @Bindable var model: PreferencesModel

    var body: some View {
        Form {
            Section("Navidrome server") {
                TextField("Address", text: $model.url, prompt: Text(verbatim: "music.example.com"))
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password)
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
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { model.refreshUsage() }
    }
}
