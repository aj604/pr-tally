import TallyCore

/// What Settings says about the GitHub login: which account the numbers are for, once a refresh has shown it,
/// or why it can't be used. Which kind of login is in use isn't enough on its own: "Using your gh login" is
/// wrong when `gh` is missing or logged out, and after saving a token nothing said whether GitHub took it.
struct WorkflowLoginStatus: Equatable {
    enum State: Equatable {
        /// A token was just saved or cleared, and the refresh trying it is under way.
        case checking
        /// A token was saved or cleared, and no refresh has succeeded with it yet for some other reason, such as
        /// being offline. The numbers on screen are still the replaced login's.
        case unconfirmed
        /// GitHub turned the login down, or there is none to use.
        case unusable(GitHubError)
        /// The latest numbers were counted for this account with the login in use.
        case counting(login: String)
        /// No numbers yet, such as on a first launch, and nothing has gone wrong.
        case unknown
    }

    let usesSavedToken: Bool
    let state: State

    static let tokenAdvice =
        "To use a different account, save a classic token with the `repo` scope, authorized for any SSO orgs."

    /// Markdown, for the `repo` and `gh` code spans.
    var text: String {
        let source = usesSavedToken ? "the token saved in your keychain" : "your gh login"
        let advice = usesSavedToken ? "" : " \(Self.tokenAdvice)"
        switch state {
        case .checking:
            return usesSavedToken ? "Checking the new token with GitHub…" : "Checking your gh login with GitHub…"
        case .unconfirmed:
            return "Using \(source). Not checked yet: it will be on the next refresh that succeeds."
        case .unusable(.unauthorized(.saved)):
            return "GitHub rejected the token saved in your keychain. Save a new one, or clear it to use your gh login."
        case .unusable(.unauthorized(.githubCLI)):
            return "GitHub rejected your gh login. Run `gh auth login` to sign in again, or save a token."
        case .unusable(.noGitHubCLI):
            return "No token saved, and the `gh` CLI isn't installed where PR Tally looks. "
                + "Save a classic token with the `repo` scope, authorized for any SSO orgs."
        case .unusable:
            return "No token saved, and `gh` isn't logged in. Run `gh auth login`, or save a classic token "
                + "with the `repo` scope, authorized for any SSO orgs."
        case .counting(let login):
            return "Counting PRs for @\(login) with \(source).\(advice)"
        case .unknown:
            return "Using \(source).\(advice)"
        }
    }

    var isWarning: Bool {
        if case .unusable = state { return true }
        return false
    }
}

extension TallyStore {
    /// `usesSavedToken` comes from the keychain, which Settings reads itself.
    func workflowLoginStatus(usesSavedToken: Bool) -> WorkflowLoginStatus {
        WorkflowLoginStatus(usesSavedToken: usesSavedToken, state: workflowLoginState)
    }

    private var workflowLoginState: WorkflowLoginStatus.State {
        // Checked first: until this refresh ends, the failure on record is the replaced login's.
        if loginUnconfirmed, isRefreshing { return .checking }
        if let error = lastFailure as? GitHubError, Self.isLoginFailure(error) { return .unusable(error) }
        if loginUnconfirmed { return .unconfirmed }
        return snapshot.map { .counting(login: $0.login) } ?? .unknown
    }

    /// Failures that are about the login itself, rather than GitHub or the network, which say nothing about it.
    private static func isLoginFailure(_ error: GitHubError) -> Bool {
        switch error {
        case .noToken, .noGitHubCLI, .unauthorized: true
        case .http, .graphQL, .rateLimited, .notGitHub: false
        }
    }
}
