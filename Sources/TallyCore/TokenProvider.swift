import Foundation

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
            override: override, cli: cli, lifetime: Self.cliLifetime, retryFloor: Self.retryFloor,
            now: { .now }
        )
    }

    init(
        override: @escaping @Sendable () -> String?,
        cli: @escaping @Sendable () -> String?,
        lifetime: Duration,
        retryFloor: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.override = override
        self.cli = cli
        self.lifetime = lifetime
        self.retryFloor = retryFloor
        self.now = now
    }

    public func token() -> String? {
        if let saved = override(), !saved.isEmpty { return saved }
        let current = now()
        if let readAt, current < readAt + (failures == 0 ? lifetime : retryFloor) { return cached }
        readAt = current
        if let fresh = cli() {
            cached = fresh
            failures = 0
        } else {
            failures += 1
            if failures > Self.tolerableFailures { cached = nil }
        }
        return cached
    }

    /// Forgets the CLI token so the next request reads it again.
    public func invalidate() {
        cached = nil
        readAt = nil
        failures = 0
    }
}

public enum GitHubCLI {
    /// Finder-launched apps get a minimal PATH, so look where `gh` is normally installed.
    private static let searchPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    public static func authToken() -> String? {
        let manager = FileManager.default
        guard let path = searchPaths.first(where: manager.isExecutableFile(atPath:)) else { return nil }
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
