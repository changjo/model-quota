import Foundation

public enum ProviderKind: String, CaseIterable, Sendable {
    case codex, gemini, claude

    public var defaultName: String {
        switch self {
        case .codex: return "Codex"
        case .gemini: return "Antigravity"
        case .claude: return "Claude"
        }
    }

    public var executableName: String {
        switch self {
        case .codex: return "codex"
        case .gemini: return "agy"
        case .claude: return "claude"
        }
    }

    init(legacyName: String) {
        switch legacyName {
        case "Codex": self = .codex
        case "Claude": self = .claude
        default: self = .gemini
        }
    }
}

public enum UsageError: Error, Equatable, LocalizedError {
    case cliNotFound, loginRequired, unsupportedAccount, startFailed
    case unavailable, connectionClosed, timedOut, invalidResponse, requestFailed, stopped

    /// Error title. `name` is the user-visible label; guidance depends only on `kind`, so a
    /// custom label (e.g. "GPT") never changes which CLI the text talks about.
    public func errorDescription(for kind: ProviderKind, name: String) -> String {
        switch self {
        case .cliNotFound: return "\(name) CLI not found"
        case .loginRequired: return "\(name) login required"
        case .unsupportedAccount, .unavailable: return "Usage unavailable"
        case .startFailed: return kind == .codex ? "Unable to start \(name) App Server" : "Unable to start \(name) CLI"
        case .connectionClosed: return "\(name) disconnected"
        case .timedOut: return "Usage request timed out"
        case .invalidResponse: return "Unable to read usage data"
        case .requestFailed: return "Unable to retrieve usage"
        case .stopped: return "Connection stopped"
        }
    }

    public func recoverySuggestion(for kind: ProviderKind, name: String) -> String {
        switch self {
        case .cliNotFound:
            switch kind {
            case .codex: return "Install the official Codex CLI or choose its executable in Settings."
            case .claude: return "Install the official Claude Code CLI (claude) or choose its executable in Settings."
            case .gemini: return "Install the official Antigravity CLI (agy) or choose its executable in Settings."
            }
        case .loginRequired:
            switch kind {
            case .codex: return "Run codex login in Terminal, then refresh."
            case .claude: return "Run claude in Terminal to sign in to your Anthropic account, then refresh."
            case .gemini: return "Sign in to your Google Antigravity account in Terminal, then refresh."
            }
        case .unsupportedAccount:
            return "Subscription usage is unavailable with the current CLI sign-in method."
        case .startFailed:
            return "Check the executable in Settings and confirm that \(kind.executableName) runs in Terminal."
        case .unavailable:
            return "No \(name) limit information was returned for this account."
        default:
            return "Check your connection. Usage will refresh automatically."
        }
    }

    /// Legacy string-keyed API kept for tests; the UI must use the `ProviderKind` overloads.
    func errorDescription(for provider: String = "Codex") -> String {
        errorDescription(for: ProviderKind(legacyName: provider), name: provider)
    }

    func recoverySuggestion(for provider: String = "Codex") -> String {
        recoverySuggestion(for: ProviderKind(legacyName: provider), name: provider)
    }

    /// Maps a CLI's human-readable failure text to an error. URLs are ignored so that words
    /// inside a sign-in link (e.g. `auth_success`) cannot masquerade as the failure reason.
    public static func classifyCLIFailure(_ message: String) -> UsageError {
        let text = message
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .lowercased()
        let signInHints = ["sign in", "sign-in", "signin", "signed in", "log in", "login", "logged in",
                           "not logged", "authenticat", "authoriz", "oauth", "token has expired",
                           "token expired", "session expired", "eligib", "verify your account", "credential"]
        return signInHints.contains(where: text.contains) ? .loginRequired : .requestFailed
    }

    public var errorDescription: String? {
        errorDescription(for: .codex, name: ProviderKind.codex.defaultName)
    }

    public var recoverySuggestion: String? {
        recoverySuggestion(for: .codex, name: ProviderKind.codex.defaultName)
    }
}
