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
}
