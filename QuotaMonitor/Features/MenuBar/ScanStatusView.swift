import SwiftUI

// Active scan progress row. Extracted from MenuBarContentView for readability.

extension MenuBarContentView {

    @ViewBuilder
    var scanStatus: some View {
        if let report = env.lastScanReport,
           report.hasPersistentDeferredSources {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.scanDeferredWarningTitle)
                        .font(.caption.weight(.semibold))
                    Text(L10n.scanDeferredWarningDetail(
                        count: report.persistentDeferredSourceCount,
                        consecutive: report.consecutiveDeferredCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }

        if env.scanPresentation == .detailedProgress,
           let progress = env.scanProgress {
            VStack(alignment: .leading, spacing: 5) {
                // Title + processed-count on the same row — they're
                // small enough that splitting into two stacked lines
                // wasted vertical space without adding clarity. Spacer
                // right-aligns the count so the digits line up between
                // updates (the monospacedDigit on the count locks the
                // glyph width too).
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.scanIndexingTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(L10n.scanProgressSummary(
                        completed: progress.completedFiles,
                        total: progress.totalFiles))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress.fraction ?? 0)
                    .progressViewStyle(.linear)
                if let file = progress.currentFile {
                    Text(L10n.scanCurrentFile(file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
