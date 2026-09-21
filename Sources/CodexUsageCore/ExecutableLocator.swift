import Foundation

public enum ExecutableLocator {
    public static func searchDirectories(path: String) -> [String] {
        let fromPath = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return fromPath + ["/opt/homebrew/bin", "/usr/local/bin",
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
    }

    public static func resolve(customPath: String, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") throws -> URL {
        let custom = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            guard custom.hasPrefix("/"), isExecutable(custom) else { throw UsageError.cliNotFound }
            return URL(fileURLWithPath: custom)
        }
        for directory in searchDirectories(path: path) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if isExecutable(candidate.path) { return candidate }
        }
        throw UsageError.cliNotFound
    }

    private static func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
