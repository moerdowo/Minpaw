import SwiftUI
import AppKit

// AppKit-backed playlist. SwiftUI List + .onMove was unreliable on macOS
// (drag would only register on empty space, would frequently fail to commit
// the reorder, and gesture state degraded after the first drag). NSTableView
// gives us rock-solid native drag-and-drop, selection, and double-click
// while keeping the LCD-green / amber-now-playing aesthetic.
struct PlaylistTable: NSViewRepresentable {
    let tracks: [Track]
    @Binding var selection: Set<UUID>
    let currentTrackID: UUID?
    let onPlay: (Int) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onReveal: (Track) -> Void
    let onRemove: (Int) -> Void

    fileprivate static let dragType = NSPasteboard.PasteboardType("app.minpaw.row-index")

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let tableView = DropIndicatorTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 16
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.menu = context.coordinator.makeContextMenu()
        // Suppress AppKit's own drop feedback — we draw our own glowing green line.
        tableView.draggingDestinationFeedbackStyle = .none

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        col.resizingMask = [.autoresizingMask]
        tableView.addTableColumn(col)

        tableView.registerForDraggedTypes([Self.dragType])
        context.coordinator.tableView = tableView

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        tableView.reloadData()
        let desiredIndexes = IndexSet(
            tracks.enumerated().compactMap { selection.contains($0.element.id) ? $0.offset : nil }
        )
        if tableView.selectedRowIndexes != desiredIndexes {
            tableView.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
        }
        if let id = currentTrackID,
           let row = tracks.firstIndex(where: { $0.id == id }) {
            tableView.scrollRowToVisible(row)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: PlaylistTable
        weak var tableView: NSTableView?

        init(parent: PlaylistTable) { self.parent = parent }

        // MARK: data source

        func numberOfRows(in tableView: NSTableView) -> Int { parent.tracks.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.tracks.count else { return nil }
            let track = parent.tracks[row]
            let cell = (tableView.makeView(withIdentifier: TrackRowView.identifier, owner: self) as? TrackRowView) ?? TrackRowView()
            cell.identifier = TrackRowView.identifier
            cell.update(
                index: row,
                title: displayLine(track),
                duration: formatDuration(track.duration),
                isPlaying: parent.currentTrackID == track.id,
                isSelected: parent.selection.contains(track.id)
            )
            return cell
        }

        // MARK: drag source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString("\(row)", forType: PlaylistTable.dragType)
            return item
        }

        // MARK: drop target

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else {
                (tableView as? DropIndicatorTableView)?.hideDropIndicator()
                return []
            }
            (tableView as? DropIndicatorTableView)?.showDropIndicator(beforeRow: row)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row destRow: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            (tableView as? DropIndicatorTableView)?.hideDropIndicator()
            guard let item = info.draggingPasteboard.pasteboardItems?.first,
                  let s = item.string(forType: PlaylistTable.dragType),
                  let sourceRow = Int(s) else {
                return false
            }
            let from = IndexSet(integer: sourceRow)
            DispatchQueue.main.async { self.parent.onMove(from, destRow) }
            return true
        }

        // MARK: selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let selectedRows = tableView.selectedRowIndexes
            let newIDs: [UUID] = selectedRows.compactMap { row in
                guard row < parent.tracks.count else { return nil }
                return parent.tracks[row].id
            }
            let newSet = Set(newIDs)
            if parent.selection != newSet {
                DispatchQueue.main.async { self.parent.selection = newSet }
            }
        }

        // MARK: double-click

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < parent.tracks.count else { return }
            DispatchQueue.main.async { self.parent.onPlay(row) }
        }

        // MARK: context menu

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            let play = NSMenuItem(title: "Play", action: #selector(menuPlay), keyEquivalent: "")
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(menuReveal), keyEquivalent: "")
            let remove = NSMenuItem(title: "Remove", action: #selector(menuRemove), keyEquivalent: "")
            for item in [play, reveal, remove] { item.target = self }
            menu.items = [play, reveal, .separator(), remove]
            return menu
        }

        @objc func menuPlay() {
            guard let row = tableView?.clickedRow, row >= 0 else { return }
            DispatchQueue.main.async { self.parent.onPlay(row) }
        }

        @objc func menuReveal() {
            guard let row = tableView?.clickedRow, row >= 0, row < parent.tracks.count else { return }
            let track = parent.tracks[row]
            DispatchQueue.main.async { self.parent.onReveal(track) }
        }

        @objc func menuRemove() {
            guard let row = tableView?.clickedRow, row >= 0 else { return }
            DispatchQueue.main.async { self.parent.onRemove(row) }
        }

        // MARK: helpers

        private func displayLine(_ track: Track) -> String {
            if let artist = track.artist, !artist.isEmpty {
                return "\(artist) - \(track.title)"
            }
            return track.title
        }

        private func formatDuration(_ t: TimeInterval) -> String {
            let s = Int(t)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
    }
}

// MARK: - NSTableView subclass with a custom drop-indicator line

final class DropIndicatorTableView: NSTableView {
    private let indicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(red: 0.30, green: 0.65, blue: 1.00, alpha: 1).cgColor
        v.layer?.cornerRadius = 1
        v.layer?.shadowColor = NSColor(red: 0.45, green: 0.75, blue: 1.00, alpha: 1).cgColor
        v.layer?.shadowOpacity = 0.95
        v.layer?.shadowRadius = 3
        v.layer?.shadowOffset = .zero
        v.isHidden = true
        return v
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(indicator)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(indicator)
    }

    func showDropIndicator(beforeRow row: Int) {
        guard numberOfRows > 0 else {
            indicator.isHidden = true
            return
        }
        let proposedY: CGFloat
        if row >= numberOfRows {
            // Insertion after the last row.
            proposedY = rect(ofRow: numberOfRows - 1).maxY
        } else {
            proposedY = rect(ofRow: row).minY
        }
        let height: CGFloat = 2
        // Clamp so the line is fully visible at the top edge (row 0)
        // and the bottom edge (after the last row) instead of being
        // half-clipped outside the table's bounds.
        let y = min(max(0, proposedY - height / 2), max(0, bounds.height - height))
        indicator.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        indicator.isHidden = false
        indicator.layer?.zPosition = 1000
        // Make sure it draws above the row views.
        if let superview = indicator.superview {
            indicator.removeFromSuperview()
            superview.addSubview(indicator)
        }
    }

    func hideDropIndicator() {
        indicator.isHidden = true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        hideDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        hideDropIndicator()
    }
}

// MARK: - Custom row view (LCD-green / amber-now-playing / dark-blue selected)

final class TrackRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TrackRowView")

    private let bgView = NSView()
    private let indexLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        bgView.wantsLayer = true
        bgView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgView)

        let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        for label in [indexLabel, titleLabel, durationLabel] {
            label.font = mono
            label.drawsBackground = false
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        indexLabel.alignment = .right
        durationLabel.alignment = .right

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),

            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            indexLabel.widthAnchor.constraint(equalToConstant: 24),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            durationLabel.widthAnchor.constraint(equalToConstant: 36),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(index: Int, title: String, duration: String, isPlaying: Bool, isSelected: Bool) {
        indexLabel.stringValue = "\(index + 1)."
        titleLabel.stringValue = title
        durationLabel.stringValue = duration

        let color: NSColor = isPlaying
            ? NSColor(red: 1.00, green: 0.78, blue: 0.07, alpha: 1)
            : (isSelected ? NSColor.white : NSColor(red: 0.12, green: 0.91, blue: 0.24, alpha: 1))

        for label in [indexLabel, titleLabel, durationLabel] {
            label.textColor = color
            if !isSelected {
                let shadow = NSShadow()
                shadow.shadowColor = color.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = .zero
                label.shadow = shadow
            } else {
                label.shadow = nil
            }
        }

        bgView.layer?.backgroundColor = isSelected
            ? NSColor(red: 0.04, green: 0.18, blue: 0.30, alpha: 1).cgColor
            : NSColor.clear.cgColor
    }
}
