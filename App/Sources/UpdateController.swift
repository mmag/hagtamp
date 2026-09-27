import AppKit
import SwiftUI
import UpdateKit

/// Updates from the GitHub releases: checked once a day (unless turned off
/// in Preferences) and on demand. A newer release is offered in a window of
/// its own, so the player keeps going: installed over this copy, which then
/// relaunches, or downloaded to the Downloads folder.
@MainActor
@Observable
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppVersion)
        case failed(String)
    }

    /// A release on offer, and how far taking it has got.
    struct Offer {
        enum Stage: Equatable {
            case choosing
            case downloading(Double)
            case installing
            case failed(String)
        }

        var release: Release
        var version: AppVersion
        var archive: Release.Asset?
        /// Why this copy can't be replaced in place, if it can't.
        var obstacle: String?
        var stage = Stage.choosing
    }

    private enum Keys {
        static let automatic = "updates.automatic"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
    }

    static let repository = "mmag/hagtamp"
    static let appName = "Hagtamp"
    /// This copy's version.
    static var version: AppVersion? { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) }

    var checksAutomatically: Bool {
        didSet { Storage.defaults.set(checksAutomatically, forKey: Keys.automatic) }
    }
    private(set) var lastCheck: Date?
    private(set) var status = Status.idle
    private(set) var offer: Offer?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?

    init() {
        checksAutomatically = Storage.defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastCheck = Storage.defaults.object(forKey: Keys.lastCheck) as? Date
    }

    private var feed: ReleaseFeed {
        #if DEBUG
        // Trying updates out: a release described in a local file.
        if let url = ProcessInfo.processInfo.environment["HAGTAMP_UPDATE_FEED"].flatMap(URL.init(string:)) { return ReleaseFeed(url: url) }
        #endif
        return ReleaseFeed(repository: Self.repository)
    }

    /// Automatic checks: shortly after launch, then whenever a day has passed.
    func start() {
        #if DEBUG
        // Development builds aren't offered releases, unless trying updates out.
        guard ProcessInfo.processInfo.environment["HAGTAMP_UPDATE_FEED"] != nil else { return }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        guard checksAutomatically, status != .checking, offer == nil else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 23 * 3600 { return }
        Task { await check(manual: false) }
    }

    /// From the menu or Preferences: always tells what it found.
    func checkNow() {
        guard status != .checking else { return }
        if offer != nil { return showWindow() }
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        status = .checking
        do {
            let release = try await feed.latest()
            lastCheck = Date()
            Storage.defaults.set(lastCheck, forKey: Keys.lastCheck)
            guard let latest = release.version, let current = Self.version, latest > current, !release.isDraft, !release.isPrerelease else {
                status = .upToDate
                if manual { tell("Hagtamp is up to date", "Version \(Self.version?.description ?? "?") is the latest.") }
                return
            }
            status = .available(latest)
            guard manual || Storage.defaults.string(forKey: Keys.skipped) != latest.description else { return }
            present(release, latest)
        } catch {
            status = .failed(error.localizedDescription)
            if manual { tell("Can't check for updates", error.localizedDescription) }
        }
    }

    private func tell(_ message: String, _ information: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - The offer

    private func present(_ release: Release, _ version: AppVersion) {
        let archive = release.archive(of: Self.appName)
        let obstacle = archive == nil ? "This release has no download for the app." : UpdateInstaller.obstacle(replacing: Bundle.main.bundleURL)
        offer = Offer(release: release, version: version, archive: archive, obstacle: obstacle)
        showWindow()
        #if DEBUG
        if ProcessInfo.processInfo.environment["HAGTAMP_UPDATE_INSTALL"] == "1" { install() }
        #endif
    }

    private func showWindow() {
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: UpdateView(updates: self))
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        self.window = window
        return window
    }

    /// Closing the window is "later"; a download under way stops.
    private func closed() {
        work?.cancel()
        work = nil
        offer = nil
    }

    func later() {
        window?.close()
    }

    func skipVersion() {
        if let offer { Storage.defaults.set(offer.version.description, forKey: Keys.skipped) }
        window?.close()
    }

    /// Stops a download; the offer stays.
    func cancel() {
        work?.cancel()
    }

    /// Downloads the release, swaps it in for this copy and relaunches.
    func install() {
        guard let archive = offer?.archive, offer?.obstacle == nil, let version = offer?.version else { return }
        let installed = Bundle.main.bundleURL
        let identifier = Bundle.main.bundleIdentifier ?? "app.hagtamp.Hagtamp"
        run { updates in
            // Next to the app, on its disk, so the swap is a rename.
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
            let file = try await updates.download(archive, into: folder)
            updates.offer?.stage = .installing
            let app = try await Task.detached {
                let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                let app = try UpdateInstaller.unpack(file, into: unpacked)
                try UpdateInstaller.validate(app, bundleIdentifier: identifier, version: version)
                do {
                    try UpdateInstaller.replace(installed, with: app)
                } catch {
                    throw UpdateError("Hagtamp couldn't replace itself (\(error.localizedDescription)). Download the update instead.")
                }
                try? FileManager.default.removeItem(at: folder)
                return installed
            }.value
            updates.relaunch(app)
        }
    }

    /// Downloads the release's archive into the Downloads folder and shows it.
    func download() {
        guard let archive = offer?.archive else {
            if let page = offer?.release.page { NSWorkspace.shared.open(page) }
            return
        }
        run { updates in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Hagtamp-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = try await updates.download(archive, into: folder)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let target = Self.unused(downloads.appendingPathComponent(file.lastPathComponent))
            try FileManager.default.moveItem(at: file, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
            updates.window?.close()
        }
    }

    /// One step at a time: a failure shows in the window, cancelling goes back to the choice.
    private func run(_ step: @escaping @MainActor (UpdateController) async throws -> Void) {
        guard offer != nil, work == nil else { return }
        offer?.stage = .downloading(0)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await step(self)
            } catch {
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError
                self.offer?.stage = cancelled ? .choosing : .failed(error.localizedDescription)
            }
            self.work = nil
        }
    }

    private func download(_ archive: Release.Asset, into folder: URL) async throws -> URL {
        try await UpdateInstaller.download(archive, into: folder) { [weak self] fraction in
            Task { @MainActor in
                if case .downloading = self?.offer?.stage { self?.offer?.stage = .downloading(fraction) }
            }
        }
    }

    /// "Hagtamp-0.1.3.zip", else "Hagtamp-0.1.3 2.zip" and so on.
    private static func unused(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Quits, and opens the new version once this process is gone.
    private func relaunch(_ app: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        helper.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            offer?.stage = .failed("The update is installed; open Hagtamp again to use it.")
        }
    }
}

/// The window offering a release: what's new, and what to do about it.
private struct UpdateView: View {
    let updates: UpdateController

    var body: some View {
        if let offer = updates.offer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hagtamp \(offer.version.description) is available").font(.headline)
                        Text("You have \(UpdateController.version?.description ?? "an older version").").foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    Text(Self.notes(offer.release.whatsNew))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                stage(offer)
            }
            .padding(20)
            .frame(width: 520)
        }
    }

    @ViewBuilder
    private func stage(_ offer: UpdateController.Offer) -> some View {
        switch offer.stage {
        case .choosing:
            if let obstacle = offer.obstacle { Text(obstacle).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Skip This Version") { updates.skipVersion() }
                Spacer()
                Button("Later") { updates.later() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { updates.download() }
                if offer.obstacle == nil {
                    Button("Install and Relaunch") { updates.install() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction) {
                    Text("Downloading… \(Self.megabytes(fraction * Double(offer.archive?.size ?? 0))) of \(Self.megabytes(Double(offer.archive?.size ?? 0)))")
                        .font(.callout)
                }
                Button("Cancel") { updates.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .installing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.callout)
            }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Later") { updates.later() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { updates.download() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private static func megabytes(_ bytes: Double) -> String {
        String(format: "%.1f MB", bytes / 1_000_000)
    }

    /// The release notes' markdown: bold and links; list items as bullets.
    static func notes(_ markdown: String) -> AttributedString {
        let text = markdown.components(separatedBy: "\n")
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? "•  " + $0.dropFirst(2) : $0 }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
