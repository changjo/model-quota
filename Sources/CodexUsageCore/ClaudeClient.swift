import Foundation

@MainActor
public protocol ClaudeUsageService: AnyObject {
    func readUsage() async throws -> ClaudeUsageSnapshot
}

@MainActor
public final class ClaudeClient: ClaudeUsageService {
    public var customPath: String
    private let timeoutSeconds: TimeInterval

    public init(customPath: String = "", timeoutSeconds: TimeInterval = 15) {
        self.customPath = customPath
        self.timeoutSeconds = timeoutSeconds
    }

    nonisolated public static func locateClaude(customPath: String = "") -> URL? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let candidates = [
            "~/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]

        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnv.components(separatedBy: ":") {
                let fullPath = (directory as NSString).appendingPathComponent("claude")
                if FileManager.default.isExecutableFile(atPath: fullPath) {
                    return URL(fileURLWithPath: fullPath)
                }
            }
        }

        return nil
    }

    public func readUsage() async throws -> ClaudeUsageSnapshot {
        guard let executable = Self.locateClaude(customPath: customPath) else {
            throw UsageError.cliNotFound
        }

        let timeout = self.timeoutSeconds

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executable
            process.arguments = [
                "--print",
                "--verbose",
                "--safe-mode",
                "--input-format=stream-json",
                "--output-format=stream-json"
            ]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var environment = ProcessInfo.processInfo.environment
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let localBin = (homeDir as NSString).appendingPathComponent(".local/bin")
            let standardPaths = "\(localBin):/opt/homebrew/bin:/usr/local/bin"
            if let path = environment["PATH"] {
                if !path.contains("/opt/homebrew/bin") || !path.contains(localBin) {
                    environment["PATH"] = "\(standardPaths):" + path
                }
            } else {
                environment["PATH"] = "\(standardPaths):/usr/bin:/bin"
            }
            process.environment = environment

            do {
                try process.run()
            } catch {
                throw UsageError.startFailed
            }

            // Write the get_usage control request to stdin and close stdin
            let request = "{\"type\":\"control_request\",\"request_id\":\"1\",\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}\n"
            if let data = request.data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
            }

            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()
            timeoutTask.cancel()

            if process.terminationStatus != 0 && outputData.isEmpty {
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                if stderrString.contains("auth") || stderrString.contains("login") {
                    throw UsageError.loginRequired
                }
                throw UsageError.requestFailed
            }

            guard !outputData.isEmpty else {
                throw UsageError.invalidResponse
            }

            return try ClaudeUsageSnapshot.decode(from: outputData)
        }.value
    }
}
