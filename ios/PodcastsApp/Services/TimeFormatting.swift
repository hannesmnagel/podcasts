import Foundation

enum TimeFormatting {
    static func playbackTime(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "--:--" }
        let total = max(0, Int(value.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
        }
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}
