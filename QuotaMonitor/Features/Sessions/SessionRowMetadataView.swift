import SwiftUI

struct SessionRowMetadataView: View {
    let row: SessionRow
    let showsUpdatedRelativeTime: Bool

    init(row: SessionRow, showsUpdatedRelativeTime: Bool = false) {
        self.row = row
        self.showsUpdatedRelativeTime = showsUpdatedRelativeTime
    }

    var body: some View {
        HStack(spacing: 8) {
            if let project = row.projectName, !project.isEmpty {
                Label(project, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.cwd ?? project)
            }
            if let agent = row.agentNickname, !agent.isEmpty {
                Text(agent)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(Capsule())
            }
            if row.containsSubagents {
                Label(L10n.subagents, systemImage: "person.2.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .help(L10n.helpSpawnedSubagents)
            }
            if let model = row.lastModelId, !model.isEmpty {
                Text(model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.eventsCount(row.eventCount))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if showsUpdatedRelativeTime, let updated = row.updatedAt {
                Text(formatRelative(updated))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatRelative(_ iso: String) -> String {
        guard let date = ISO8601.parse(iso) else { return iso }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizationStore.activeLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
