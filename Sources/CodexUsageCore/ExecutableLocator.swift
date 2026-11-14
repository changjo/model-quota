import Foundation

public enum ExecutableLocator {
    public static func searchDirectories(path: String) -> [String] {
        let fromPath = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return fromPath + ["/opt/homebrew/bin", "/usr/local/bin",
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
    }

    /// Resolves a provider CLI. An explicit path must be an absolute (or `~`-relative) executable
    /// file and is never silently replaced by automatic detection; an empty path searches the
    /// absolute `PATH` entries and the usual install locations.
    /// Install locations searched before `PATH` for a provider. Claude's native installer puts an
    /// auto-updating `claude` in `~/.local/bin`, which must win over an older npm-global copy.
    public static func preferredDirectories(for kind: ProviderKind) -> [String] {
        switch kind {
        case .claude: return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        case .codex, .gemini: return []
        }
    }

    /// The single resolution rule for a provider's CLI, shared by the clients and Settings validation.
    public static func resolve(_ kind: ProviderKind, customPath: String) throws -> URL {
        try resolve(customPath: customPath, name: kind.executableName,
                    preferredDirectories: preferredDirectories(for: kind))
    }

    public static func resolve(customPath: String,
                               name: String = "codex",
                               path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                               preferredDirectories: [String] = []) throws -> URL {
        let custom = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), isExecutable(expanded) else { throw UsageError.cliNotFound }
            return URL(fileURLWithPath: expanded)
        }
        for directory in preferredDirectories + searchDirectories(path: path) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
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
