import XCTest
import Darwin
@testable import ModelQuotaCore

@MainActor
final class AppServerClientTests: XCTestCase {
    func fixture(_ mode: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["fake-server.py", "response-redacted.json"] {
            let source = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        try Data(mode.utf8).write(to: directory.appendingPathComponent("mode"))
        let executable = directory.appendingPathComponent("fake-server.py")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func assertStopped(_ executable: URL) throws {
        let directory = executable.deletingLastPathComponent()
        let pid = Int32(try String(contentsOf: directory.appendingPathComponent("pid")))!
        XCTAssertEqual(kill(pid, 0), -1, "Child must be reaped")
    }

    func testHandshakeReadAndGracefulShutdown() async throws {
        let executable = try fixture("normal")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(requestTimeout: 5)
        try await client.start(executable: executable)
        let snapshot = try await client.readUsage()
        XCTAssertEqual(snapshot.menuBarTitle, "Codex 3%")
        await client.stop()
        try assertStopped(executable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("exited").path))
    }

    func testLoginRequiredIsDistinctFromUnavailable() async throws {
        let executable = try fixture("signed-out")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(requestTimeout: 5)
        try await client.start(executable: executable)
        do { _ = try await client.readUsage(); XCTFail("Expected login error") }
        catch { XCTAssertEqual(error as? UsageError, .loginRequired) }
        await client.stop()
        try assertStopped(executable)
    }

    func testTimeoutEOFAndMalformedFramesFailAndCanReconnect() async throws {
        for (mode, expected) in [("timeout", UsageError.timedOut), ("crash", .connectionClosed), ("malformed", .invalidResponse)] {
            let executable = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
            let client = CodexAppServerClient(requestTimeout: 0.5)
            try await client.start(executable: executable)
            do { _ = try await client.readUsage(); XCTFail("Expected \(expected)") }
            catch { XCTAssertEqual(error as? UsageError, expected) }
            await client.stop()
            try assertStopped(executable)
            try Data("normal".utf8).write(to: executable.deletingLastPathComponent().appendingPathComponent("mode"))
            try await client.start(executable: executable)
            let snapshot = try await client.readUsage()
            XCTAssertEqual(snapshot.menuBarTitle, "Codex 3%")
            await client.stop()
            try assertStopped(executable)
        }
    }

    func testNotificationsAreDeliveredBetweenResponses() async throws {
        let executable = try fixture("notify")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(requestTimeout: 5)
        var notifications: [AccountNotification] = []
        client.onNotification = { notifications.append($0) }
        try await client.start(executable: executable)
        _ = try await client.readUsage()
        XCTAssertEqual(notifications, [.rateLimitsChanged(limitId: "codex")])
        await client.stop()
    }

    func testServerActionsAreRejected() async throws {
        let executable = try fixture("server-request")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(requestTimeout: 5)
        try await client.start(executable: executable)
        _ = try await client.readUsage()
        await client.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("rejected").path))
    }

    func testConcurrentStopsBothWaitForTheChildToExit() async throws {
        let executable = try fixture("slow-exit")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(requestTimeout: 5)
        try await client.start(executable: executable)
        _ = try await client.readUsage()
        let firstStop = Task { await client.stop() }
        try await Task.sleep(nanoseconds: 30_000_000)
        await client.stop()
        try assertStopped(executable)
        await firstStop.value
    }

    func testChildGetsUserInstallDirectoriesOnPathWhenLaunchedFromFinder() async throws {
        // Finder/Login Items launch apps with a minimal PATH; `#!/usr/bin/env node` launchers need more.
        let saved = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer { if let saved { setenv("PATH", saved, 1) } else { unsetenv("PATH") } }
        let executable = try fixture("normal")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let client = CodexAppServerClient(requestTimeout: 5)
        try await client.start(executable: executable)
        await client.stop()
        let childPath = try String(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("path"))
        let entries = childPath.split(separator: ":").map(String.init)
        let ownDirectory = executable.deletingLastPathComponent().path
        XCTAssertEqual(entries.first, ownDirectory, "The CLI's own directory comes first for nvm-style installs")
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin"] {
            XCTAssertTrue(entries.contains(directory), "\(directory) missing from \(childPath)")
        }
    }
}
