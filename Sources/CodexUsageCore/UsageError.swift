import Foundation

public enum UsageError: Error, Equatable, LocalizedError {
    case cliNotFound, loginRequired, unsupportedAccount, startFailed
    case unavailable, connectionClosed, timedOut, invalidResponse, requestFailed, stopped

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: return "Codex CLI not found"
        case .loginRequired: return "Codex login required"
        case .unsupportedAccount: return "Usage unavailable"
        case .startFailed: return "Unable to start Codex App Server"
        case .unavailable: return "Usage unavailable"
        case .connectionClosed: return "Codex disconnected"
        case .timedOut: return "Usage request timed out"
        case .invalidResponse: return "Unable to read usage data"
        case .requestFailed: return "Unable to retrieve usage"
        case .stopped: return "Connection stopped"
        }
    }
    public var recoverySuggestion: String? {
        switch self {
        case .cliNotFound: return "Install the official Codex CLI or choose its executable in Settings."
        case .loginRequired: return "Run codex login in Terminal, then refresh."
        case .unsupportedAccount: return "Subscription usage is unavailable with the current CLI sign-in method."
        case .startFailed: return "Check the executable in Settings and confirm that codex runs in Terminal."
        case .unavailable: return "No Codex limit information was returned for this account."
        default: return "Check your connection. Usage will refresh automatically."
        }
    }
}
