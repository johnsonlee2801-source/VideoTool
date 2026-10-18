import Foundation

enum TimeFormatting {
    /// 65 -> "1:05", 3661 -> "1:01:01". Non-finite or negative -> "0:00".
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        // Clamp before converting: Int(Double) traps on huge finite values.
        let total = Int(min(seconds, 359_999_999).rounded(.down))     // caps at 99999:59:59
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
