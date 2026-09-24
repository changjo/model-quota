import Foundation

public enum UsageError: Error, Equatable, LocalizedError {
    case cliNotFound, loginRequired, unsupportedAccount, startFailed
    case unavailable, connectionClosed, timedOut, invalidResponse, requestFailed, stopped

    public func errorDescription(for provider: String = "Codex") -> String {
        switch self {
        case .cliNotFound:
            return "\(provider) CLI not found"
        case .loginRequired:
            return "\(provider) login required"
        case .unsupportedAccount:
            return "Usage unavailable"
        case .startFailed:
            return provider == "Codex" ? "Unable to start Codex App Server" : "Unable to start \(provider) CLI"
        case .unavailable:
            return "Usage unavailable"
        case .connectionClosed:
            return "\(provider) disconnected"
        case .timedOut:
            return "Usage request timed out"
        case .invalidResponse:
            return "Unable to read usage data"
        case .requestFailed:
            return "Unable to retrieve usage"
        case .stopped:
            return "Connection stopped"
        }
    }

    public func recoverySuggestion(for provider: String = "Codex") -> String {
        switch self {
        case .cliNotFound:
            if provider == "Codex" {
                return "Install the official Codex CLI or choose its executable in Settings."
            } else {
                return "Install the official Antigravity CLI (agy) or choose its executable in Settings."
            }
        case .loginRequired:
            if provider == "Codex" {
                return "Run codex login in Terminal, then refresh."
            } else {
                return "Sign in to your Google Antigravity account in Terminal, then refresh."
            }
        case .unsupportedAccount:
            return "Subscription usage is unavailable with the current CLI sign-in method."
        case .startFailed:
            if provider == "Codex" {
                return "Check the executable in Settings and confirm that codex runs in Terminal."
            } else {
                return "Check the executable in Settings and confirm that agy runs in Terminal."
            }
        case .unavailable:
            return "No \(provider) limit information was returned for this account."
        default:
            return "Check your connection. Usage will refresh automatically."
        }
    }

    public var errorDescription: String? {
        errorDescription(for: "Codex")
    }

    public var recoverySuggestion: String? {
        recoverySuggestion(for: "Codex")
    }
}
