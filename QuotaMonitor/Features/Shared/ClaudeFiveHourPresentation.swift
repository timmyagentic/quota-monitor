import Foundation

/// Select the same 5h source for the popover and Dashboard. A local billing
/// block describes elapsed time and measured usage, not account quota.
enum ClaudeFiveHourPresentation: Equatable {
    case quota(ClaudeUsageSnapshot.Window)
    case localBlock(BillingBlocks.Block)
    case idle
    case unavailable

    static func make(usage: ClaudeUsageSnapshot?, block: BillingBlocks.Block?) -> Self {
        if let window = usage?.fiveHourForDisplay { return .quota(window) }
        if let block { return .localBlock(block) }
        if usage?.hasRenderableWeeklyQuotaWindow == true { return .idle }
        return .unavailable
    }
}
