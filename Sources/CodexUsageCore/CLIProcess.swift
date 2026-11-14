import Foundation
import Darwin

public struct CLIProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Runs a one-shot CLI command. Both output pipes are drained concurrently so a chatty child can
/// never block on a full pipe buffer, a timeout surfaces as `UsageError.timedOut`, and task
/// cancellation terminates the child instead of leaving it running in the background.
public enum CLIProcess {
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Prepends the usual user install locations that a GUI app's minimal `PATH` lacks, without
    /// duplicating directories that are already present.
    /// `executableDirectory` goes first: nvm/volta-style installs keep `node` next to the CLI.
    public static func environment(base: [String: String], home: String,
                                   executableDirectory: String? = nil) -> [String: String] {
        var environment = base
        let inherited = base["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin"
        let existing = inherited.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var front: [String] = []
        for directory in [executableDirectory].compactMap({ $0 }) + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        where directory.hasPrefix("/") && !front.contains(directory) && !existing.contains(directory) {
            front.append(directory)
        }
        environment["PATH"] = (front + existing).joined(separator: ":")
        return environment
    }

    /// Combined stdout + stderr limit; a usage report is a few KB, so more means a wrong executable.
    public static let defaultOutputLimit = 4 * 1024 * 1024

    /// Children always start in `/` (as a Finder launch would), never in whatever directory the
    /// app was started from, so a CLI cannot pick up an untrusted project's configuration.
    static let workingDirectory = URL(fileURLWithPath: "/", isDirectory: true)

    public static func run(executable: URL,
                           arguments: [String],
                           stdin: Data? = nil,
                           timeout: TimeInterval,
                           killGrace: TimeInterval = 1,
                           outputLimit: Int = defaultOutputLimit) async throws -> CLIProcessResult {
        _ = ignoreSIGPIPE
        let execution = Execution(executable: executable, arguments: arguments, stdin: stdin,
                                  timeout: timeout, killGrace: killGrace, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { execution.start($0) }
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class Execution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinData: Data?
    private let timeout: TimeInterval
    private let killGrace: TimeInterval
    private let outputLimit: Int

    // Guarded by `lock`.
    private var continuation: CheckedContinuation<CLIProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutOpen = true
    private var stderrOpen = true
    private var launched = false
    private var exited = false
    private var timedOut = false
    private var cancelled = false
    private var overflowed = false
    private var finished = false

    init(executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval, killGrace: TimeInterval,
         outputLimit: Int) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = CLIProcess.workingDirectory
        stdinData = stdin
        self.timeout = timeout
        self.killGrace = killGrace
        self.outputLimit = outputLimit
    }

    func start(_ continuation: CheckedContinuation<CLIProcessResult, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        process.environment = CLIProcess.environment(
            base: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
            executableDirectory: process.executableURL?.deletingLastPathComponent().path)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = stdinData == nil ? nil : Pipe()
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData, isStdout: true, handle: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData, isStdout: false, handle: handle)
        }
        process.terminationHandler = { [weak self] _ in self?.processExited() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            complete(forcedError: UsageError.startFailed)
            return
        }

        lock.lock()
        launched = true
        let cancelledBeforeLaunch = cancelled
        lock.unlock()
        if cancelledBeforeLaunch { terminate() }

        if let stdinPipe, let stdinData {
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.timeoutFired() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = launched && !exited
        lock.unlock()
        if shouldTerminate { terminate() }
    }

    private func received(_ data: Data, isStdout: Bool, handle: FileHandle) {
        lock.lock()
        if data.isEmpty {
            if isStdout { stdoutOpen = false } else { stderrOpen = false }
        } else if isStdout {
            stdout.append(data)
        } else {
            stderr.append(data)
        }
        let overflow = !overflowed && stdout.count + stderr.count > outputLimit
        if overflow { overflowed = true }
        let ready = exited && !stdoutOpen && !stderrOpen
        lock.unlock()
        if data.isEmpty { handle.readabilityHandler = nil }
        if overflow {
            terminate()
            complete(forcedError: UsageError.invalidResponse)
        } else if ready {
            complete()
        }
    }

    private func processExited() {
        lock.lock()
        exited = true
        let ready = !stdoutOpen && !stderrOpen
        lock.unlock()
        if ready {
            complete()
        } else {
            // A grandchild may inherit the pipes and keep them open; never wait on it indefinitely.
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [weak self] in self?.complete() }
        }
    }

    private func timeoutFired() {
        lock.lock()
        let shouldTerminate = !finished && !exited
        if shouldTerminate { timedOut = true }
        lock.unlock()
        if shouldTerminate { terminate() }
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            guard process.isRunning else { return }
            // The child leads its own process group, so -pid also reaches helpers that ignored SIGTERM.
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func complete(forcedError: Error? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result: Result<CLIProcessResult, Error>
        if let forcedError {
            result = .failure(forcedError)
        } else if cancelled {
            result = .failure(CancellationError())
        } else if timedOut {
            result = .failure(UsageError.timedOut)
        } else {
            result = .success(CLIProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr))
        }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        continuation?.resume(with: result)
    }
}
