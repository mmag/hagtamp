import Foundation

/// Favourites of the local library. Artists and albums go by their catalog
/// ids, made from tags, so they survive moved folders; tracks go by path.
/// Those missing from the catalog stay: a disconnected drive comes back.
public struct LibraryFavourites: Codable, Sendable, Equatable {
    public var artists: Set<String> = []
    public var albums: Set<String> = []
    /// File paths.
    public var tracks: Set<String> = []

    public init() {}
}

extension LibraryCatalog {
    /// The favourites the catalog has, in its order.
    public func favourites(_ favourites: LibraryFavourites) -> (artists: [Artist], albums: [Album], tracks: [LibraryEntry]) {
        let tracks = favourites.tracks.isEmpty ? [] : albums.flatMap { tracks(ofAlbum: $0.id) }.filter { favourites.tracks.contains($0.url.path) }
        return (artists.filter { favourites.artists.contains($0.id) }, albums.filter { favourites.albums.contains($0.id) }, tracks)
    }
}
