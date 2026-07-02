import Foundation
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {
    private static func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Defaults to enabled on fresh install and persists the default")
    func defaultsToEnabledOnFreshInstallAndPersistsDefault() {
        let defaults = Self.freshDefaults()
        let store = SettingsStore(defaults: defaults)

        #expect(store.launchAtLoginEnabled == true)
        #expect(defaults.object(forKey: "settings.launchAtLoginEnabled") as? Bool == true)
    }

    @Test("User can disable launch at login and the choice survives relaunch")
    func userCanDisableAndPersistChoice() {
        let defaults = Self.freshDefaults()
        let store = SettingsStore(defaults: defaults)

        store.launchAtLoginEnabled = false

        #expect(defaults.bool(forKey: "settings.launchAtLoginEnabled") == false)
        #expect(SettingsStore(defaults: defaults).launchAtLoginEnabled == false)
    }

    @Test("Enabled preference registers only when not already enabled")
    func enabledPreferenceRegistersOnlyWhenNeeded() {
        let service = FakeLaunchAtLoginService(status: .disabled)
        let controller = LaunchAtLoginController(service: service)

        controller.apply(enabled: true)
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 0)

        service.status = .enabled
        controller.apply(enabled: true)
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 0)
    }

    @Test("Disabled preference unregisters only when currently enabled")
    func disabledPreferenceUnregistersOnlyWhenNeeded() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        controller.apply(enabled: false)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 1)

        service.status = .disabled
        controller.apply(enabled: false)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 1)
    }

    @Test("AppEnvironment skips system registration while local QA is active")
    func appEnvironmentSkipsSystemRegistrationDuringLocalQA() {
        let controller = SpyLaunchAtLoginController()
        let env = AppEnvironment(
            launchAtLoginController: controller,
            startBackgroundTasks: false)

        env.applyLaunchAtLoginPreference(enabled: true, allowSystemRegistration: false)
        #expect(controller.appliedValues.isEmpty)

        env.applyLaunchAtLoginPreference(enabled: false, allowSystemRegistration: true)
        #expect(controller.appliedValues == [false])
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .disabled
    }
}

@MainActor
private final class SpyLaunchAtLoginController: LaunchAtLoginControlling {
    private(set) var appliedValues: [Bool] = []

    func apply(enabled: Bool) {
        appliedValues.append(enabled)
    }
}
