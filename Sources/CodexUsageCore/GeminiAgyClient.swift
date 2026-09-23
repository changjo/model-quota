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
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let candidates = [
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "~/.local/bin/agy"
        ]

        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Search PATH environment variable
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnv.components(separatedBy: ":") {
                let fullPath = (directory as NSString).appendingPathComponent("agy")
                if FileManager.default.isExecutableFile(atPath: fullPath) {
                    return URL(fileURLWithPath: fullPath)
                }
            }
        }

        return nil
    }

    public func readUsage() async throws -> GeminiUsageSnapshot {
        guard let executable = Self.locateAgy(customPath: customPath) else {
            throw UsageError.cliNotFound
        }

        let timeout = self.timeoutSeconds

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executable
            process.arguments = ["--output-format", "json", "--print", "/usage"]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var environment = ProcessInfo.processInfo.environment
            if let path = environment["PATH"] {
                if !path.contains("/opt/homebrew/bin") {
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
                }
            } else {
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            }
            process.environment = environment

            do {
                try process.run()
            } catch {
                throw UsageError.startFailed
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                if stderrString.contains("auth") || stderrString.contains("login") {
                    throw UsageError.loginRequired
                }
                throw UsageError.requestFailed
            }

            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard !outputData.isEmpty else {
                throw UsageError.invalidResponse
            }

            do {
                return try GeminiUsageSnapshot.decode(from: outputData)
            } catch {
                throw UsageError.invalidResponse
            }
        }.value
    }
}
