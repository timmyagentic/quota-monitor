import Foundation

enum SummaryRefreshTarget: Equatable, Sendable {
    case menuBar
    case dashboardAndMenuBar
}

struct RefreshGeneration: Sendable {
    private(set) var current = 0

    mutating func advance() -> Int {
        current &+= 1
        return current
    }

    func accepts(_ candidate: Int) -> Bool {
        candidate == current
    }
}

struct DashboardRefreshInputs: Equatable, Sendable {
    let providerFilter: ProviderFilter
    let enabledProviders: Set<String>
    let includesMenuBar: Bool
}

/// Coalesces Dashboard reads without losing a newer scan/settings request.
/// Identical internal mount requests are duplicates; any semantic input change
/// or named freshness trigger requests one trailing pass.
struct DashboardRefreshCoalescer: Sendable {
    private(set) var activeInputs: DashboardRefreshInputs?
    private(set) var hasPendingRefresh = false
    private var pendingIncludesMenuBar = false

    static func requiresFreshPass(for trigger: String) -> Bool {
        trigger != "internal" && trigger != "mount" && trigger != "coalesced"
    }

    mutating func begin(
        inputs: DashboardRefreshInputs,
        requiresFreshPass: Bool
    ) -> Bool {
        guard let activeInputs else {
            self.activeInputs = inputs
            return true
        }

        if activeInputs != inputs || requiresFreshPass {
            hasPendingRefresh = true
            pendingIncludesMenuBar = pendingIncludesMenuBar || inputs.includesMenuBar
        }
        return false
    }

    /// Finishes the active pass and returns the strongest pending surface
    /// requirement. The next pass deliberately re-reads current settings.
    mutating func finish() -> Bool? {
        activeInputs = nil
        guard hasPendingRefresh else { return nil }
        let includeMenuBar = pendingIncludesMenuBar
        hasPendingRefresh = false
        pendingIncludesMenuBar = false
        return includeMenuBar
    }
}
