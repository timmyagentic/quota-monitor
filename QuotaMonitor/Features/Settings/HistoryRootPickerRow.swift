import AppKit
import SwiftUI

struct HistoryRootPickerRow: View {
    let kind: HistoryRootKind
    var required: Bool = true
    var showsClearButton: Bool = true
    var onChange: () -> Void = { }

    @State private var displayPath: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(displayPath ?? L10n.historyFolderNotSelected)
                        .font(.caption.monospaced())
                        .foregroundStyle(displayPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(displayPath == nil ? L10n.chooseFolder : L10n.changeFolder) {
                    chooseFolder()
                }
                if showsClearButton, displayPath != nil {
                    Button(L10n.clearFolder) {
                        HistoryRootAuthorizationStore.shared.clear(kind: kind)
                        reload()
                        onChange()
                    }
                }
            }
            if required, displayPath == nil {
                Text(L10n.historyFolderRequired)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { reload() }
    }

    private var title: String {
        switch kind {
        case .codexHome:
            return L10n.historyRootCodexHome
        case .claudeProjects:
            return L10n.historyRootClaudeProjects
        case .claudeConfigProjects:
            return L10n.historyRootClaudeConfigProjects
        }
    }

    private var help: String {
        switch kind {
        case .codexHome:
            return L10n.historyRootCodexHelp
        case .claudeProjects:
            return L10n.historyRootClaudeProjectsHelp
        case .claudeConfigProjects:
            return L10n.historyRootClaudeConfigHelp
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L10n.chooseFolder
        panel.message = help
        if let suggested = suggestedURL() {
            panel.directoryURL = suggested
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryRootAuthorizationStore.shared.authorize(kind: kind, url: url)
            errorMessage = nil
            reload()
            onChange()
        } catch {
            errorMessage = L10n.historyFolderAuthorizationFailed(error.localizedDescription)
        }
    }

    private func reload() {
        displayPath = HistoryRootAuthorizationStore.shared.displayPath(for: kind)
    }

    private func suggestedURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url: URL
        switch kind {
        case .codexHome:
            url = home.appendingPathComponent(".codex", isDirectory: true)
        case .claudeProjects:
            url = home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .claudeConfigProjects:
            url = home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
