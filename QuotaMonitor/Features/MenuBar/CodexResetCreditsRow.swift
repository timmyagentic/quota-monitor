import SwiftUI

struct CodexResetCreditsRow: View {
    let snapshot: CodexResetCreditsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(L10n.codexResetCardsTitle)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(countLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(countColor)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.caption2)
                Text(detailLabel)
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    private var countLabel: String {
        snapshot.availableCount > 0
            ? L10n.codexResetCardsAvailable(snapshot.availableCount)
            : L10n.codexResetCardsNoActive
    }

    private var detailLabel: String {
        if let next = snapshot.nextExpiration {
            let formatted = LocalizedDateFormatting.string(
                from: next,
                style: .mediumDateShortTime)
            return L10n.codexResetCardsNextExpires(formatted)
        }
        return snapshot.availableCount > 0
            ? L10n.codexResetCardsExpiryUnavailable
            : L10n.codexResetCardsNoActive
    }

    private var helpText: String {
        guard !snapshot.credits.isEmpty else { return detailLabel }
        let lines = snapshot.credits
            .map { credit -> String in
                let formatted = LocalizedDateFormatting.string(
                    from: credit.expiresAt,
                    style: .mediumDateMediumTime)
                return "- \(formatted)"
            }
            .joined(separator: "\n")
        return L10n.codexResetCardsHelp(lines)
    }

    private var countColor: Color {
        snapshot.availableCount > 0 ? .blue : .secondary
    }
}
