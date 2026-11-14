import Foundation

@MainActor
public protocol ClaudeUsageService: AnyObject {
    func readUsage() async throws -> ClaudeUsageSnapshot
}

@MainActor
public final class ClaudeClient: ClaudeUsageService {
    public var customPath: String
    private let timeoutSeconds: TimeInterval

    /// A `get_usage` control request; it reads quota state and never starts a model turn.
    static let usageRequest = Data(#"{"type":"control_request","request_id":"1","request":{"subtype":"get_usage","skip_behaviors":true}}"#.utf8 + [0x0A])

    public init(customPath: String = "", timeoutSeconds: TimeInterval = 15) {
        self.customPath = customPath
        self.timeoutSeconds = timeoutSeconds
    }

    nonisolated public static func locateClaude(customPath: String = "") -> URL? {
        try? ExecutableLocator.resolve(.claude, customPath: customPath)
    }

    public func readUsage() async throws -> ClaudeUsageSnapshot {
        guard let executable = Self.locateClaude(customPath: customPath) else {
            throw UsageError.cliNotFound
        }
        let result = try await CLIProcess.run(
            executable: executable,
            arguments: ["--print", "--verbose", "--safe-mode",
                        "--input-format=stream-json", "--output-format=stream-json"],
            stdin: Self.usageRequest,
            timeout: timeoutSeconds
        )
        if result.status != 0 && result.stdout.isEmpty {
            throw UsageError.classifyCLIFailure(String(decoding: result.stderr, as: UTF8.self))
        }
        guard !result.stdout.isEmpty else { throw UsageError.invalidResponse }
        return try ClaudeUsageSnapshot.decode(from: result.stdout)
    }
}
