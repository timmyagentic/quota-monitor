import AppKit
import SwiftUI

struct HistoryRootPickerRow: View {
    let kind: HistoryRootKind
    var required: Bool = true
    var showsClearButton: Bool = true
    /// Bumped by the parent whenever ANY history folder is granted/cleared, so
    /// a sibling row (e.g. the interchangeable alternate Claude root) can
    /// refresh its "Required" state without reopening Settings.
    var refreshToken: Int = 0
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
            if showsRequiredWarning {
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
        .onChange(of: refreshToken) { reload() }
    }

    /// The orange "Required" note must be group-aware: granting the
    /// interchangeable alternate `~/.config/claude/projects` fully authorizes
    /// Claude, so the primary Claude row must stop warning once it's set.
    private var showsRequiredWarning: Bool {
        guard required, displayPath == nil else { return false }
        if kind == .claudeProjects,
           HistoryRootAuthorizationStore.shared.displayPath(for: .claudeConfigProjects) != nil {
            return false
        }
        return true
    }

    private var wrongFolderMessage: String {
        switch kind {
        case .codexHome:
            return L10n.historyFolderWrongCodex
        case .claudeProjects, .claudeConfigProjects:
            return L10n.historyFolderWrongClaude
        }
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
        // Reject a folder that isn't actually a history root (e.g. the user
        // picked ~ or the wrong subfolder) instead of silently authorizing it
        // and then importing nothing. May resolve to a child of the pick.
        guard let folder = kind.resolveSelectedFolder(url) else {
            errorMessage = wrongFolderMessage
            return
        }
        do {
            try HistoryRootAuthorizationStore.shared.authorize(kind: kind, url: folder)
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
