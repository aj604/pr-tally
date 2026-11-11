import Foundation

/// Where a token came from, which decides what to do when GitHub rejects it.
public enum TokenSource: Sendable, Equatable {
    /// Saved in Settings. It takes precedence over the CLI, so logging in to `gh` again doesn't replace it.
    case saved
    /// The `gh` CLI's login.
    case githubCLI
}

/// What a classic token's searches leave out without an error: private repos, unless it has the `repo` scope
/// (`public_repo` and `repo:status` don't cover them), and organizations that use SAML single sign-on until it's
/// authorized for each. The count just comes up short either way, so the refresh can't tell.
public struct TokenReach: Equatable, Sendable {
    /// Nil when GitHub doesn't say, as for a fine-grained token, which has no scopes.
    public var readsPrivateRepos: Bool?
    /// How many SSO organizations GitHub left out of a search for the token's own PRs.
    public var unauthorizedSSOOrganizations: Int

    public init(readsPrivateRepos: Bool?, unauthorizedSSOOrganizations: Int = 0) {
        self.readsPrivateRepos = readsPrivateRepos
        self.unauthorizedSSOOrganizations = unauthorizedSSOOrganizations
    }
}

/// Asks GitHub what a token's searches can see, going by the headers on a search like the one a refresh makes:
/// `X-OAuth-Scopes`, sent on every answer to a classic token, and `X-GitHub-SSO`, sent when results from SSO
/// organizations the token isn't authorized for were left out.
public enum TokenScopes {
    public typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Nil when there's no answer to go by: a rejected token, a rate-limited search, or no network.
    public static func reach(
        _ token: String, load: Load = { try await URLSession.shared.data(for: $0) }
    ) async -> TokenReach? {
        var url = URLComponents(string: "https://api.github.com/search/issues")!
        url.queryItems = [URLQueryItem(name: "q", value: "is:pr author:@me"), URLQueryItem(name: "per_page", value: "1")]
        var request = URLRequest(url: url.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PRTally", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await load(request), let response = response as? HTTPURLResponse,
            response.statusCode == 200
        else { return nil }
        // GitHub documents no scopes header for fine-grained tokens. If one ever arrives empty, it isn't a classic
        // token missing `repo`, and saying so would send someone to swap a token that works.
        let scopes = isFineGrained(token) ? nil : response.value(forHTTPHeaderField: "X-OAuth-Scopes")
        return TokenReach(
            readsPrivateRepos: readsPrivateRepos(scopes: scopes),
            unauthorizedSSOOrganizations: unauthorizedSSOOrganizations(sso: response.value(forHTTPHeaderField: "X-GitHub-SSO")))
    }

    static func readsPrivateRepos(scopes header: String?) -> Bool? {
        // A classic token with no scopes gets the header, empty.
        guard let header else { return nil }
        return header.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "repo" }
    }

    /// Reads `partial-results; organizations=21955855,20582480`. Anything else, such as `required; url=…` on a
    /// request refused outright, isn't a search with results left out.
    static func unauthorizedSSOOrganizations(sso header: String?) -> Int {
        guard let header else { return 0 }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first?.lowercased() == "partial-results" else { return 0 }
        let ids = parts.dropFirst().first { $0.lowercased().hasPrefix("organizations=") }?.dropFirst("organizations=".count)
        let count = ids?.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count ?? 0
        // Results were left out even if the list didn't say whose.
        return max(count, 1)
    }

    /// GitHub's default new token is fine-grained, which belongs to one user or org and has permissions, not scopes.
    public static func isFineGrained(_ token: String) -> Bool {
        token.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("github_pat_")
    }
}

/// Finds a GitHub token: a saved override first, then the `gh` CLI's login.
public actor TokenProvider {
    /// How long a token read from the CLI is reused. Long enough that a refresh normally reads once,
    /// short enough that `gh auth switch` takes effect by the next refresh.
    static let cliLifetime: Duration = .seconds(60)

    /// After a failed read, how long before the CLI is tried again.
    static let retryFloor: Duration = .seconds(10)

    /// `gh` also fails when the keychain is locked or the process is killed, so a working token is
    /// kept through this many failed reads in a row before a missing login is believed.
    static let tolerableFailures = 2

    private let override: @Sendable () -> String?
    private let cli: @Sendable () -> String?
    private let cliInstalled: @Sendable () -> Bool
    private let lifetime: Duration
    private let retryFloor: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cached: String?
    private var readAt: ContinuousClock.Instant?
    private var failures = 0

    public init(
        override: @escaping @Sendable () -> String? = { nil },
        cli: @escaping @Sendable () -> String? = { GitHubCLI.authToken() }
    ) {
        self.init(
            override: override, cli: cli, cliInstalled: { GitHubCLI.executablePath() != nil },
            lifetime: Self.cliLifetime, retryFloor: Self.retryFloor, now: { .now }
        )
    }

    init(
        override: @escaping @Sendable () -> String?,
        cli: @escaping @Sendable () -> String?,
        cliInstalled: @escaping @Sendable () -> Bool = { true },
        lifetime: Duration,
        retryFloor: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.override = override
        self.cli = cli
        self.cliInstalled = cliInstalled
        self.lifetime = lifetime
        self.retryFloor = retryFloor
        self.now = now
    }

    public func token() -> String? {
        credential()?.token
    }

    /// The token to use, and where it came from.
    func credential() -> (token: String, source: TokenSource)? {
        if let saved = override(), !saved.isEmpty { return (saved, .saved) }
        let current = now()
        if let readAt, current < readAt + (failures == 0 ? lifetime : retryFloor) {
            return cached.map { ($0, .githubCLI) }
        }
        readAt = current
        if let fresh = cli() {
            cached = fresh
            failures = 0
        } else {
            failures += 1
            if failures > Self.tolerableFailures { cached = nil }
        }
        return cached.map { ($0, .githubCLI) }
    }

    /// Why there's no token: `gh` has no login, or there's no `gh` to ask. Telling someone without `gh`
    /// to run `gh auth login` sends them nowhere.
    func missingLogin() -> GitHubError {
        cliInstalled() ? .noToken : .noGitHubCLI
    }

    /// Forgets the CLI token so the next request reads it again.
    public func invalidate() {
        cached = nil
        readAt = nil
        failures = 0
    }
}

public enum GitHubCLI {
    /// Finder-launched apps get a minimal PATH, so look where package managers install `gh`.
    static func searchPaths(home: String = NSHomeDirectory(), user: String = NSUserName()) -> [String] {
        [
            // Homebrew, Apple silicon then Intel, and the system: the places looked before the rest were
            // added, kept first so nobody already using `gh` gets a different one.
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
            // MacPorts.
            "/opt/local/bin/gh",
            // Nix: a user profile, home-manager under nix-darwin, then nix-darwin's system packages.
            "\(home)/.nix-profile/bin/gh", "/etc/profiles/per-user/\(user)/bin/gh", "/run/current-system/sw/bin/gh",
            // A release unpacked by hand, or installed by a tool that links into it.
            "\(home)/.local/bin/gh",
        ]
    }

    /// Where `gh` is, if it's in any of `paths`.
    static func executablePath(in paths: [String] = searchPaths()) -> String? {
        paths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    public static func authToken() -> String? {
        guard let path = executablePath() else { return nil }
        return run(path, arguments: ["auth", "token"])
    }

    static func run(_ path: String, arguments: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // A stuck keychain prompt must not hang refreshes forever.
        let watchdog = DispatchWorkItem { [process] in process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
