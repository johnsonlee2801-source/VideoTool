import AppKit
import UniformTypeIdentifiers

enum DefaultAppRegistrar {
    typealias Setter = (_ appURL: URL, _ type: UTType, _ done: @escaping (Error?) -> Void) -> Void

    struct Summary: Equatable {
        var total: Int
        var failures: [String]
        var message: String {
            if failures.isEmpty { return L("已把 %@ 种视频格式的默认打开方式设为 VideoTool。", String(describing: total)) }
            return L("成功 %1$@ 种，失败 %2$@ 种：\n", String(describing: total - failures.count), String(describing: failures.count)) + failures.prefix(8).joined(separator: "\n")
        }
    }

    /// NSWorkspace asks the user to confirm each change. On current macOS this is the
    /// only way that works: LSSetDefaultRoleHandlerForContentType reports success
    /// but changes nothing (verified on the user's Mac, 2026-10-18), so defaults can
    /// never be switched unattended.
    static let systemSetter: Setter = { appURL, type, done in
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { done($0) }
    }

    /// Routes the given types to this app, one request at a time: macOS shows a
    /// confirmation per type, and the next appears only after the previous one is
    /// answered (never a pile of dialogs). Completions may arrive on any queue;
    /// results are collected on one serial queue and the summary arrives on main.
    static func makeDefault(types: [UTType] = MediaTypes.videoUTTypes,
                            appURL: URL = Bundle.main.bundleURL,
                            setter: @escaping Setter = systemSetter,
                            completion: @escaping (Summary) -> Void) {
        let collector = DispatchQueue(label: "io.github.johnsonlee2801-source.videotool.default-app")
        var failures: [String] = []
        func step(_ index: Int) {
            guard index < types.count else {
                let summary = Summary(total: types.count, failures: failures.sorted())
                DispatchQueue.main.async { completion(summary) }
                return
            }
            let type = types[index]
            setter(appURL, type) { error in
                collector.async {
                    if let error { failures.append("\(type.identifier): \(error.localizedDescription)") }
                    step(index + 1)
                }
            }
        }
        collector.async { step(0) }
    }
}
