import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Sendable {
    case enabled
    case disabled
    case requiresApproval
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    func apply(enabled: Bool)
}

@MainActor
final class LaunchAtLoginController: LaunchAtLoginControlling {
    private let service: any LaunchAtLoginServicing
    private(set) var lastError: String?

    init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
    }

    func apply(enabled: Bool) {
        do {
            switch (enabled, service.status) {
            case (true, .disabled):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            case (true, .enabled),
                 (true, .requiresApproval),
                 (false, .disabled):
                break
            }
            lastError = nil
            DeveloperLog.eventRecord(
                "settings.launch_at_login.apply",
                category: "settings",
                trigger: "settings",
                result: "success",
                fields: ["enabled": .bool(enabled)])
        } catch {
            lastError = error.localizedDescription
            DeveloperLog.eventRecord(
                "settings.launch_at_login.apply",
                level: .error,
                category: "settings",
                trigger: "settings",
                result: "failed",
                fields: [
                    "enabled": .bool(enabled),
                    "error": .string(error.localizedDescription)
                ])
        }
    }
}

@MainActor
private final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
