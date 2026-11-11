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
    /// GitHub says the saved token lacks the `repo` scope. Its refreshes succeed, so without this Settings would name
    /// the account as counted while every PR in a private repo is left out.
    var skipsPrivateRepos = false
    /// GitHub left this many SAML SSO organizations out of a search with the saved token, which isn't authorized for
    /// them. Its refreshes succeed too, and the count is short by their PRs.
    var unauthorizedSSOOrganizations = 0

    static let tokenAdvice =
        "To use a different account, save a classic token with the `repo` scope, authorized for any SSO orgs."

    /// Markdown, for the `repo` and `gh` code spans.
    var text: String {
        let source = usesSavedToken ? "the token saved in your keychain" : "your gh login"
        let advice = usesSavedToken ? "" : " \(Self.tokenAdvice)"
        if let scopeWarning {
            guard let orgs = ssoOrganizations else { return scopeWarning }
            return "\(scopeWarning) It also isn't authorized for \(orgs.named), whose PRs are left out too."
        }
        if let ssoWarning { return ssoWarning }
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
        return scopeWarning != nil || ssoWarning != nil
    }

    static let ssoFix = "To count them, find this token on GitHub under Settings > Developer settings > "
        + "Personal access tokens, choose Configure SSO, and authorize each organization."

    /// The SSO organizations left out, worded for a sentence. Held back when `scopeWarning` would be, for its reasons.
    private var ssoOrganizations: (named: String, them: String, their: String)? {
        guard usesSavedToken, unauthorizedSSOOrganizations > 0 else { return nil }
        switch state {
        case .checking, .unusable: return nil
        case .counting, .unconfirmed, .unknown: break
        }
        return unauthorizedSSOOrganizations == 1
            ? ("1 organization that uses SSO", "it", "its")
            : ("\(unauthorizedSSOOrganizations) organizations that use SSO", "them", "their")
    }

    private var ssoWarning: String? {
        guard let orgs = ssoOrganizations else { return nil }
        if case .counting(let login) = state {
            return "Counting PRs for @\(login), but not in \(orgs.named): the token saved in your keychain isn't "
                + "authorized for \(orgs.them), so GitHub's search leaves \(orgs.their) PRs out. \(Self.ssoFix)"
        }
        return "GitHub's search leaves out PRs in \(orgs.named): the token saved in your keychain isn't authorized "
            + "for \(orgs.them). \(Self.ssoFix)"
    }

    /// A rejection says more, and while checking a new token the finding may be about the old one.
    private var scopeWarning: String? {
        guard usesSavedToken, skipsPrivateRepos else { return nil }
        let fix = "Save a classic token with the `repo` scope, authorized for any SSO orgs, to count them."
        switch state {
        case .counting(let login):
            return "Counting only PRs in public repos for @\(login): the token saved in your keychain doesn't have "
                + "the `repo` scope, so private repos are left out. \(fix)"
        case .unconfirmed, .unknown:
            return "The token saved in your keychain doesn't have the `repo` scope, so PRs in private repos "
                + "won't be counted. \(fix)"
        case .checking, .unusable:
            return nil
        }
    }
}

extension TallyStore {
    /// `usesSavedToken` comes from the keychain, which Settings reads itself.
    func workflowLoginStatus(usesSavedToken: Bool) -> WorkflowLoginStatus {
        WorkflowLoginStatus(
            usesSavedToken: usesSavedToken, state: workflowLoginState, skipsPrivateRepos: savedTokenSkipsPrivateRepos,
            unauthorizedSSOOrganizations: savedTokenUnauthorizedSSOOrganizations)
    }

    private var workflowLoginState: WorkflowLoginStatus.State {
        if loginUnconfirmed, isRefreshing { return .checking }
        if let loginFailure { return .unusable(loginFailure) }
        if loginUnconfirmed { return .unconfirmed }
        return snapshot.map { .counting(login: $0.login) } ?? .unknown
    }
}

extension WorkflowLoginStatus {
    /// How a failure about the login itself is saved for the next launch. Nil for the rest, which are about GitHub
    /// or the network and say nothing about the login.
    static func savedName(of error: GitHubError) -> String? {
        switch error {
        case .noToken: "noToken"
        case .noGitHubCLI: "noGitHubCLI"
        case .unauthorized(.saved): "unauthorizedSaved"
        case .unauthorized(.githubCLI): "unauthorizedGitHubCLI"
        case .http, .graphQL, .rateLimited, .notGitHub: nil
        }
    }

    static func loginFailure(named name: String) -> GitHubError? {
        [GitHubError.noToken, .noGitHubCLI, .unauthorized(.saved), .unauthorized(.githubCLI)]
            .first { savedName(of: $0) == name }
    }
}
