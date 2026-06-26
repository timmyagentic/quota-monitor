enum ClaudeProviderQuotaVisibility {
    static func hasRenderableOAuthRows(_ usage: ClaudeUsageSnapshot) -> Bool {
        usage.fiveHour != nil ||
        usage.staleFiveHour != nil ||
        usage.sevenDay != nil ||
        hasRenderableModelQuota(usage.sevenDayOpus) ||
        hasRenderableModelQuota(usage.sevenDaySonnet)
    }

    static func hasRenderableModelQuota(_ window: ClaudeUsageSnapshot.Window?) -> Bool {
        window != nil
    }
}
