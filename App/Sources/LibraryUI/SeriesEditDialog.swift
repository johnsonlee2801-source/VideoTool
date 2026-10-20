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
        // Season 0 is real (specials, "S00E01"); only an empty field means "no season".
        return SeriesOverride(title: t, season: s.flatMap { $0 >= 0 ? $0 : nil }, episode: ep)
    }

    /// The fields, prefilled with what the series view currently thinks.
    final class Form {
        let title: NSTextField
        let season: NSTextField
        let episode: NSTextField
        let renameAll = NSButton(checkboxWithTitle: L("同一部剧的其他集也改用这个剧名"), target: nil, action: nil)
        let view: NSGridView

        init(current: EpisodeInfo?) {
            title = NSTextField(string: current?.title ?? "")
            season = NSTextField(string: current?.season.map(String.init) ?? "")
            episode = NSTextField(string: current.map { String($0.episode) } ?? "")
            title.placeholderString = L("剧名")
            season.placeholderString = L("可不填")
            episode.placeholderString = L("必填")
            renameAll.state = .on
            for f in [title, season, episode] { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
            view = NSGridView(views: [
                [NSTextField(labelWithString: L("剧名：")), title],
                [NSTextField(labelWithString: L("第几季：")), season],
                [NSTextField(labelWithString: L("第几集：")), episode],
                [NSGridCell.emptyContentView, renameAll],
            ])
            view.rowSpacing = 8
            view.column(at: 0).xPlacement = .trailing
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        }

        /// What pressing a button means. An unusable form (no name or episode) saves nothing.
        func result(for response: NSApplication.ModalResponse) -> Result {
            switch response {
            case .alertFirstButtonReturn:
                guard let o = parse(title: title.stringValue, season: season.stringValue, episode: episode.stringValue) else {
                    return .cancel
                }
                return .save(o, renameShow: renameAll.state == .on)
            case .alertThirdButtonReturn:
                return .notSeries
            default:
                return .cancel
            }
        }
    }

    /// Save pressed with an unusable form: show it again with what was typed, instead
    /// of closing and losing the edits (audit 2026-10-20).
    static func shouldAskAgain(after response: NSApplication.ModalResponse, form: Form) -> Bool {
        response == .alertFirstButtonReturn && form.result(for: response) == .cancel
    }

    static func run(on window: NSWindow, item: LibraryItem, current: EpisodeInfo?,
                    completion: @escaping (Result) -> Void) {
        present(Form(current: current), on: window, item: item, problem: nil, completion: completion)
    }

    private static func present(_ form: Form, on window: NSWindow, item: LibraryItem, problem: String?,
                                completion: @escaping (Result) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("修改剧集信息")
        alert.informativeText = problem ?? L("「%@」\n改过的信息会记住，文件改名或移动后也有效。", String(describing: item.name))
        alert.accessoryView = form.view
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("不是剧集"))
        alert.beginSheetModal(for: window) { response in
            if shouldAskAgain(after: response, form: form) {
                NSSound.beep()
                DispatchQueue.main.async {
                    present(form, on: window, item: item, problem: L("请填写剧名和集数（集数是数字）。"), completion: completion)
                }
                return
            }
            completion(form.result(for: response))
        }
    }
}
