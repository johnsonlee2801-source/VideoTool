import AppKit

struct SubtitleTranscriptContext {
    let target: String
    let local: URL?
    let network: NetworkVideo?
    let external: [SubtitleSourceOption]
    let preferredSource: String?
}

/// Owns cancellation, source identity and its own temporary display file.
/// It never starts speech recognition or writes local library/watch records.
final class SubtitleTranscriptCoordinator {
    let view: SubtitleTranscriptView
    var loader: SubtitleContentLoading
    var catalog: NetworkCaptionCatalogLoading
    var onDisplayFile: ((URL, String) -> Void)?
    var onRemoveFile: ((URL) -> Void)?
    var onSelectTrack: ((String) -> Void)?
    var writeQueue: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    var mainQueue: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    private(set) var documentTarget: String?
    private(set) var sources: [SubtitleSourceOption] = []
    private var context: SubtitleTranscriptContext?
    private var generation = 0
    private var loading = false
    private var temporaryFile: URL?
    init(view: SubtitleTranscriptView, loader: SubtitleContentLoading = SubtitleContentLoader(), catalog: NetworkCaptionCatalogLoading = NetworkCaptionCatalog()) {
        self.view = view; self.loader = loader; self.catalog = catalog
        view.onSource = { [weak self] in self?.loadSource($0, explicit: true) }
        view.onCancel = { [weak self] in self?.cancelRead() }
    }
    func open(_ context: SubtitleTranscriptContext, refresh: Bool = false) {
        if !refresh, documentTarget == context.target, view.document != nil { return }
        let previous = self.context?.target == context.target ? view.selectedSourceID : nil
        cancelRead(); self.context = context
        documentTarget = nil; sources = []
        view.setSources([]); view.setDocument(nil, status: "")
        loading = true; view.setStatus(L("正在读取字幕来源…"), loading: true)
        let token = generation
        if let network = context.network {
            catalog.resolve(network) { [weak self] result in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let tracks):
                    let sources = tracks.map { SubtitleSourceOption(id: "website:" + $0.id, title: $0.title, input: .website($0)) }
                    self.setSources(sources, preferred: previous ?? context.preferredSource)
                case .failure(let error): self.finishFailure(error.localizedDescription)
                }
            }
        } else if let local = context.local {
            loader.localSources(local) { [weak self] result in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let embedded): self.setSources(context.external + embedded, preferred: previous ?? context.preferredSource)
                case .failure(let error):
                    if !context.external.isEmpty { self.setSources(context.external, preferred: previous ?? context.preferredSource) }
                    else { self.finishFailure(error.localizedDescription) }
                }
            }
        } else { finishFailure(SubtitleLoadFailure.unavailable.localizedDescription) }
    }
    private func setSources(_ options: [SubtitleSourceOption], preferred: String?) {
        var seen = Set<String>()
        // Our own display file is loaded into the player and so shows up as an external track;
        // it is deleted on the next switch, so it must never be offered as a source.
        sources = options.filter { option in
            if case .file(let url, _) = option.input, url.deletingLastPathComponent().standardizedFileURL == Self.displayDirectory.standardizedFileURL { return false }
            return seen.insert(option.id).inserted
        }
        view.setSources(sources, selected: preferred)
        guard let selected = view.selectedSourceID else { finishFailure(context?.network == nil ? L("没有可搜索的字幕，可选择其他字幕或生成本机 AI 字幕。") : L("此视频没有公开可读取的字幕。")); return }
        loadSource(selected, explicit: false)
    }
    private func loadSource(_ id: String, explicit: Bool) {
        guard let source = sources.first(where: { $0.id == id }), let context else { return }
        generation += 1; loader.cancel(); catalog.cancel()
        let token = generation
        documentTarget = nil; loading = true
        view.setDocument(nil, status: ""); view.setStatus(L("正在读取字幕内容…"), loading: true)
        loader.load(source.input) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.loading = false
            switch result {
            case .success(let document):
                self.documentTarget = context.target
                self.view.setDocument(document, status: L("共 %@ 句，点击字幕即可跳转", String(document.cues.count)))
                if case .website = source.input { self.display(document, title: source.title) }
                else if explicit {
                    if let track = source.playerTrackID { self.onSelectTrack?(track) }
                    else { self.display(document, title: source.title) }
                }
            case .failure(let error): self.finishFailure(error.localizedDescription)
            }
        }
    }
    static var displayDirectory: URL { AppData.directory.appendingPathComponent("TranscriptCaptions", isDirectory: true) }
    /// Serializing up to 30,000 cues and writing them happens off the main thread;
    /// a write that finishes after the source or video changed is deleted, never shown.
    private func display(_ document: SubtitleTranscript, title: String) {
        let token = generation, directory = Self.displayDirectory, main = mainQueue
        writeQueue { [weak self] in
            let result = Result<URL, Error> {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(UUID().uuidString + ".srt")
                try SRT.document(document.cues).write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            main {
                guard let self, self.generation == token, self.context != nil else {
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                switch result {
                case .success(let url): self.removeTemporary(); self.temporaryFile = url; self.onDisplayFile?(url, title)
                case .failure: self.view.setStatus(L("字幕已读取，但无法添加到播放画面。"), loading: false)
                }
            }
        }
    }
    private func finishFailure(_ message: String) {
        loading = false; documentTarget = nil; view.setDocument(nil, status: message)
    }
    func cancelRead() {
        generation += 1; loader.cancel(); catalog.cancel()
        if loading { loading = false; documentTarget = nil; view.setDocument(nil, status: SubtitleLoadFailure.cancelled.localizedDescription) }
    }
    func reset() {
        cancelRead(); context = nil; sources = []; documentTarget = nil
        view.searchField.stringValue = ""; view.setSources([]); view.setDocument(nil, status: "")
        removeTemporary()
    }
    private func removeTemporary() {
        if let file = temporaryFile { onRemoveFile?(file); try? FileManager.default.removeItem(at: file) }
        temporaryFile = nil
    }
    deinit { loader.cancel(); catalog.cancel(); if let file = temporaryFile { try? FileManager.default.removeItem(at: file) } }
}
