import Foundation
import TallyCore

/// How long the schedule waits before trying again after a failed refresh.
///
/// A failure that persists (an expired token, a proxy, an outage) shouldn't be asked about every minute for
/// as long as it lasts: each consecutive failure doubles the wait, up to the normal refresh interval. A rate
/// limit says when it lifts, and no backoff is allowed to carry the next try past that moment.
enum TallyStoreRetry {
    static func delay(afterFailures failures: Int, error: Error?, base: Duration, interval: Duration, now: Date) -> Duration {
        let ceiling = max(base, interval)
        // The exponent is capped so a long outage can't overflow the multiplication.
        let backoff = min(base * (1 << min(max(failures - 1, 0), 10)), ceiling)
        guard case .rateLimited(let until)? = error as? GitHubError else { return backoff }
        // Waiting for the limit, not for the backoff, is the point: the deadline is exact and a try before it fails.
        let remaining = max(0, until.timeIntervalSince(now))
        return max(base, .seconds(remaining))
    }
}

extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

extension TallyStore {
    /// When the next try is, for the footer and VoiceOver, while the latest refresh has failed: otherwise the
    /// numbers just stop and nothing says whether the app is still trying. A rate limit's own message already
    /// names when it lifts, and waiting for the network has none, since the network coming back is what retries.
    func retryText(at now: Date) -> String? {
        guard !automaticRefreshPaused, let lastFailure, let nextTryAt, nextTryAt > now else { return nil }
        if case .rateLimited? = lastFailure as? GitHubError { return nil }
        return "Next try \(nextTryAt.formatted(date: .omitted, time: .shortened))"
    }

    func retrySuffix(at now: Date) -> String {
        retryText(at: now).map { ". \($0)" } ?? ""
    }
}
