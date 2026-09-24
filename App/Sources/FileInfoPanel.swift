import AppKit
import ClassicUI
import PlayerCore

/// Winamp's file info dialog, read-only for now.
@MainActor
enum FileInfoPanel {
    static func show(_ info: TrackInfo) {
        let alert = NSAlert()
        alert.messageText = info.displayName
        var lines: [String] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(label): \(value)") }
        }
        add("Title", info.title)
        add("Artist", info.artist)
        add("Album", info.album)
        add("Length", info.duration.map { Marquee.timeString(Int($0)) })
        add("Bitrate", info.bitrate.map { "\($0) kbps" })
        add("Sample rate", info.sampleRate.map { "\(Int($0)) Hz" })
        add("Channels", info.channels.map { $0 == 1 ? "Mono" : $0 == 2 ? "Stereo" : "\($0)" })
        add("Location", info.url.isFileURL ? info.url.path : info.url.absoluteString)
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Close")
        if info.url.isFileURL { alert.addButton(withTitle: "Show in Finder") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([info.url])
        }
    }
}
