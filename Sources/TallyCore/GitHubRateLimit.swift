import Foundation

/// Reads GitHub's rate limit signals from a response.
enum GitHubRateLimit {
    /// GitHub asks clients to wait at least this long when a limit comes with no other instructions.
    static let defaultWait: TimeInterval = 60

    /// No wait lasts longer than this, whatever the server says. GitHub's primary window is one hour;
    /// the margin covers a reset that lands just after it.
    static let maxWait: TimeInterval = 3600 + 60

    /// When to try again if `response` was rate limited, or nil if it wasn't.
    ///
    /// `Retry-After` is read as a number of seconds only. On a 403 the header's presence is what
    /// signals a limit, since no SSO or permission error carries it: a value that isn't a positive
    /// whole number (an HTTP date, `0`, `inf`) still limits, for the 60s default.
    static func retryDate(for response: HTTPURLResponse, body: Data, now: Date) -> Date? {
        let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After")
        let retryAfter = seconds(retryAfterHeader)
        let exhausted = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        let limited =
            switch response.statusCode {
            case 429: true
            case 403:
                // Only limits send Retry-After, whatever the message says. An exhausted budget is weaker
                // evidence (the last request of the budget can fail for any reason), so a message
                // that says something else (SSO, permissions) wins over it.
                if retryAfterHeader != nil {
                    true
                } else if let message = (try? JSONDecoder().decode(Message.self, from: body))?.message {
                    isRateLimitMessage(message)
                } else {
                    exhausted
                }
            // GraphQL reports an exhausted budget as a successful response with an error in it.
            case 200: (try? JSONDecoder().decode(Failures.self, from: body))?.isRateLimited ?? false
            default: false
            }
        guard limited else { return nil }

        let latest = now.addingTimeInterval(maxWait)
        if let retryAfter, retryAfter > 0 { return min(now.addingTimeInterval(retryAfter), latest) }
        if exhausted,
            let reset = seconds(response.value(forHTTPHeaderField: "X-RateLimit-Reset")),
            reset > now.timeIntervalSince1970
        {
            return min(Date(timeIntervalSince1970: reset), latest)
        }
        return now.addingTimeInterval(defaultWait)
    }

    /// A header holding a whole number of seconds. Signs, decimals, exponents, `inf` and `nan` are rejected.
    private static func seconds(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
            !header.isEmpty, header.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let value = TimeInterval(header), value.isFinite
        else { return nil }
        return value
    }

    /// GitHub's wording for primary, secondary and abuse-detection limits. Other messages that merely mention limits
    /// (org settings, limited tokens) are not rate limits.
    private static func isRateLimitMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("API rate limit exceeded")
            || message.localizedCaseInsensitiveContains("secondary rate limit")
            || message.localizedCaseInsensitiveContains("abuse detection")
    }

    private struct Message: Decodable { let message: String? }

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
        // A block further out than any wait can be means the clock moved back since it was set.
        if now < blockedUntil, blockedUntil.timeIntervalSince(now) <= GitHubRateLimit.maxWait {
            throw GitHubError.rateLimited(until: blockedUntil)
        }
        self.blockedUntil = nil
    }

    func block(until date: Date) {
        blockedUntil = max(blockedUntil ?? date, date)
    }
}
