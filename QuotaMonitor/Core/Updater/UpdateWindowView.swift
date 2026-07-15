import SwiftUI

/// The main SwiftUI view for the custom update window.  Displays different
/// content depending on `state.phase` and provides Install / Skip / Later
/// buttons that call through to the Sparkle reply closures stored on the
/// state object.
struct UpdateWindowView: View {

    let state: UpdateWindowState

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            buttonBar
                .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    // MARK: - Content (phase-dependent)

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle, .done:
            Color.clear
        case .checking:
            checkingView
        case .updateAvailable:
            updateAvailableView
        case .downloading:
            downloadingView
        case .extracting:
            extractingView
        case .readyToInstall:
            readyToInstallView
        case .installing:
            installingView
        case .upToDate:
            upToDateView
        case .error(let message):
            errorView(message)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // App icon
            if let nsImage = NSApp.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 48, height: 48)
            }

            VStack(alignment: .leading, spacing: 2) {
                if state.isCritical {
                    criticalBadge
                }
                Text(L10n.updateVersionAvailable(state.newVersion))
                    .font(.headline)
                Text(L10n.updateCurrentVersion(state.currentVersion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 12)
    }

    private var criticalBadge: some View {
        Text(L10n.updateCriticalBadge)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red.opacity(0.15))
            .foregroundStyle(.red)
            .clipShape(Capsule())
    }

    // MARK: - Phase views

    private var checkingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.updateChecking)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var updateAvailableView: some View {
        VStack(spacing: 0) {
            header
            if state.hasReleaseNotes {
                AnimatedReleaseNotesView(htmlContent: state.releaseNotesHTML)
            } else if state.releaseNotesPending {
                loadingReleaseNotesView
            } else {
                noReleaseNotesView
            }
        }
    }

    /// Shown while Sparkle downloads the linked release notes
    /// (`sparkle:releaseNotesLink`). Keeps the window from flashing the
    /// "no release notes" placeholder in the brief window between the update
    /// dialog appearing and the notes arriving.
    private var loadingReleaseNotesView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.updateLoadingReleaseNotes)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Shown when an update has no release notes — a calm placeholder rather
    /// than a blank WebView. The update itself is still installable.
    private var noReleaseNotesView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.plaintext")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L10n.updateNoReleaseNotes)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var downloadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: state.downloadProgress) {
                Text(L10n.updateDownloading)
            } currentValueLabel: {
                if state.totalBytes > 0 {
                    Text(state.downloadProgressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .progressViewStyle(.linear)
            Spacer()
        }
    }

    private var extractingView: some View {
        VStack(spacing: 12) {
            Spacer()
            if state.extractionProgress > 0 {
                ProgressView(value: state.extractionProgress) {
                    Text(L10n.updateExtracting)
                }
                .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                Text(L10n.updateExtracting)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var readyToInstallView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(L10n.updateReadyToInstall)
                .font(.headline)
            Spacer()
        }
    }

    private var installingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.updateInstalling)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var upToDateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(L10n.updateUpToDate)
                .font(.headline)
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Button bar

    @ViewBuilder
    private var buttonBar: some View {
        switch state.phase {
        case .updateAvailable, .readyToInstall:
            actionButtons
        case .error:
            HStack {
                Spacer()
                Button(L10n.done) { state.fireAcknowledge() }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading:
            HStack {
                Spacer()
                Button(L10n.cancel) { state.fireCancel() }
                    .buttonStyle(.bordered)
            }
        default:
            EmptyView()
        }
    }

    private var actionButtons: some View {
        HStack {
            if state.availableActions.contains(.skip) {
                Button(L10n.updateSkipButton) { state.fireSkip() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button(L10n.updateLaterButton) { state.fireDismiss() }
                .buttonStyle(.bordered)
            Button(state.phase == .readyToInstall
                   ? L10n.updateInstallAndRelaunch
                   : L10n.updateInstallButton) {
                state.fireInstall()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
