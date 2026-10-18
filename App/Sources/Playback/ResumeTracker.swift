import Foundation

/// Decides when to save, clear and restore the resume position.
///
/// The current file is whatever `fileLoaded(path:duration:)` last named; that
/// path and duration are read by the engine at FILE_LOADED time. A state
/// update is acted on only if its own `path` matches, so it does not matter
/// whether mpv delivers FILE_LOADED before or after the `path` property change,
/// and one file's position can never be written under another file's name.
struct ResumeTracker {
    enum Action: Equatable {
        case save(path: String, position: Double)
        case clear(path: String)
        case seek(Double)
    }

    static let saveInterval = 5.0
    /// mpv keeps reporting the pre-seek position for a few updates after a seek.
    static let seekLandingTolerance = 1.5
    /// Updates to wait for the resume seek to land before trusting time-pos anyway.
    static let seekLandingBudget = 120

    private let storedPosition: (String) -> Double?
    private var path: String?               // file named by the last fileLoaded
    private var awaitingDuration = false    // loaded without a known duration (streams)
    private var pendingSeek: (target: Double, updatesLeft: Int)?
    private var lastSavedAt = 0.0
    private var clearedAtEOF = false

    init(storedPosition: @escaping (String) -> Double?) {
        self.storedPosition = storedPosition
    }

    /// mpv finished opening `path`. Returns the resume seek, if any.
    mutating func fileLoaded(path: String, duration: Double) -> [Action] {
        self.path = path
        lastSavedAt = 0
        clearedAtEOF = false
        pendingSeek = nil
        awaitingDuration = !(duration > 0)
        return awaitingDuration ? [] : resume(duration: duration)
    }

    mutating func update(_ s: PlayerState) -> [Action] {
        guard let path, s.path == path else { return [] }   // another file, or not loaded yet

        if awaitingDuration {
            guard s.duration > 0 else { return [] }
            awaitingDuration = false
            return resume(duration: s.duration)
        }

        if let seek = pendingSeek {
            // Ignore stale pre-seek positions so they cannot overwrite the stored one.
            if abs(s.timePos - seek.target) <= Self.seekLandingTolerance || seek.updatesLeft <= 0 {
                pendingSeek = nil
                lastSavedAt = s.timePos
            } else {
                pendingSeek = (seek.target, seek.updatesLeft - 1)
            }
            return []
        }

        if s.eofReached {
            if clearedAtEOF { return [] }
            clearedAtEOF = true
            return [.clear(path: path)]
        }
        clearedAtEOF = false

        guard !s.isPaused else { return [] }
        if s.timePos - lastSavedAt >= Self.saveInterval || s.timePos < lastSavedAt {
            lastSavedAt = s.timePos
            return [.save(path: path, position: s.timePos)]
        }
        return []
    }

    /// What to persist when the window closes or the app quits.
    func finalAction(_ s: PlayerState) -> Action? {
        guard let path, s.path == path, s.duration > 0 else { return nil }
        return s.eofReached ? .clear(path: path) : .save(path: path, position: s.timePos)
    }

    private mutating func resume(duration: Double) -> [Action] {
        guard let path,
              let target = ResumePositionStore.resumeTarget(position: storedPosition(path), duration: duration)
        else { return [] }
        lastSavedAt = target
        pendingSeek = (target, Self.seekLandingBudget)
        return [.seek(target)]
    }
}
