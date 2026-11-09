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
