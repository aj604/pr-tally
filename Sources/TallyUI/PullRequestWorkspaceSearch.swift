import Foundation
import TallyCore

/// Searches only the PRs the current metric and filters already count, preserving their order.
struct PullRequestWorkspaceSearch {
    let query: String

    init(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool { !query.isEmpty }

    /// The field's placeholder says what the list holds ("Search 5 PRs opened"), so the count needs no row of its own
    /// and the metric stays named while nothing is typed.
    static func prompt(count: Int, metric: PRMetric) -> String {
        "Search \(count.formatted()) \(noun(count, metric))"
    }

    /// While searching, how many of the list match ("2 of 5"), short enough to sit inside the search row. Nothing
    /// while the field is blank, as the placeholder already gives the count.
    func matchText(_ matches: Int, of total: Int) -> String? {
        isActive ? "\(matches.formatted()) of \(total.formatted())" : nil
    }

    /// `matchText` read out in full, since "2 of 5" alone doesn't say of what.
    func matchAccessibilityLabel(_ matches: Int, of total: Int, metric: PRMetric) -> String? {
        isActive ? "\(matches.formatted()) of \(total.formatted()) \(Self.noun(total, metric)) match" : nil
    }

    private static func noun(_ count: Int, _ metric: PRMetric) -> String {
        count == 1 ? (metric == .opened ? "PR opened" : "PR merged") : metric.noun
    }

    func results(in pullRequests: [PullRequest]) -> [PullRequest] {
        guard isActive else { return pullRequests }
        if let reference = Reference(query) { return pullRequests.filter { reference.matches($0) } }
        return pullRequests.filter { pr in
            [pr.title, pr.repository.nameWithOwner].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Explicit references are exact; ordinary text keeps its title/repository substring behavior.
    private enum Reference {
        case number(Int, repository: String?)
        case url(URL)

        init?(_ query: String) {
            if let url = URL(string: query), Self.number(in: url) != nil {
                self = .url(url)
                return
            }
            let parts = query.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, let number = Self.number(String(parts[1])) else { return nil }
            let repository = String(parts[0])
            guard repository.isEmpty || repository.split(separator: "/", omittingEmptySubsequences: false).count == 2
            else { return nil }
            self = .number(number, repository: repository.isEmpty ? nil : repository)
        }

        func matches(_ pr: PullRequest) -> Bool {
            guard let number = Self.number(in: pr.url) else { return false }
            switch self {
            case .number(let expected, let repository):
                return number == expected && (repository.map {
                    $0.caseInsensitiveCompare(pr.repository.nameWithOwner) == .orderedSame
                } ?? true)
            case .url(let expected):
                // Browser query parameters and discussion anchors do not change the PR's identity.
                return expected.host?.lowercased() == pr.url.host?.lowercased() && expected.port == pr.url.port
                    && Self.path(expected).caseInsensitiveCompare(Self.path(pr.url)) == .orderedSame
            }
        }

        private static func number(_ text: String) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text), value > 0
            else { return nil }
            return value
        }

        private static func number(in url: URL) -> Int? {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            let parts = path(url).split(separator: "/")
            guard parts.count >= 4, parts[parts.count - 2] == "pull" else { return nil }
            return number(String(parts[parts.count - 1]))
        }

        private static func path(_ url: URL) -> String {
            let parts = url.path.split(separator: "/")
            // Files changed, commits and checks are pages within the same PR.
            if parts.count >= 4, parts[2] == "pull", number(String(parts[3])) != nil {
                return parts.prefix(4).joined(separator: "/")
            }
            return parts.joined(separator: "/")
        }
    }
}
