// Disposable protocol probe for Codex CLI 0.155.0; not the app client.
// Usage: swift rate-limits-probe.swift /absolute/path/to/codex [watch-seconds]
import Foundation
import Darwin

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func sanitized(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
        return object.mapValues { sanitized($0) }.map { key, value in
            (key, (key == "accountId" || (key == "id" && value is String))
                && !(value is NSNull) ? "<redacted>" : value)
        }.reduce(into: [String: Any]()) { $0[$1.0] = $1.1 }
    }
    if let array = value as? [Any] { return array.map(sanitized) }
    return value
}

func show(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: sanitized(value), options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

final class Probe {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var buffer = Data()
    var notificationCount = 0

    init(executable: String) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProbeError("Codex CLI not found: provide an absolute executable path")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        // Unrelated startup diagnostics are intentionally not recorded by this probe.
        process.standardError = FileHandle.nullDevice
        try process.run()
        log("App Server PID: \(process.processIdentifier)")
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        func waitBriefly() {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        }
        waitBriefly()
        if process.isRunning { process.terminate(); waitBriefly() }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        log("App Server exited: \(process.terminationStatus)")
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func next(until deadline: TimeInterval) throws -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ProbeError("Invalid JSON-RPC object")
                }
                return object
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ProbeError("stdout poll failed")
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 { throw ProbeError("App Server closed stdout") }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProbeError("stdout read failed")
            }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.count > 4 * 1024 * 1024 { throw ProbeError("JSONL message exceeded probe limit") }
        }
    }

    func handle(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                // This read-only probe does not implement server-initiated actions.
                try send(["id": id, "error": ["code": -32601, "message": "Unsupported by usage probe"]])
            } else if method == "account/rateLimits/updated" {
                notificationCount += 1
                try show(message)
            }
        }
    }

    func response(id: Int) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while let message = try next(until: deadline) {
            if message["id"] as? Int == id && message["method"] == nil {
                if let error = message["error"] as? [String: Any] {
                    throw ProbeError("JSON-RPC error \(error["code"] ?? "?"): \(error["message"] ?? "Unknown error")")
                }
                guard message["result"] is [String: Any] else { throw ProbeError("Missing result") }
                return message
            }
            try handle(message)
        }
        throw ProbeError("Timed out waiting for response \(id)")
    }
}

signal(SIGPIPE, SIG_IGN)
do {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw ProbeError("Usage: rate-limits-probe /absolute/path/to/codex [watch-seconds]")
    }
    let watch = CommandLine.arguments.count == 3 ? Double(CommandLine.arguments[2]) : 0
    guard let watch, watch.isFinite, (0...300).contains(watch) else {
        throw ProbeError("watch-seconds must be between 0 and 300")
    }
    let probe = try Probe(executable: CommandLine.arguments[1])
    defer { probe.stop() }
    try probe.send(["id": 1, "method": "initialize", "params": [
        "clientInfo": ["name": "codex_usage_probe", "title": "Codex Usage Probe", "version": "0.1.0"],
        "capabilities": ["experimentalApi": false, "requestAttestation": false]
    ]])
    _ = try probe.response(id: 1)
    log("initialize: OK")
    try probe.send(["method": "initialized"])
    try probe.send(["id": 2, "method": "account/rateLimits/read"])
    try show(probe.response(id: 2))
    if watch > 0 {
        log("Watching notifications for \(watch)s; no polling or model requests")
        let deadline = ProcessInfo.processInfo.systemUptime + watch
        while let message = try probe.next(until: deadline) { try probe.handle(message) }
        log("Rate-limit notifications observed: \(probe.notificationCount)")
    }
} catch {
    log("Probe failed: \(error)")
    exit(1)
}
