import Foundation

enum UpdateChannel: String, CaseIterable, Sendable {
    case stable
    case privateBeta = "private-beta"

    static let defaultsKey = "QMUpdateChannel"

    init(defaults: UserDefaults) {
        self = UpdateChannel(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .stable
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
