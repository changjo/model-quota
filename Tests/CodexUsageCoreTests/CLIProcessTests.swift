import XCTest
@testable import CodexUsageCore

final class CLIProcessTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-process-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLargeStdoutAndStderrDoNotDeadlock() async throws {
        // Far beyond the 64KB pipe buffer on both streams at once.
        let url = try script("""
        /usr/bin/head -c 400000 /dev/zero | /usr/bin/tr '\\0' 'o'
        /usr/bin/head -c 400000 /dev/zero | /usr/bin/tr '\\0' 'e' 1>&2
        exit 0
        """)
        let started = Date()
        let result = try await CLIProcess.run(executable: url, arguments: [], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 400_000)
        XCTAssertEqual(result.stderr.count, 400_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testStdinIsDeliveredAndClosed() async throws {
        let url = try script("/bin/cat")
        let result = try await CLIProcess.run(executable: url, arguments: [], stdin: Data("hello\n".utf8), timeout: 5)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }

    func testTimeoutTerminatesAndReportsTimedOut() async throws {
        let url = try script("/bin/sleep 30")
        let started = Date()
        do {
            _ = try await CLIProcess.run(executable: url, arguments: [], timeout: 0.3)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? UsageError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testChildIgnoringSIGTERMIsKilledAfterGrace() async throws {
        let url = try script("trap '' TERM\nwhile :; do /bin/sleep 1; done")
        let started = Date()
        do {
            _ = try await CLIProcess.run(executable: url, arguments: [], timeout: 0.3, killGrace: 0.5)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? UsageError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancellationTerminatesTheChild() async throws {
        let url = try script("/bin/sleep 30")
        let task = Task { try await CLIProcess.run(executable: url, arguments: [], timeout: 60) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testMissingExecutableReportsStartFailed() async {
        do {
            _ = try await CLIProcess.run(executable: URL(fileURLWithPath: "/nonexistent/cli"), arguments: [], timeout: 5)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? UsageError, .startFailed)
        }
    }

    func testRunawayOutputIsCappedAndRejected() async throws {
        let url = try script("exec /usr/bin/yes")
        let started = Date()
        do {
            _ = try await CLIProcess.run(executable: url, arguments: [], timeout: 30)
            XCTFail("Expected the output cap to stop the child")
        } catch {
            XCTAssertEqual(error as? UsageError, .invalidResponse)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testChildRunsInTheRootDirectoryNotTheAppsWorkingDirectory() async throws {
        // A CLI started inside an untrusted checkout could pick up that project's configuration.
        let url = try script("/bin/pwd")
        let result = try await CLIProcess.run(executable: url, arguments: [], timeout: 5)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "/\n")
    }

    func testEnvironmentDropsRelativeEntriesAndHandlesEmptyPath() {
        let env = CLIProcess.environment(base: ["PATH": ".:bin:/usr/bin"], home: "/h")
        XCTAssertEqual(env["PATH"], "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin")
        let empty = CLIProcess.environment(base: ["PATH": ""], home: "/h")
        XCTAssertEqual(empty["PATH"], "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    func testEnvironmentPutsTheExecutablesOwnDirectoryFirst() {
        // nvm/volta installs keep `node` next to the CLI, which `#!/usr/bin/env node` must find.
        let env = CLIProcess.environment(base: ["PATH": "/usr/bin"], home: "/h",
                                         executableDirectory: "/h/.nvm/versions/node/v22/bin")
        XCTAssertEqual(env["PATH"], "/h/.nvm/versions/node/v22/bin:/h/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin")
        let duplicate = CLIProcess.environment(base: ["PATH": "/usr/bin"], home: "/h", executableDirectory: "/opt/homebrew/bin")
        XCTAssertEqual(duplicate["PATH"], "/opt/homebrew/bin:/h/.local/bin:/usr/local/bin:/usr/bin")
    }

    func testEnvironmentPrependsStandardDirectoriesOnce() {
        let home = "/Users/test"
        let env = CLIProcess.environment(base: ["PATH": "/usr/bin:/bin"], home: home)
        XCTAssertEqual(env["PATH"], "/Users/test/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        let already = CLIProcess.environment(base: ["PATH": "/opt/homebrew/bin:/usr/bin"], home: home)
        XCTAssertEqual(already["PATH"], "/Users/test/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin")
        let missing = CLIProcess.environment(base: [:], home: home)
        XCTAssertEqual(missing["PATH"], "/Users/test/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }
}
