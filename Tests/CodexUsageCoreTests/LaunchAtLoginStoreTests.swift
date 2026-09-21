import XCTest
import ServiceManagement
@testable import CodexUsageCore

@MainActor
final class LaunchAtLoginStoreTests: XCTestCase {
    // Substitute only the external OS registration boundary; exercise the real store.
    final class Service: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var registerResult: SMAppService.Status = .enabled
        var failRegister = false
        var failUnregister = false
        var registrationCount = 0
        var settingsOpenCount = 0
        var unregisterCount = 0
        var delayUnregister = false
        var pendingUnregister: CheckedContinuation<Void, Never>?
        func register() throws {
            registrationCount += 1
            if failRegister { throw NSError(domain: "RegistrationTest", code: 1) }
            status = registerResult
        }
        func unregister() async throws {
            unregisterCount += 1
            if delayUnregister {
                await withCheckedContinuation { pendingUnregister = $0 }
            }
            if failUnregister { throw NSError(domain: "RegistrationTest", code: 2) }
            status = .notRegistered
        }
        func openSystemSettings() { settingsOpenCount += 1 }
    }

    func testInitialStateAndExternalChangesReflectSystemStatus() {
        let service = Service()
        service.status = .enabled
        let store = LaunchAtLoginStore(service: service)
        XCTAssertTrue(store.isEnabled)
        service.status = .requiresApproval
        store.refreshStatus()
        XCTAssertFalse(store.isEnabled, "System consent revoked must not be shown as enabled")
        XCTAssertTrue(store.needsApproval)
        service.status = .notRegistered
        store.refreshStatus()
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.needsApproval)
        XCTAssertEqual(service.registrationCount, 0, "Reading state must not enable login automatically")
    }

    func testEnableReadsBackSuccessfulRegistration() async {
        let service = Service()
        // macOS can report notFound before the first successful registration.
        service.status = .notFound
        let store = LaunchAtLoginStore(service: service)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.errorMessage)
        await store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isUpdating)
        await store.setEnabled(true)
        XCTAssertEqual(service.registrationCount, 1, "Already enabled should not register twice")
    }

    func testPendingApprovalIsNotReportedAsEnabledAndCanBeCancelled() async {
        let service = Service()
        service.registerResult = .requiresApproval
        let store = LaunchAtLoginStore(service: service)
        await store.setEnabled(true)
        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.needsApproval)
        XCTAssertNil(store.errorMessage)
        await store.setEnabled(true)
        XCTAssertEqual(service.registrationCount, 1, "Pending item must not be registered again")
        XCTAssertEqual(service.settingsOpenCount, 1)
        await store.setEnabled(false)
        XCTAssertFalse(store.needsApproval)
        XCTAssertFalse(store.isEnabled)
    }

    func testFailedEnableStaysOffAndRetryClearsError() async {
        let service = Service()
        service.failRegister = true
        let store = LaunchAtLoginStore(service: service)
        await store.setEnabled(true)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNotNil(store.errorMessage)
        service.failRegister = false
        await store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(store.errorMessage)
    }

    func testFailedDisableKeepsActualEnabledState() async {
        let service = Service()
        service.status = .enabled
        service.failUnregister = true
        let store = LaunchAtLoginStore(service: service)
        await store.setEnabled(false)
        XCTAssertTrue(store.isEnabled)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isUpdating)
    }

    func testDisableWaitsAndPreventsOverlappingRegistration() async {
        let service = Service()
        service.status = .enabled
        service.delayUnregister = true
        let store = LaunchAtLoginStore(service: service)
        let disabling = Task { await store.setEnabled(false) }
        for _ in 0..<100 where service.pendingUnregister == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(service.pendingUnregister)
        XCTAssertTrue(store.isUpdating)
        XCTAssertTrue(store.isEnabled)
        await store.setEnabled(true)
        service.pendingUnregister?.resume()
        service.pendingUnregister = nil
        await disabling.value
        XCTAssertFalse(store.isUpdating)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(service.registrationCount, 0)
        XCTAssertEqual(service.unregisterCount, 1)
    }
}
