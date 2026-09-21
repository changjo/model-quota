import Combine
import ServiceManagement

@MainActor
public protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
private final class MainAppLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
public final class LaunchAtLoginStore: ObservableObject {
    @Published public private(set) var status: SMAppService.Status
    @Published public private(set) var isUpdating = false
    @Published public private(set) var errorMessage: String?
    private let service: LoginItemService

    public var isEnabled: Bool { status == .enabled }
    public var needsApproval: Bool { status == .requiresApproval }

    public init(service: LoginItemService? = nil) {
        let service = service ?? MainAppLoginItemService()
        self.service = service
        self.status = service.status
    }

    public func refreshStatus() {
        let current = service.status
        if current != status { errorMessage = nil }
        status = current
    }

    public func openSystemSettings() { service.openSystemSettings() }

    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refreshStatus()
        if enabled && needsApproval {
            // The item already exists. Registering again cannot grant system consent.
            openSystemSettings()
            return
        }
        guard enabled ? !isEnabled : (isEnabled || needsApproval) else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
            refreshStatus()
            if enabled ? (!isEnabled && !needsApproval) : (isEnabled || needsApproval) {
                errorMessage = "macOS hasn't confirmed the change. Check Login Items in System Settings."
            }
        } catch {
            // Keep the switch truthful even when registration or removal fails.
            refreshStatus()
            errorMessage = enabled
                ? "Couldn't enable Launch at Login. Try again or check Login Items in System Settings."
                : "Couldn't disable Launch at Login. Try again or check Login Items in System Settings."
        }
    }
}
