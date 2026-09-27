import CryptoKit
import Foundation
import Testing

@testable import UpdateKit

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hagtamp-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@discardableResult
private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A small app bundle (Apple's `true` as its executable), signed ad hoc like our releases.
private func makeApp(in folder: URL, identifier: String = "app.hagtamp.Hagtamp", version: String) throws -> URL {
    let app = folder.appendingPathComponent("Hagtamp.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Hagtamp"))
    let info: [String: Any] = [
        "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Hagtamp",
        "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    #expect(try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
    return app
}

private func zip(_ app: URL, to archive: URL) throws {
    #expect(try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path]) == 0)
}

@Suite struct AppVersionTests {
    @Test func readsTagsAndBundleVersions() {
        #expect(AppVersion("v0.1.2")?.components == [0, 1, 2])
        #expect(AppVersion("0.1.2")?.description == "0.1.2")
        #expect(AppVersion("1.0")?.description == "1.0.0")
        #expect(AppVersion("2.0.1-beta.3")?.components == [2, 0, 1])
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func comparesNumbersNotText() {
        #expect(AppVersion("0.1.10")! > AppVersion("0.1.9")!)
        #expect(AppVersion("0.2")! > AppVersion("0.1.9")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(!(AppVersion("0.1.2")! < AppVersion("v0.1.2")!))
    }
}

@Suite struct ReleaseTests {
    private func fixture() throws -> Release {
        let url = try #require(Bundle.module.url(forResource: "latest", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Release.self, from: Data(contentsOf: url))
    }

    /// GitHub's answer for Hagtamp 0.1.2.
    @Test func readsGitHubsLatestRelease() throws {
        let release = try fixture()
        #expect(release.version == AppVersion("0.1.2"))
        #expect(!release.isDraft && !release.isPrerelease)
        #expect(release.page.absoluteString == "https://github.com/mmag/hagtamp/releases/tag/v0.1.2")
        let archive = try #require(release.archive(of: "Hagtamp"))
        #expect(archive.name == "Hagtamp-0.1.2.zip")
        #expect(archive.size == 8_390_935)
        #expect(archive.sha256 == "da7edc6b1844a3bec8addb32ad69617762dc99c84d6330e1e80c06cb8b11e6a8")
    }

    @Test func whatsNewIsItsOwnSection() throws {
        let notes = try fixture().whatsNew
        #expect(notes.hasPrefix("- **Loudness normalization**"))
        #expect(notes.contains("Loud modern recordings"))
        #expect(!notes.contains("<img"))
        #expect(!notes.contains("brew install"))
        // Notes without the section are shown whole, pictures aside.
        var plain = try fixture()
        plain.notes = "Fixes.\n<img src=\"x.png\">\n- One thing"
        #expect(plain.whatsNew == "Fixes.\n- One thing")
    }

    @Test func picksTheAppsArchive() throws {
        var release = try fixture()
        let url = URL(string: "https://example.com/a")!
        release.assets = [
            .init(name: "Hagtamp-0.1.2-dSYM.zip", url: url, size: 1), .init(name: "Hagtamp-0.1.2.zip", url: url, size: 2),
            .init(name: "notes.txt", url: url, size: 3),
        ]
        #expect(release.archive(of: "Hagtamp")?.size == 2)
        release.assets = [.init(name: "Hagtamp.zip", url: url, size: 4)]
        #expect(release.archive(of: "Hagtamp")?.size == 4)
        release.assets = []
        #expect(release.archive(of: "Hagtamp") == nil)
    }

    @Test func feedReadsAFile() async throws {
        let url = try #require(Bundle.module.url(forResource: "latest", withExtension: "json", subdirectory: "Fixtures"))
        #expect(try await ReleaseFeed(url: url).latest().tag == "v0.1.2")
        #expect(ReleaseFeed(repository: "mmag/hagtamp").url.absoluteString == "https://api.github.com/repos/mmag/hagtamp/releases/latest")
    }
}

@Suite struct UpdateInstallerTests {
    private func asset(for file: URL, size: Int? = nil, sha256: String? = nil) throws -> Release.Asset {
        let data = try Data(contentsOf: file)
        let digest = sha256 ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Release.Asset(name: "Hagtamp-9.9.9.zip", url: file, size: size ?? data.count, digest: "sha256:" + digest)
    }

    @Test func downloadsAndChecksTheArchive() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.zip")
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: source)
        let target = folder.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let file = try await UpdateInstaller.download(try asset(for: source), into: target)
        #expect(file.lastPathComponent == "Hagtamp-9.9.9.zip")
        #expect(try Data(contentsOf: file) == Data(contentsOf: source))

        await #expect(throws: UpdateError("The download is damaged: its checksum doesn't match.")) {
            _ = try await UpdateInstaller.download(try asset(for: source, sha256: String(repeating: "0", count: 64)), into: target)
        }
        await #expect(throws: UpdateError("The download is incomplete.")) {
            _ = try await UpdateInstaller.download(try asset(for: source, size: 12), into: target)
        }
    }

    @Test func unpacksAndChecksTheApp() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let built = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: built) }
        let archive = folder.appendingPathComponent("Hagtamp-0.2.0.zip")
        try zip(try makeApp(in: built, version: "0.2.0"), to: archive)

        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let app = try UpdateInstaller.unpack(archive, into: unpacked)
        #expect(app.lastPathComponent == "Hagtamp.app")
        try UpdateInstaller.validate(app, bundleIdentifier: "app.hagtamp.Hagtamp", version: AppVersion("0.2")!)

        #expect(throws: UpdateError("The download holds a different app.")) {
            try UpdateInstaller.validate(app, bundleIdentifier: "com.example.Other", version: AppVersion("0.2.0")!)
        }
        #expect(throws: UpdateError("The download is version 0.2.0, not 0.3.0.")) {
            try UpdateInstaller.validate(app, bundleIdentifier: "app.hagtamp.Hagtamp", version: AppVersion("0.3.0")!)
        }
        // Tampered with after signing.
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Hagtamp"))
        #expect(throws: UpdateError("The downloaded app is damaged: its code signature doesn't hold.")) {
            try UpdateInstaller.validate(app, bundleIdentifier: "app.hagtamp.Hagtamp", version: AppVersion("0.2.0")!)
        }
    }

    @Test func archivesWithoutTheAppAreRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        let archive = folder.appendingPathComponent("Hagtamp-0.2.0.zip")
        try zip(notes, to: archive)
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        #expect(throws: UpdateError("The download doesn't hold the app.")) { _ = try UpdateInstaller.unpack(archive, into: unpacked) }
        #expect(throws: UpdateError("The download couldn't be unpacked.")) { _ = try UpdateInstaller.unpack(notes, into: unpacked) }
    }

    @Test func swapsTheNewVersionIn() throws {
        let installed = try temporaryFolder()
        let incoming = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: installed)
            try? FileManager.default.removeItem(at: incoming)
        }
        let old = try makeApp(in: installed, version: "0.1.0")
        let new = try makeApp(in: incoming, version: "0.2.0")
        #expect(UpdateInstaller.obstacle(replacing: old) == nil)
        try UpdateInstaller.replace(old, with: new)
        let info = NSDictionary(contentsOf: old.appendingPathComponent("Contents/Info.plist"))
        #expect(info?["CFBundleShortVersionString"] as? String == "0.2.0")
        try UpdateInstaller.validate(old, bundleIdentifier: "app.hagtamp.Hagtamp", version: AppVersion("0.2.0")!)
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func translocatedCopiesCantBeReplaced() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Hagtamp.app")
        #expect(UpdateInstaller.obstacle(replacing: translocated)?.contains("Applications folder") == true)
        #expect(UpdateInstaller.obstacle(replacing: URL(fileURLWithPath: "/System/Applications/Music.app")) != nil)
    }
}
