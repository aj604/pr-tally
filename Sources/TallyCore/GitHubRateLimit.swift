import Foundation

/// Reads GitHub's rate limit signals from a response.
enum GitHubRateLimit {
    /// GitHub asks clients to wait at least this long when a limit comes with no other instructions.
    static let defaultWait: TimeInterval = 60

    /// When to try again if `response` was rate limited, or nil if it wasn't.
    static func retryDate(for response: HTTPURLResponse, body: Data, now: Date) -> Date? {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let exhausted = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        let limited =
            switch response.statusCode {
            case 429: true
            case 403:
                retryAfter != nil || exhausted
                    || String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains("rate limit")
            // GraphQL reports an exhausted budget as a successful response with an error in it.
            case 200: (try? JSONDecoder().decode(Failures.self, from: body))?.isRateLimited ?? false
            default: false
            }
        guard limited else { return nil }

        if let retryAfter { return now.addingTimeInterval(retryAfter) }
        if exhausted,
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init),
            reset > now.timeIntervalSince1970
        {
            return Date(timeIntervalSince1970: reset)
        }
        return now.addingTimeInterval(defaultWait)
    }

    private struct Failures: Decodable {
        struct Failure: Decodable { let type: String? }
        let errors: [Failure]?
        var isRateLimited: Bool { errors?.contains { $0.type == "RATE_LIMITED" } ?? false }
    }
}

/// Remembers a rate limit so requests made before it lifts never reach GitHub, where they
/// would fail anyway and can extend the penalty.
actor GitHubRateLimitGate {
    private var blockedUntil: Date?

    func check(now: Date) throws {
        guard let blockedUntil else { return }
        if now < blockedUntil { throw GitHubError.rateLimited(until: blockedUntil) }
        self.blockedUntil = nil
    }

    func block(until date: Date) {
        blockedUntil = max(blockedUntil ?? date, date)
    }
}
