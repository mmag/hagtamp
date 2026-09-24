import Foundation

/// The words of a song: synced (each line with the second it starts at, from
/// LRC files or the server) or plain text.
public struct Lyrics: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// Seconds into the track; nil in plain lyrics.
        public var start: Double?
        public var text: String

        public init(start: Double? = nil, text: String) {
            self.start = start
            self.text = text
        }
    }

    public var lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    public var isSynced: Bool { lines.contains { $0.start != nil } }

    /// The line being sung `time` seconds in: the last one that has started.
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        return lines.lastIndex { ($0.start ?? .infinity) <= time }
    }

    /// LRC ("[01:02.50]words", several stamps per line, an [offset:ms] tag)
    /// or plain text when nothing carries a time stamp.
    public static func parse(_ text: String) -> Lyrics? {
        var synced: [Line] = []
        var plain: [Line] = []
        var offset = 0.0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = timestamp(tag) {
                    stamps.append(seconds)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                } else if stamps.isEmpty, tag.contains(":") {
                    rest = ""  // [ar:...], [ti:...] and other ID tags
                    break
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            if stamps.isEmpty {
                if !(raw.hasPrefix("[") && words.isEmpty) { plain.append(Line(text: words)) }
            } else {
                synced += stamps.map { Line(start: $0, text: words) }
            }
        }
        if !synced.isEmpty {
            // A positive offset brings the words earlier.
            let lines = synced.map { Line(start: max(0, ($0.start ?? 0) - offset), text: $0.text) }
            return Lyrics(lines: lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) })
        }
        while plain.first?.text.isEmpty == true { plain.removeFirst() }
        while plain.last?.text.isEmpty == true { plain.removeLast() }
        return plain.isEmpty ? nil : Lyrics(lines: plain)
    }

    /// "mm:ss", "mm:ss.xx", "mm:ss.xxx" or "mm:ss:xx".
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsText = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(secondsText), seconds >= 0, seconds < 60, secondsText.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + seconds
    }
}
