import SwiftUI

enum UpdateWindowLayout {
    static let contentSize = CGSize(width: 820, height: 640)
    static let minimumContentSize = CGSize(width: 680, height: 560)
}

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
        }
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.045),
                        Color.clear,
                        Color.purple.opacity(0.025),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
        }
        .frame(
            minWidth: UpdateWindowLayout.minimumContentSize.width,
            idealWidth: UpdateWindowLayout.contentSize.width,
            minHeight: UpdateWindowLayout.minimumContentSize.height,
            idealHeight: UpdateWindowLayout.contentSize.height)
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
        HStack(spacing: 14) {
            // App icon
            if let nsImage = NSApp.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.updateVersionAvailable(state.newVersion))
                    .font(.system(size: 19, weight: .semibold))
                HStack(spacing: 7) {
                    Text(state.currentVersion)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(state.newVersion)
                        .foregroundStyle(.primary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            if state.isCritical {
                criticalBadge
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.mint.opacity(0.045),
                    Color.clear,
                ],
                startPoint: .leading,
                endPoint: .trailing)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
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
        .padding(.horizontal, 120)
    }

    // MARK: - Button bar

    @ViewBuilder
    private var buttonBar: some View {
        switch state.phase {
        case .updateAvailable, .readyToInstall:
            actionShelf {
                actionButtons
            }
        case .error:
            actionShelf {
                HStack {
                    Spacer()
                    Button(L10n.done) { state.fireAcknowledge() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        case .downloading:
            actionShelf {
                HStack {
                    Spacer()
                    Button(L10n.cancel) { state.fireCancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        default:
            EmptyView()
        }
    }

    private func actionShelf<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
    }

    private var actionButtons: some View {
        HStack {
            if state.availableActions.contains(.skip) {
                Button(L10n.updateSkipButton) { state.fireSkip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            Spacer()
            Button(L10n.updateLaterButton) { state.fireDismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
            Button(state.phase == .readyToInstall
                   ? L10n.updateInstallAndRelaunch
                   : L10n.updateInstallButton) {
                state.fireInstall()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}
