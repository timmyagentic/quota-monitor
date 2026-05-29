import Foundation

/// Lifecycle actions for the recovery guide window.
struct MenuBarHelpLifecycleActions {
    var demoteToAccessory: @MainActor () -> Void

    @MainActor
    static func live(env: AppEnvironment) -> MenuBarHelpLifecycleActions {
        MenuBarHelpLifecycleActions(
            demoteToAccessory: {
                env.demoteToAccessory(excludingWindowIDs: ["menubar-help"])
            })
    }

    @MainActor
    func windowDidDisappear() {
        demoteToAccessory()
    }
}
