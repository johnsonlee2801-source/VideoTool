import AppKit

/// Right-hand panel listing the stars of the current video. Double-click a row
/// to jump (2 s before the star); edit the note in place; delete with the trash button.
final class BookmarkListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onJump: ((Bookmark) -> Void)?
    var onNoteChange: ((UUID, String) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private(set) var bookmarks: [Bookmark] = []
    private let titleLabel = NSTextField(labelWithString: L("星标"))
    private let table = NSTableView()
    private let empty = NSTextField(wrappingLabelWithString: L("还没有星标。\n播放时按 B 把当前时刻标上星。"))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor
        let edge = NSView()
        edge.wantsLayer = true
        edge.layer?.backgroundColor = Theme.stroke.cgColor
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([edge.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     edge.topAnchor.constraint(equalTo: topAnchor),
                                     edge.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     edge.widthAnchor.constraint(equalToConstant: 1)])

        let title = titleLabel
        title.font = Theme.display(17, .heavy)
        title.textColor = Theme.textPrimary

        let column = NSTableColumn(identifier: .init("star"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.textColor = Theme.textSecondary
        empty.font = .systemFont(ofSize: 13, weight: .medium)
        empty.alignment = .center

        for v in [title, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            // Breakable: the panel collapses to zero width when hidden.
            { let c = empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
              c.priority = .defaultHigh; return c }(),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var pending: [Bookmark]?

    /// Reloads the rows, except while a note is being typed: then the update is
    /// applied when editing ends, so the text in progress is never thrown away.
    func show(_ bookmarks: [Bookmark]) {
        if isEditingNote { pending = bookmarks; return }
        self.bookmarks = bookmarks
        titleLabel.stringValue = bookmarks.isEmpty ? L("星标") : L("星标  %@", String(describing: bookmarks.count))
        empty.isHidden = !bookmarks.isEmpty
        table.reloadData()
    }

    private var isEditingNote: Bool {
        guard let editor = window?.firstResponder as? NSText else { return false }
        return (editor.delegate as? NSView)?.isDescendant(of: table) == true
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { bookmarks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let b = bookmarks[row]
        let cell = NSView()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = Theme.bg2.cgColor
        cell.layer?.cornerRadius = Theme.radiusCard

        let time = NSButton(title: "★ " + TimeFormatting.string(b.time), target: self, action: #selector(timeClicked(_:)))
        time.isBordered = false
        time.contentTintColor = Theme.star
        time.font = Theme.digits(13, .heavy)
        time.tag = row
        time.toolTip = L("跳到这里（提前 2 秒）")

        let note = NSTextField(string: b.note)
        note.placeholderAttributedString = NSAttributedString(string: L("添加备注…"), attributes: [
            .foregroundColor: Theme.textTertiary, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        note.isBordered = false
        note.drawsBackground = false
        note.textColor = Theme.textPrimary
        note.font = .systemFont(ofSize: 12, weight: .semibold)
        note.focusRingType = .none
        note.delegate = self
        note.tag = row

        let trash = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("删除星标"))!,
                             target: self, action: #selector(deleteClicked(_:)))
        trash.isBordered = false
        trash.contentTintColor = Theme.textSecondary
        trash.tag = row

        for v in [time, note, trash] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            time.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            note.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: trash.leadingAnchor, constant: -6),
            note.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 1),
            trash.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            trash.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard bookmarks.indices.contains(row) else { return }
        onJump?(bookmarks[row])
    }

    @objc private func timeClicked(_ sender: NSButton) {
        guard bookmarks.indices.contains(sender.tag) else { return }
        onJump?(bookmarks[sender.tag])
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard bookmarks.indices.contains(sender.tag) else { return }
        onDelete?(bookmarks[sender.tag].id)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, bookmarks.indices.contains(field.tag) else { return }
        let b = bookmarks[field.tag]
        window?.makeFirstResponder(nil)        // give keys back to the player
        if let latest = pending { pending = nil; show(latest) }
        if field.stringValue != b.note { onNoteChange?(b.id, field.stringValue) }
    }
}
