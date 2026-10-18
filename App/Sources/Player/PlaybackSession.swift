import Foundation

/// Owns the mpv engine and its render layer and is the only place that tears
/// them down, so the render context is always freed before mpv is destroyed.
final class PlaybackSession {
    let engine: MPVEngine
    let renderLayer: MPVRenderLayer
    private var isShutDown = false

    init() throws {
        engine = try MPVEngine()
        renderLayer = MPVRenderLayer(engine: engine)
    }

    deinit { shutdown() }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        renderLayer.teardown()
        engine.shutdown()
    }
}
