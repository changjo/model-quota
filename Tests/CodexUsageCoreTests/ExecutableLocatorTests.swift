import XCTest
@testable import CodexUsageCore

final class ExecutableLocatorTests: XCTestCase {
    func testExplicitPathIsUsedWithoutShellInterpretation() throws {
        XCTAssertEqual(try ExecutableLocator.resolve(customPath: "/usr/bin/true", path: "").path, "/usr/bin/true")
        XCTAssertThrowsError(try ExecutableLocator.resolve(customPath: "/no-such-codex", path: "/opt/homebrew/bin"))
        XCTAssertThrowsError(try ExecutableLocator.resolve(customPath: "codex; echo unsafe", path: "/opt/homebrew/bin"))
    }

    func testSearchesAbsolutePathAndIgnoresWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertEqual(try ExecutableLocator.resolve(customPath: "", path: ".::\(directory.path)").path, file.path)
        XCTAssertFalse(ExecutableLocator.searchDirectories(path: ".::relative:/bin").contains(where: { !$0.hasPrefix("/") }))
    }

    func testDirectoryCannotBeUsedAsExecutable() {
        XCTAssertThrowsError(try ExecutableLocator.resolve(customPath: "/bin", path: ""))
    }

    func testInvalidExplicitPathNeverFallsBackToAutomaticDetection() throws {
        // /bin/sh exists in the search path, but an explicit wrong path must still fail.
        XCTAssertThrowsError(try ExecutableLocator.resolve(customPath: "/no/such/agy", name: "sh", path: "/bin"))
        XCTAssertEqual(try ExecutableLocator.resolve(customPath: "", name: "sh", path: "/bin").path, "/bin/sh")
        XCTAssertNil(GeminiAgyClient.locateAgy(customPath: "/no/such/agy"))
        XCTAssertNil(ClaudeClient.locateClaude(customPath: "/no/such/claude"))
    }

    func testTildeExpandsToHome() throws {
        // Walk from $HOME up to / and back down to /bin/sh, so nothing is written to the home folder.
        let depth = NSHomeDirectory().split(separator: "/").count
        let tilde = "~/" + String(repeating: "../", count: depth) + "bin/sh"
        let resolved = try ExecutableLocator.resolve(customPath: tilde, name: "sh", path: "")
        XCTAssertTrue(resolved.path.hasPrefix(NSHomeDirectory()))
        XCTAssertEqual(resolved.standardizedFileURL.path, "/bin/sh")
    }

    func testPreferredDirectoryWinsOverPathForClaudeNativeInstaller() throws {
        func makeTool(in name: String) throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("claude")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return directory
        }
        let stale = try makeTool(in: "npm-")
        let native = try makeTool(in: "native-")
        let resolved = try ExecutableLocator.resolve(customPath: "", name: "claude", path: stale.path,
                                                     preferredDirectories: [native.path])
        XCTAssertEqual(resolved.deletingLastPathComponent().path, native.path)
        XCTAssertEqual(ExecutableLocator.preferredDirectories(for: .claude).first, NSHomeDirectory() + "/.local/bin")
        XCTAssertTrue(ExecutableLocator.preferredDirectories(for: .codex).isEmpty)
    }
}
