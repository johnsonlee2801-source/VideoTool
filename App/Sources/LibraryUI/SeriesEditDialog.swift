import AppKit

/// Thin bar along the bottom of a cover: how much of the video has been watched.
final class WatchProgressStripe: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * min(max(fraction, 0), 1), height: bounds.height).fill()
    }
}

/// Right-click › 修改剧集信息…: show name, season, episode; or "not a series".
enum SeriesEditDialog {
    enum Result: Equatable {
        case save(SeriesOverride, renameShow: Bool)
        case notSeries
        case cancel
    }

    /// Reads the form; nil if the episode number is missing or not a number.
    static func parse(title: String, season: String, episode: String) -> SeriesOverride? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let ep = Int(episode.trimmingCharacters(in: .whitespaces)), ep >= 0 else { return nil }
        let s = Int(season.trimmingCharacters(in: .whitespaces))
        return SeriesOverride(title: t, season: s.flatMap { $0 > 0 ? $0 : nil }, episode: ep)
    }

    static func run(on window: NSWindow, item: LibraryItem, current: EpisodeInfo?,
                    completion: @escaping (Result) -> Void) {
        let title = NSTextField(string: current?.title ?? "")
        let season = NSTextField(string: current?.season.map(String.init) ?? "")
        let episode = NSTextField(string: current.map { String($0.episode) } ?? "")
        title.placeholderString = "剧名"
        season.placeholderString = "可不填"
        episode.placeholderString = "必填"
        let renameAll = NSButton(checkboxWithTitle: "同一部剧的其他集也改用这个剧名", target: nil, action: nil)
        renameAll.state = .on
        for f in [title, season, episode] { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "剧名："), title],
            [NSTextField(labelWithString: "第几季："), season],
            [NSTextField(labelWithString: "第几集："), episode],
            [NSGridCell.emptyContentView, renameAll],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 120)

        let alert = NSAlert()
        alert.messageText = "修改剧集信息"
        alert.informativeText = "「\(item.name)」\n改过的信息会记住，文件改名或移动后也有效。"
        alert.accessoryView = grid
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不是剧集")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                guard let o = parse(title: title.stringValue, season: season.stringValue, episode: episode.stringValue) else {
                    NSSound.beep(); return completion(.cancel)
                }
                completion(.save(o, renameShow: renameAll.state == .on))
            case .alertThirdButtonReturn:
                completion(.notSeries)
            default:
                completion(.cancel)
            }
        }
    }
}
