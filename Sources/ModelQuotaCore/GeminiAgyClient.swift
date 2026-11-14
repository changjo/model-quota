import Foundation

@MainActor
public protocol GeminiUsageService: AnyObject {
    func readUsage() async throws -> GeminiUsageSnapshot
}

@MainActor
public final class GeminiAgyClient: GeminiUsageService {
    public var customPath: String
    private let timeoutSeconds: TimeInterval

    public init(customPath: String = "", timeoutSeconds: TimeInterval = 15) {
        self.customPath = customPath
        self.timeoutSeconds = timeoutSeconds
    }

    nonisolated public static func locateAgy(customPath: String = "") -> URL? {
        try? ExecutableLocator.resolve(.gemini, customPath: customPath)
    }

    public func readUsage() async throws -> GeminiUsageSnapshot {
        guard let executable = Self.locateAgy(customPath: customPath) else {
            throw UsageError.cliNotFound
        }
        let result = try await CLIProcess.run(executable: executable,
                                              arguments: ["--output-format", "json", "--print", "/usage"],
                                              timeout: timeoutSeconds)
        guard result.status == 0 else {
            throw GeminiUsageSnapshot.failure(stdout: result.stdout, stderr: result.stderr)
        }
        guard !result.stdout.isEmpty else { throw UsageError.invalidResponse }
        do {
            return try GeminiUsageSnapshot.decode(from: result.stdout)
        } catch {
            throw UsageError.invalidResponse
        }
    }
}
