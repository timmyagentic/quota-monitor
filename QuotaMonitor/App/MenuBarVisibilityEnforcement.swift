import Foundation

enum MenuBarVisibilityEnforcement {
    enum Action: Equatable {
        case retry
        case applyUnreachable(clipped: Bool)
    }

    static func decide(visibility: StatusItemVisibility, attempt: Int) -> Action {
        if visibility == .clipped && attempt < 2 {
            return .retry
        }
        return .applyUnreachable(clipped: visibility == .clipped)
    }
}
