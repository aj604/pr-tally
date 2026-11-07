import Foundation

/// Where a token came from, which decides what to do when GitHub rejects it.
public enum TokenSource: Sendable, Equatable {
    /// Saved in Settings. It takes precedence over the CLI, so logging in to `gh` again doesn't replace it.
    case saved
    /// The `gh` CLI's login.
    case githubCLI
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
            // Homebrew, Apple silicon then Intel.
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh",
            // MacPorts.
            "/opt/local/bin/gh",
            // Nix: a user profile, home-manager under nix-darwin, then nix-darwin's system packages.
            "\(home)/.nix-profile/bin/gh", "/etc/profiles/per-user/\(user)/bin/gh", "/run/current-system/sw/bin/gh",
            // A release unpacked by hand, or installed by a tool that links into it.
            "\(home)/.local/bin/gh",
            "/usr/bin/gh",
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
