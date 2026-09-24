import AppKit
import PlayerCore

/// Winamp's "Jump to file" window: type to filter the playlist, Enter plays.
@MainActor
final class JumpToFilePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: PlayerModel
    private lazy var panel = makePanel()
    private let search = NSSearchField()
    private let table = NSTableView()
    /// Playlist indices matching the search.
    private var matches: [Int] = []

    init(model: PlayerModel) {
        self.model = model
        super.init()
    }

    func show() {
        search.stringValue = ""
        refilter()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Jump to file"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        search.delegate = self
        search.placeholderString = "Search playlist"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(refilter)

        let column = NSTableColumn(identifier: .init("title"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(jump)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let play = NSButton(title: "Jump to file", target: self, action: #selector(jump))
        play.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: panel, action: #selector(NSWindow.performClose(_:)))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), close, play])
        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [search, scroll, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        panel.contentView = stack
        return panel
    }

    /// Every word of the query must appear in "N. Artist - Title".
    @objc private func refilter() {
        let words = search.stringValue.lowercased().split(separator: " ")
        matches = model.playlist.entries.indices.filter { index in
            let text = title(index).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func title(_ index: Int) -> String {
        "\(index + 1). \(model.playlist[index].info.displayName)"
    }

    @objc private func jump() {
        let row = table.selectedRow
        guard matches.indices.contains(row) else { return }
        model.play(trackAt: matches[row])
        panel.close()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: title(matches[row]))
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    /// Arrow keys in the search field move through the results.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let step: Int
        switch selector {
        case #selector(NSResponder.moveUp(_:)): step = -1
        case #selector(NSResponder.moveDown(_:)): step = 1
        case #selector(NSResponder.insertNewline(_:)):
            jump()
            return true
        default: return false
        }
        let row = min(max(0, table.selectedRow + step), matches.count - 1)
        if row >= 0 {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        return true
    }
}
