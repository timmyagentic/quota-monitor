enum PrivateBetaCheckIntent: Equatable {
    case checkForUpdates
    case revealEnrollment
}

enum PrivateBetaSettingsPresentation {
    static func showsControls(
        privateBetaAvailable: Bool,
        privateBetaEnrolled: Bool,
        enrollmentRevealed: Bool
    ) -> Bool {
        privateBetaAvailable && (privateBetaEnrolled || enrollmentRevealed)
    }

    static func checkIntent(
        privateBetaAvailable: Bool,
        privateBetaEnrolled: Bool,
        optionPressed: Bool
    ) -> PrivateBetaCheckIntent {
        if privateBetaAvailable && !privateBetaEnrolled && optionPressed {
            return .revealEnrollment
        }
        return .checkForUpdates
    }
}
