import Foundation

/// One line of the playlist. The identity survives reordering, so the
/// current track and the selection stay put when the list is sorted or edited.
public struct PlaylistEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var info: TrackInfo
    /// Tags have been read (successfully or not).
    public var infoLoaded: Bool

    public init(_ info: TrackInfo, infoLoaded: Bool = false) {
        id = UUID()
        self.info = info
        self.infoLoaded = infoLoaded
    }

    public var url: URL { info.url }
}

/// Winamp's playlist editor model: order, selection, current track.
///
/// Selection follows Winamp 2: a click selects one entry and sets the
/// anchor, Ctrl-click toggles and moves the anchor, Shift-click selects the
/// range from the anchor.
public struct Playlist: Sendable {
    public private(set) var entries: [PlaylistEntry] = []
    public private(set) var selection: Set<UUID> = []
    /// Anchor for Shift ranges, also the keyboard focus.
    public private(set) var anchor: Int?
    public private(set) var currentID: UUID?

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public subscript(index: Int) -> PlaylistEntry { entries[index] }

    public var currentIndex: Int? {
        currentID.flatMap { id in entries.firstIndex { $0.id == id } }
    }

    public mutating func setCurrent(_ index: Int?) {
        currentID = index.flatMap { entries.indices.contains($0) ? entries[$0].id : nil }
    }

    // MARK: - Selection

    public func isSelected(_ index: Int) -> Bool {
        entries.indices.contains(index) && selection.contains(entries[index].id)
    }

    public var selectedIndices: [Int] {
        entries.indices.filter { selection.contains(entries[$0].id) }
    }

    public mutating func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = [entries[index].id]
        anchor = index
    }

    public mutating func toggleSelection(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let id = entries[index].id
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        anchor = index  // Winamp moves the anchor even when deselecting
    }

    /// Selects from the anchor to `index` (just `index` without an anchor).
    public mutating func extendSelection(to index: Int) {
        guard entries.indices.contains(index) else { return }
        guard let anchor, entries.indices.contains(anchor) else {
            select(index)
            return
        }
        selection = Set(entries[min(anchor, index)...max(anchor, index)].map(\.id))
    }

    /// Keyboard focus without changing the anchor semantics of clicks.
    public mutating func setAnchor(_ index: Int?) {
        anchor = index.map { min(max(0, $0), entries.count - 1) }
    }

    public mutating func selectAll() { selection = Set(entries.map(\.id)) }
    public mutating func selectNone() { selection = [] }
    public mutating func invertSelection() { selection = Set(entries.map(\.id)).subtracting(selection) }

    // MARK: - Editing

    /// Inserts tracks at `index` (the end when nil); returns where they landed.
    /// `infoLoaded`: the tags are complete, nothing to read from the files.
    @discardableResult
    public mutating func insert(_ tracks: [TrackInfo], at index: Int? = nil, infoLoaded: Bool = false) -> Range<Int> {
        let at = min(max(0, index ?? entries.count), entries.count)
        entries.insert(contentsOf: tracks.map { PlaylistEntry($0, infoLoaded: infoLoaded) }, at: at)
        anchor = nil
        return at..<at + tracks.count
    }

    public mutating func removeAll() {
        entries = []
        selection = []
        anchor = nil
        currentID = nil
    }

    public mutating func removeSelected() {
        let selected = selection
        remove { selected.contains($0.id) }
    }

    /// Keeps only the selection.
    public mutating func crop() {
        let selected = selection
        remove { !selected.contains($0.id) }
    }

    /// Removes later entries pointing at a file that is already in the list.
    public mutating func removeDuplicates() {
        var seen: Set<URL> = []
        remove { !seen.insert($0.url.standardizedFileURL).inserted }
    }

    /// Removes local files that no longer exist.
    public mutating func removeDeadFiles(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        remove { $0.url.isFileURL && !exists($0.url) }
    }

    public mutating func remove(where shouldRemove: (PlaylistEntry) -> Bool) {
        entries.removeAll(where: shouldRemove)
        let ids = Set(entries.map(\.id))
        selection.formIntersection(ids)
        if let currentID, !ids.contains(currentID) { self.currentID = nil }
        anchor = nil
    }

    /// Moves the selected entries by `offset` rows, clamped so none leaves
    /// the list; returns the offset applied.
    @discardableResult
    public mutating func moveSelection(by offset: Int) -> Int {
        let selected = selectedIndices
        guard let first = selected.first, let last = selected.last else { return 0 }
        let applied = min(max(offset, -first), entries.count - 1 - last)
        guard applied != 0 else { return 0 }
        var result = [PlaylistEntry?](repeating: nil, count: entries.count)
        for i in selected { result[i + applied] = entries[i] }
        var rest = entries.indices.filter { !selection.contains(entries[$0].id) }.map { entries[$0] }.makeIterator()
        for i in result.indices where result[i] == nil { result[i] = rest.next() }
        entries = result.compactMap { $0 }
        anchor = anchor.map { $0 + applied }
        return applied
    }

    public enum SortKey: Sendable {
        /// The displayed title ("Artist - Title").
        case title
        case fileName
        case path
    }

    public mutating func sort(by key: SortKey) {
        func sortKey(_ entry: PlaylistEntry) -> String {
            switch key {
            case .title: entry.info.displayName
            case .fileName: entry.url.lastPathComponent
            case .path: entry.url.isFileURL ? entry.url.path : entry.url.absoluteString
            }
        }
        // Stable, case-insensitive, numbers in natural order.
        entries = entries.enumerated().sorted { a, b in
            let order = sortKey(a.element).localizedStandardCompare(sortKey(b.element))
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
        anchor = nil
    }

    public mutating func reverse() {
        entries.reverse()
        anchor = nil
    }

    public mutating func randomize() {
        entries.shuffle()
        anchor = nil
    }

    // MARK: - Tags

    /// Fills in tags read in the background for every entry of that file.
    public mutating func update(_ info: TrackInfo) {
        for i in entries.indices where entries[i].url == info.url && !entries[i].infoLoaded {
            entries[i].info = info
            entries[i].infoLoaded = true
        }
    }

    // MARK: - Running time

    /// Seconds of the selection and of the whole list; `incomplete` when some
    /// lengths are unknown (Winamp then shows a "+").
    public var runningTime: (selected: Int, total: Int, incomplete: Bool) {
        var selected = 0, total = 0, incomplete = false
        for entry in entries {
            guard let duration = entry.info.duration else {
                incomplete = true
                continue
            }
            total += Int(duration)
            if selection.contains(entry.id) { selected += Int(duration) }
        }
        return (selected, total, incomplete)
    }
}
