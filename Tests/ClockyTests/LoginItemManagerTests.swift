import AppKit
import Combine
import ServiceManagement
import XCTest
@testable import Clocky

final class LoginItemManagerTests: XCTestCase {
    @MainActor
    private final class MockService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var registrationResult: SMAppService.Status = .enabled
        var unregistrationResult: SMAppService.Status = .notRegistered
        var registrationError: Error?
        var unregistrationError: Error?
        var registerCalls = 0
        var unregisterCalls = 0
        var settingsCalls = 0

        func register() throws {
            registerCalls += 1
            status = registrationResult
            if let registrationError { throw registrationError }
        }

        func unregister() throws {
            unregisterCalls += 1
            status = unregistrationResult
            if let unregistrationError { throw unregistrationError }
        }

        func openSystemSettings() { settingsCalls += 1 }
    }

    @MainActor
    func testInitializationAndStopNeverChangeRegistration() async {
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = MockService()
            service.status = status
            let manager = LoginItemManager(service: service)
            XCTAssertEqual(manager.status, status)
            XCTAssertEqual(manager.isRequested, status == .enabled || status == .requiresApproval)
            manager.stop()
            manager.stop()
            XCTAssertEqual(service.registerCalls, 0)
            XCTAssertEqual(service.unregisterCalls, 0)
            XCTAssertEqual(service.settingsCalls, 0)
            XCTAssertEqual(service.status, status)
        }
    }

    @MainActor
    func testEnableAndDisableUseActualServiceStatus() async {
        let service = MockService()
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        XCTAssertTrue(manager.canConfigure)
        XCTAssertNil(manager.unavailableReason)
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertTrue(manager.isRequested)
        XCTAssertFalse(manager.requiresApproval)
        manager.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertFalse(manager.isRequested)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(service.settingsCalls, 0)
    }

    @MainActor
    func testRepeatedRequestsAreIdempotent() async {
        let service = MockService()
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        manager.setEnabled(false)
        manager.setEnabled(true)
        manager.setEnabled(true)
        manager.setEnabled(false)
        manager.setEnabled(false)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    @MainActor
    func testPendingApprovalStaysRequestedAndCanBeUnregistered() async {
        let service = MockService()
        service.registrationResult = .requiresApproval
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        manager.setEnabled(true)
        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertTrue(manager.isRequested)
        XCTAssertTrue(manager.requiresApproval)
        XCTAssertNil(manager.errorMessage)
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.settingsCalls, 0)
        manager.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(manager.isRequested)
        XCTAssertFalse(manager.requiresApproval)
    }

    @MainActor
    func testRegistrationErrorReportsActualStateAndAllowsRetry() async {
        let service = MockService()
        service.registrationResult = .notRegistered
        service.registrationError = NSError(
            domain: "Clocky.Tests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Registration was denied."]
        )
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        manager.setEnabled(true)
        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertFalse(manager.isRequested)
        XCTAssertTrue(manager.errorMessage?.contains("Could not enable") == true)
        XCTAssertTrue(manager.errorMessage?.contains("Registration was denied.") == true)
        service.registrationError = nil
        service.registrationResult = .enabled
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 2)
        XCTAssertTrue(manager.isRequested)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testRegistrationErrorStillReadsChangedActualState() async {
        let service = MockService()
        service.registrationResult = .requiresApproval
        service.registrationError = NSError(domain: "Clocky.Tests", code: 2)
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        manager.setEnabled(true)
        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertTrue(manager.isRequested)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testUnregistrationErrorsReflectBothUnchangedAndChangedActualState() async {
        for result in [SMAppService.Status.enabled, .notRegistered] {
            let service = MockService()
            service.status = .enabled
            service.unregistrationResult = result
            service.unregistrationError = NSError(
                domain: "Clocky.Tests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unregistration failed."]
            )
            let manager = LoginItemManager(service: service)
            defer { manager.stop() }
            manager.setEnabled(false)
            XCTAssertEqual(manager.status, result)
            XCTAssertEqual(manager.isRequested, result == .enabled)
            XCTAssertTrue(manager.errorMessage?.contains("Could not disable") == true)
            XCTAssertTrue(manager.errorMessage?.contains("Unregistration failed.") == true)
        }
    }

    @MainActor
    func testRefreshObservesExternalChanges() async {
        let service = MockService()
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        service.status = .requiresApproval
        manager.refresh()
        XCTAssertTrue(manager.requiresApproval)
        service.status = .enabled
        manager.refresh()
        XCTAssertEqual(manager.status, .enabled)
        service.status = .notRegistered
        manager.refresh()
        XCTAssertFalse(manager.isRequested)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    @MainActor
    func testRequestChecksExternalChangesBeforeDecidingWhetherToRegister() async {
        let service = MockService()
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        service.status = .enabled
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(manager.status, .enabled)
        service.status = .notRegistered
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
    }

    @MainActor
    func testActivationRefreshesUntilStopped() async {
        let service = MockService()
        let center = NotificationCenter()
        let manager = LoginItemManager(service: service, notificationCenter: center)
        defer { manager.stop() }
        let refreshed = expectation(description: "Activation refreshes registration")
        let token = manager.$status.dropFirst().prefix(1).sink { status in
            XCTAssertEqual(status, .enabled)
            refreshed.fulfill()
        }
        service.status = .enabled
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [refreshed], timeout: 1)
        withExtendedLifetime(token) {}

        manager.stop()
        let stopped = expectation(description: "Stopped observer does not refresh")
        stopped.isInverted = true
        let stoppedToken = manager.$status.dropFirst().sink { _ in stopped.fulfill() }
        service.status = .notRegistered
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [stopped], timeout: 0.1)
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertEqual(service.unregisterCalls, 0)
        withExtendedLifetime(stoppedToken) {}
    }

    @MainActor
    func testNotFoundIsReadableButAllowsRetry() async {
        let service = MockService()
        service.status = .notFound
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        XCTAssertTrue(manager.canConfigure)
        XCTAssertFalse(manager.isRequested)
        XCTAssertTrue(manager.errorMessage?.contains("could not find") == true)
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testNotFoundAfterRegistrationIsNotReportedAsEnabled() async {
        let service = MockService()
        service.registrationResult = .notFound
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        manager.setEnabled(true)
        XCTAssertFalse(manager.isRequested)
        XCTAssertNotNil(manager.errorMessage)
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 2)
    }

    @MainActor
    func testUnavailableManagerCannotMutateExistingRegistrationOrOpenSettings() async {
        let service = MockService()
        service.status = .enabled
        let reason = "Requires a packaged app."
        let manager = LoginItemManager(service: service, unavailableReason: reason)
        defer { manager.stop() }
        XCTAssertFalse(manager.canConfigure)
        XCTAssertEqual(manager.unavailableReason, reason)
        manager.setEnabled(false)
        manager.setEnabled(true)
        manager.openSystemSettings()
        manager.refresh()
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(service.settingsCalls, 0)
    }

    @MainActor
    func testOnlyExplicitActionOpensSystemSettings() async {
        let service = MockService()
        service.registrationResult = .requiresApproval
        let manager = LoginItemManager(service: service)
        defer { manager.stop() }
        manager.setEnabled(true)
        manager.refresh()
        XCTAssertEqual(service.settingsCalls, 0)
        manager.openSystemSettings()
        XCTAssertEqual(service.settingsCalls, 1)
        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    @MainActor
    func testSupportCheckAcceptsPackagedAppOutsideApplications() async {
        XCTAssertNil(LoginItemManager.configurationUnavailableReason(
            bundleURL: URL(fileURLWithPath: "/Users/test/Tools/Clocky.app"),
            executableURL: URL(fileURLWithPath: "/Users/test/Tools/Clocky.app/Contents/MacOS/Clocky"),
            bundleIdentifier: "com.example.Clocky", arguments: []
        ))
    }

    @MainActor
    func testSupportCheckRejectsDirectRunMalformedBundleAndMissingIdentifier() async {
        let app = URL(fileURLWithPath: "/Tools/Clocky.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Clocky")
        let cases: [(URL, URL?, String?)] = [
            (URL(fileURLWithPath: "/repo/.build/debug"), URL(fileURLWithPath: "/repo/.build/debug/Clocky"), nil),
            (app, app.appendingPathComponent("Clocky"), "com.example.Clocky"),
            (app, nil, "com.example.Clocky"),
            (app, executable, nil),
            (app, executable, "  ")
        ]
        for (bundle, executable, identifier) in cases {
            let reason = LoginItemManager.configurationUnavailableReason(
                bundleURL: bundle, executableURL: executable,
                bundleIdentifier: identifier, arguments: []
            )
            XCTAssertTrue(reason?.contains("packaged Clocky.app") == true)
            XCTAssertTrue(reason?.contains("swift run") == true)
        }
    }

    @MainActor
    func testSmokeTestGuardOverridesOtherwiseSupportedBundle() async {
        let reason = LoginItemManager.configurationUnavailableReason(
            bundleURL: URL(fileURLWithPath: "/Applications/Clocky.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Clocky.app/Contents/MacOS/Clocky"),
            bundleIdentifier: "com.example.Clocky", arguments: ["Clocky", "--smoke-test"]
        )
        XCTAssertTrue(reason?.contains("disabled during smoke-test diagnostics") == true)
        let service = MockService()
        let manager = LoginItemManager(service: service, unavailableReason: reason)
        defer { manager.stop() }
        manager.setEnabled(true)
        manager.setEnabled(false)
        manager.openSystemSettings()
        XCTAssertFalse(manager.canConfigure)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(service.settingsCalls, 0)
    }
}
