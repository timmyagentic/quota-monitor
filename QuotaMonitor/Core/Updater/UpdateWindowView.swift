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
            if state.releaseNotesHTML.isEmpty {
                Spacer()
            } else {
                AnimatedReleaseNotesView(htmlContent: state.releaseNotesHTML)
            }
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
                Button(L10n.done) { state.onAcknowledge?() }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading:
            HStack {
                Spacer()
                Button(L10n.cancel) { state.onCancel?() }
                    .buttonStyle(.bordered)
            }
        default:
            EmptyView()
        }
    }

    private var actionButtons: some View {
        HStack {
            Button(L10n.updateSkipButton) { state.onSkip?() }
                .buttonStyle(.bordered)
            Spacer()
            Button(L10n.updateLaterButton) { state.onDismiss?() }
                .buttonStyle(.bordered)
            Button(state.phase == .readyToInstall
                   ? L10n.updateInstallAndRelaunch
                   : L10n.updateInstallButton) {
                state.onInstall?()
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.phase == .updateAvailable
                      && state.releaseNotesHTML.isEmpty)
        }
    }
}
