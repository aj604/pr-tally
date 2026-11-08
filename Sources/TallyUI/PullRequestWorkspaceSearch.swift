import Foundation
import TallyCore

/// Searches only the PRs the current metric and filters already count, preserving their order.
struct PullRequestWorkspaceSearch {
    let query: String

    init(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool { !query.isEmpty }

    func results(in pullRequests: [PullRequest]) -> [PullRequest] {
        guard isActive else { return pullRequests }
        return pullRequests.filter { pr in
            [pr.title, pr.repository.nameWithOwner].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
