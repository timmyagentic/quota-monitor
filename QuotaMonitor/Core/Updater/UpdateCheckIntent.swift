struct UpdateCheckIntent {
    enum DiscoveryAction: Equatable {
        case manual
        case installAvailableUpdate
    }

    private var nextDiscoveryAction: DiscoveryAction = .manual

    var presentsCheckingUI: Bool {
        nextDiscoveryAction == .manual
    }

    mutating func requestDirectInstall() {
        nextDiscoveryAction = .installAvailableUpdate
    }

    mutating func consumeDiscovery() -> DiscoveryAction {
        let action = nextDiscoveryAction
        nextDiscoveryAction = .manual
        return action
    }

    mutating func reset() {
        nextDiscoveryAction = .manual
    }
}
