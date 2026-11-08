import TallyCore

/// Repository choices from the current metric, day and funnel, before repository or text filtering.
struct PullRequestWorkspaceRepositories {
    struct Option: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    let options: [Option]
    let totalCount: Int

    init(_ pullRequests: [PullRequest], selected: String? = nil) {
        var counts = Dictionary(grouping: pullRequests, by: \.repository.nameWithOwner).mapValues(\.count)
        // Keep the selection visible and removable when a different day has no PRs in this repository.
        if let selected, counts[selected] == nil { counts[selected] = 0 }
        options = counts.map { Option(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
        totalCount = pullRequests.count
    }
}
