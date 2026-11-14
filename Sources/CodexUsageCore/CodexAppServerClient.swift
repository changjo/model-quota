import Foundation
import Darwin

public enum AccountNotification: Equatable, Sendable {
    case rateLimitsChanged(limitId: String?)
    case accountChanged
    case accountUpdated
}

@MainActor
public protocol AppServerConnection: AnyObject {
    var isConnected: Bool { get }
    var onNotification: ((AccountNotification) -> Void)? { get set }
    var onDisconnect: ((UsageError) -> Void)? { get set }
    func start(executable: URL) async throws
    func readUsage() async throws -> UsageSnapshot
    func stop() async
}

@MainActor
public final class CodexAppServerClient: AppServerConnection {
    public var onNotification: ((AccountNotification) -> Void)?
    public var onDisconnect: ((UsageError) -> Void)?
    public var isConnected: Bool { ready && process?.isRunning == true }

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var session = UUID()
    private var ready = false
    private var failed = false
    private var buffer = Data()
    private var nextID = 0
    private var cleanup: Task<Void, Never>?
    private let requestTimeout: TimeInterval
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]

    public init(requestTimeout: TimeInterval = 20) {
        self.requestTimeout = requestTimeout
        // A closed child stdin must fail the write rather than terminate this app.
        signal(SIGPIPE, SIG_IGN)
    }

    public func start(executable: URL) async throws {
        await stop()
        try Task.checkCancellation()
        session = UUID()
        let current = session
        failed = false
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process = child
        input = stdin
        output = stdout
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        // Apps launched from Finder get a minimal PATH; npm-installed codex needs `env node`.
        child.environment = CLIProcess.environment(base: ProcessInfo.processInfo.environment,
                                                   home: NSHomeDirectory(),
                                                   executableDirectory: executable.deletingLastPathComponent().path)
        child.currentDirectoryURL = CLIProcess.workingDirectory
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(data, session: current) }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.session == current else { return }
                self.fail(self.ready ? .connectionClosed : .startFailed)
            }
        }
        do {
            try child.run()
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "codex_usage_menu_bar", "title": "Codex Usage", "version": "0.1.0"],
                "capabilities": ["experimentalApi": false, "requestAttestation": false]
            ])
            try send(["method": "initialized"])
            ready = true
        } catch {
            await stop()
            if error is CancellationError { throw error }
            throw UsageError.startFailed
        }
    }

    public func readUsage() async throws -> UsageSnapshot {
        guard isConnected else { throw UsageError.connectionClosed }
        struct AccountResponse: Decodable {
            struct Account: Decodable { let type: String }
            let account: Account?
        }
        let accountData = try await request("account/read", params: ["refreshToken": false])
        guard let state = try? JSONDecoder().decode(AccountResponse.self, from: accountData) else {
            throw UsageError.invalidResponse
        }
        guard let account = state.account else { throw UsageError.loginRequired }
        if account.type == "apiKey" || account.type == "amazonBedrock" { throw UsageError.unsupportedAccount }
        // Omit optional params for compatibility; no reset-credit consumption or model calls.
        let data = try await request("account/rateLimits/read")
        guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
            throw UsageError.invalidResponse
        }
        guard !snapshot.quotas.isEmpty else { throw UsageError.unavailable }
        return snapshot
    }

    public func stop() async {
        if let cleanup { await cleanup.value; return }
        session = UUID() // Ignore queued callbacks from the old process.
        ready = false
        failed = true
        finishAll(UsageError.stopped)
        let child = process
        let stdout = output
        process = nil
        output = nil
        stdout?.fileHandleForReading.readabilityHandler = nil
        child?.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        buffer.removeAll(keepingCapacity: false)
        let operation = Task {
            if let child, child.processIdentifier > 0 {
                await waitForExit(child, seconds: 0.4)
                if child.isRunning {
                    child.terminate()
                    await waitForExit(child, seconds: 0.6)
                }
                if child.isRunning {
                    // The child leads its own process group; -pid also reaches stuck helpers.
                    kill(-child.processIdentifier, SIGKILL)
                    kill(child.processIdentifier, SIGKILL)
                    // Poll instead of waitUntilExit(), which would spin the main run loop.
                    await waitForExit(child, seconds: 1)
                }
            }
            // The read handler is already detached; let the pipe close on deallocation rather
            // than racing a handler that may still be inside `availableData`.
            _ = stdout
        }
        cleanup = operation
        await operation.value
        cleanup = nil
    }

    private func waitForExit(_ child: Process, seconds: TimeInterval) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            // Cleanup must finish even if the calling refresh task was cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
    }

    private func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard process?.isRunning == true, !failed else { throw UsageError.connectionClosed }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.fail(.timedOut)
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout)
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                do { try send(message) }
                catch { fail(.connectionClosed) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let handle = input?.fileHandleForWriting else { throw UsageError.connectionClosed }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func receive(_ data: Data, session current: UUID) {
        guard session == current, !failed else { return }
        guard !data.isEmpty else { fail(ready ? .connectionClosed : .startFailed); return }
        buffer.append(data)
        let maximum = 4 * 1024 * 1024
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard line.count <= maximum else { fail(.invalidResponse); return }
            if line.isEmpty { continue }
            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw UsageError.invalidResponse
                }
                try route(message)
            } catch { fail(.invalidResponse); return }
            if failed { return }
        }
        if buffer.count > maximum { fail(.invalidResponse) }
    }

    private func route(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                try send(["id": id, "error": ["code": -32601, "message": "Unsupported by usage client"]])
            } else if method == "account/updated" {
                onNotification?(.accountUpdated)
            } else if method == "account/rateLimits/updated" {
                let params = message["params"] as? [String: Any]
                let bucket = params?["rateLimits"] as? [String: Any]
                onNotification?(.rateLimitsChanged(limitId: bucket?["limitId"] as? String))
            }
            return
        }
        guard let id = message["id"] as? Int, pending[id] != nil else { return }
        if message["error"] != nil {
            finish(id, result: .failure(UsageError.requestFailed))
        } else if let result = message["result"] as? [String: Any] {
            finish(id, result: .success(try JSONSerialization.data(withJSONObject: result)))
        } else {
            finish(id, result: .failure(UsageError.invalidResponse))
        }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func finishAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }

    private func fail(_ error: UsageError) {
        guard !failed else { return }
        failed = true
        ready = false
        output?.fileHandleForReading.readabilityHandler = nil
        finishAll(error)
        onDisconnect?(error)
    }
}
