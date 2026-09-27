import Foundation

/// A version like "0.1.2": a leading "v" (as in tags) and a suffix after
/// "-" or "+" are ignored, and missing parts count as 0 ("1.0" is "1.0.0").
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        core = core.prefix { $0 != "-" && $0 != "+" }
        var components: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        guard !components.isEmpty else { return nil }
        // Trailing zeros don't count, so equal versions hash alike.
        while components.count > 1, components.last == 0 { components.removeLast() }
        self.components = components
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public var description: String {
        (components + Array(repeating: 0, count: max(0, 3 - components.count))).map(String.init).joined(separator: ".")
    }
}

/// A release as GitHub's API describes it.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public var name: String
        public var url: URL
        public var size: Int
        /// "sha256:<hex>", worked out by GitHub on upload.
        public var digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case url = "browser_download_url"
        }

        public init(name: String, url: URL, size: Int, digest: String? = nil) {
            self.name = name
            self.url = url
            self.size = size
            self.digest = digest
        }

        public var sha256: String? {
            guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
            return digest.dropFirst(7).lowercased()
        }
    }

    public var tag: String
    public var name: String?
    /// Markdown.
    public var notes: String?
    public var page: URL
    public var isDraft: Bool
    public var isPrerelease: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case name
        case notes = "body"
        case page = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }

    public var version: AppVersion? { AppVersion(tag) }

    /// The app's archive: "<app>-<version>.zip", else the only zip there is.
    public func archive(of app: String) -> Asset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let named = version.flatMap { version in zips.first { Self.version(in: $0.name, of: app) == version } }
        return named ?? (zips.count == 1 ? zips[0] : nil)
    }

    /// "Hagtamp-0.1.2.zip" → 0.1.2; nothing else may follow the version.
    private static func version(in fileName: String, of app: String) -> AppVersion? {
        let base = (fileName as NSString).deletingPathExtension
        guard base.hasPrefix(app + "-") else { return nil }
        let version = base.dropFirst(app.count + 1)
        return version.allSatisfy { $0.isNumber || $0 == "." } ? AppVersion(String(version)) : nil
    }

    /// What the notes say is new: their "What's new" section (all of them
    /// without one), pictures left out. Markdown.
    public var whatsNew: String {
        let lines = (notes ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let heading = lines.firstIndex { $0.hasPrefix("## ") && $0.lowercased().contains("new") }
        let section = heading.map { Array(lines[($0 + 1)...].prefix { !$0.hasPrefix("## ") }) } ?? lines
        return section.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The latest release of a GitHub repository.
public struct ReleaseFeed: Sendable {
    public let url: URL
    private let session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    /// "owner/name".
    public init(repository: String, session: URLSession = .shared) {
        self.init(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, session: session)
    }

    public func latest() async throws -> Release {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError(http.statusCode == 404 ? "There are no releases yet." : "GitHub answered with status \(http.statusCode).")
        }
        do {
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateError("GitHub's answer isn't a release.")
        }
    }
}

public struct UpdateError: LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
