import Foundation

protocol SubtitleSearching: AnyObject {
    func search(_ document: SubtitleTranscript, query: String, completion: @escaping ([Int]) -> Void)
    func cancel()
}

/// One bounded worker: rapid typing cancels the old scan rather than queueing
/// full-document searches. Only the newest generation publishes on main.
final class SubtitleSearch: SubtitleSearching {
    private let queue: OperationQueue
    private var generation = 0
    init() {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }
    func search(_ document: SubtitleTranscript, query: String, completion: @escaping ([Int]) -> Void) {
        cancel()
        let token = generation, operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let rows = document.matches(query, cancelled: { operation.isCancelled })
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                completion(rows)
            }
        }
        queue.addOperation(operation)
    }
    func cancel() { generation += 1; queue.cancelAllOperations() }
    deinit { queue.cancelAllOperations() }
}
