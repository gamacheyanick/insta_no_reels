import Foundation

/// Session usage shown in the top bar: how long the app has been in the
/// foreground, and how many feed posts have scrolled past.
final class UsageTracker: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var postsViewed = 0

    /// Being in the background longer than this starts a fresh session.
    private let sessionResetAfter: TimeInterval = 30 * 60

    private var accumulated: TimeInterval = 0
    private var activeSince: Date?
    private var backgroundedAt: Date?
    private var timer: Timer?

    func recordPostViewed() {
        postsViewed += 1
    }

    func setActive(_ active: Bool) {
        if active {
            if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > sessionResetAfter {
                accumulated = 0
                postsViewed = 0
            }
            backgroundedAt = nil
            activeSince = Date()
            startTimer()
        } else {
            if let activeSince {
                accumulated += Date().timeIntervalSince(activeSince)
            }
            activeSince = nil
            backgroundedAt = Date()
            stopTimer()
        }
        refresh()
    }

    var elapsedText: String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Past this many posts the counter turns red, and it gains one
    /// exclamation mark for every further `postsWarningStep` posts.
    static let postsWarningThreshold = 15
    static let postsWarningStep = 15

    var isOverPostsThreshold: Bool {
        postsViewed > Self.postsWarningThreshold
    }

    var postsText: String {
        let base = postsViewed == 1 ? "1 post" : "\(postsViewed) posts"
        let over = postsViewed - Self.postsWarningThreshold
        let exclamations = over > 0 ? over / Self.postsWarningStep : 0
        return base + String(repeating: "!", count: exclamations)
    }

    private func refresh() {
        var value = accumulated
        if let activeSince {
            value += Date().timeIntervalSince(activeSince)
        }
        elapsed = value
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
