import AppKit
import UniformTypeIdentifiers

enum DefaultAppRegistrar {
    typealias Setter = (_ appURL: URL, _ type: UTType, _ done: @escaping (Error?) -> Void) -> Void

    struct Summary: Equatable {
        var total: Int
        var failures: [String]
        var message: String {
            if failures.isEmpty { return "已把 \(total) 种媒体类型的默认打开方式设为 VideoTool。" }
            return "成功 \(total - failures.count) 种，失败 \(failures.count) 种：\n" + failures.prefix(8).joined(separator: "\n")
        }
    }

    static let systemSetter: Setter = { appURL, type, done in
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { done($0) }
    }

    /// Asks Launch Services to route every media type to this app. Each type is
    /// a separate request whose completion may arrive on any queue; results are
    /// collected on one serial queue and the summary is delivered on main.
    static func makeDefault(types: [UTType] = MediaTypes.utTypes,
                            appURL: URL = Bundle.main.bundleURL,
                            setter: @escaping Setter = systemSetter,
                            completion: @escaping (Summary) -> Void) {
        let collector = DispatchQueue(label: "io.github.johnsonlee2801-source.videotool.default-app")
        var failures: [String] = []
        let group = DispatchGroup()
        for type in types {
            group.enter()
            setter(appURL, type) { error in
                collector.async {
                    if let error { failures.append("\(type.identifier): \(error.localizedDescription)") }
                    group.leave()
                }
            }
        }
        group.notify(queue: collector) {
            let summary = Summary(total: types.count, failures: failures.sorted())
            DispatchQueue.main.async { completion(summary) }
        }
    }
}
