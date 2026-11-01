import AppKit

/// Shared compact rendering for indexed videos and recent playback. Only visible
/// collection/table rows load thumbnails; the file itself is never probed here.
final class SidebarMediaRow: NSView {
    private let thumb = AspectFillImageView()
    private let icon = NSImageView(image: NSImage(systemSymbolName: "film", accessibilityDescription: nil)!)
    private let name = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = WatchProgressStripe()
    private let compact: Bool
    var isCurrent = false { didSet { updateBorder() } }
    var isSelected = false { didSet { updateBorder() } }

    override convenience init(frame: NSRect) { self.init(frame: frame, compact: false) }
    init(frame: NSRect, compact: Bool) {
        self.compact = compact
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.cornerRadius = Theme.radiusCard
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = Theme.radiusSmall
        thumb.layer?.masksToBounds = true
        icon.contentTintColor = Theme.accent2
        icon.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Theme.textPrimary
        metadata.font = .systemFont(ofSize: 11, weight: .medium)
        metadata.textColor = Theme.accent2
        detail.font = .systemFont(ofSize: 10, weight: .medium)
        detail.textColor = Theme.textSecondary
        for label in [name, metadata, detail] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for child in [thumb, name, metadata, detail, progress] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        thumb.addSubview(icon)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: compact ? 80 : 112),
            thumb.heightAnchor.constraint(equalToConstant: compact ? 45 : 63),
            icon.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: compact ? 8 : 14),
            metadata.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: name.bottomAnchor, constant: compact ? 4 : 6),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 5),
            progress.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            progress.heightAnchor.constraint(equalToConstant: 3),
        ])
        detail.isHidden = compact
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(path: String, item: LibraryItem?, watch: WatchEntry?, thumbnail: URL?, recent: Bool, current: Bool) {
        name.stringValue = (path as NSString).lastPathComponent
        name.toolTip = path
        var parts = item?.tags.prefix(2).map { L($0) } ?? []
        let duration = item?.record.duration ?? watch?.duration ?? 0
        if duration > 0 { parts.append(TimeFormatting.string(duration)) }
        if let item {
            let resolution = LibraryGrouping.resolutionBucket(width: item.record.width, height: item.record.height)
            if resolution != .unknown { parts.append(resolution.title) }
            if item.record.status == .cloudOnly { parts = [L("iCloud 未下载")] }
        }
        metadata.stringValue = parts.joined(separator: " · ")
        if let watch {
            let state = watch.isWatched ? L("✓ 已看完") : L("继续观看")
            let time = Self.timeLabel(watch.watchedAt)
            detail.stringValue = recent ? "\(time) · \(state) · \(Int(watch.fraction * 100))%" : "\(state) · \(Int(watch.fraction * 100))%"
            detail.toolTip = DateFormatter.localizedString(from: watch.watchedAt, dateStyle: .full, timeStyle: .short)
            progress.fraction = watch.isWatched ? 0 : watch.fraction
        } else {
            detail.stringValue = item.map { $0.starCount > 0 ? "★ \($0.starCount)" : "" } ?? ""
            detail.toolTip = nil
            progress.fraction = 0
        }
        progress.isHidden = progress.fraction <= 0
        if compact {
            let state = watch.map { $0.isWatched ? L("✓ 已看完") : L("继续观看") + " · \(Int($0.fraction * 100))%" } ?? item?.tags.first.map { L($0) } ?? ""
            metadata.stringValue = [duration > 0 ? TimeFormatting.string(duration) : "", state].filter { !$0.isEmpty }.joined(separator: " · ")
            if item?.record.status == .cloudOnly { metadata.stringValue = L("iCloud 未下载") }
        }
        thumb.image = thumbnail.flatMap { NSImage(contentsOf: $0) }
        icon.isHidden = thumb.image != nil
        isCurrent = current
        setAccessibilityLabel([name.stringValue, metadata.stringValue, detail.stringValue].joined(separator: ", "))
    }
    static func timeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return L("今天 %@", DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
    private func updateBorder() {
        layer?.borderWidth = isCurrent || isSelected ? 1.5 : 0
        layer?.borderColor = (isCurrent ? Theme.accent : Theme.accent2).cgColor
    }
}

final class SidebarMediaItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("SidebarMediaItem")
    var row: SidebarMediaRow { view as! SidebarMediaRow }
    var onDoubleClick: (() -> Void)?
    override func loadView() { view = SidebarMediaRow(frame: NSRect(x: 0, y: 0, width: 350, height: 92)) }
    override var isSelected: Bool { didSet { row.isSelected = isSelected } }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
