import Foundation

/// Finds a GitHub token: a saved override first, then the `gh` CLI's login.
public actor TokenProvider {
    private let override: @Sendable () -> String?
    private let cli: @Sendable () -> String?
    private var cached: String?

    public init(
        override: @escaping @Sendable () -> String? = { nil },
        cli: @escaping @Sendable () -> String? = { GitHubCLI.authToken() }
    ) {
        self.override = override
        self.cli = cli
    }

    public func token() -> String? {
        if let saved = override(), !saved.isEmpty { return saved }
        if let cached { return cached }
        cached = cli()
        return cached
    }

    /// Forgets the CLI token so the next request reads it again.
    public func invalidate() {
        cached = nil
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
