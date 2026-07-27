import AppKit
import AVKit
import Combine
import SwiftUI

struct WhatsNewMediaView: View {
    @Environment(LocalizationStore.self) private var localization

    let page: WhatsNewPage
    let content: WhatsNewContent

    var body: some View {
        Group {
            switch page.media {
            case .image(let path, let accessibilityLabel):
                image(
                    at: content.resourceURL(for: path),
                    accessibilityLabel: accessibilityLabel.value(
                        for: localization.currentLanguage))
            case .video(let path, let posterPath, let accessibilityLabel):
                WhatsNewVideoView(
                    videoURL: content.resourceURL(for: path),
                    posterURL: content.resourceURL(for: posterPath),
                    accessibilityLabel: accessibilityLabel.value(
                        for: localization.currentLanguage))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }

    @ViewBuilder
    private func image(at url: URL?, accessibilityLabel: String) -> some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(10)
                .accessibilityLabel(accessibilityLabel)
        } else {
            WhatsNewMediaUnavailableView()
        }
    }
}

private struct WhatsNewVideoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let videoURL: URL?
    let posterURL: URL?
    let accessibilityLabel: String

    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var userRequestedPlayback = false

    var body: some View {
        ZStack {
            if videoURL == nil {
                posterOrUnavailable
            } else if reduceMotion && !userRequestedPlayback {
                posterOrUnavailable
                VStack(spacing: 8) {
                    Text(L10n.whatsNewReducedMotion)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button(L10n.whatsNewPlayVideo) {
                        userRequestedPlayback = true
                        configurePlayback(looping: false)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(
                    cornerRadius: 12, style: .continuous))
            } else {
                WhatsNewAVPlayerView(
                    player: player,
                    accessibilityLabel: accessibilityLabel)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            configurePlayback(looping: true)
        }
        .onChange(of: reduceMotion) { _, shouldReduce in
            userRequestedPlayback = false
            tearDownPlayback()
            if !shouldReduce {
                configurePlayback(looping: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            player.pause()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { notification in
            guard isWhatsNewWindow(notification.object) else { return }
            player.pause()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { notification in
            guard isWhatsNewWindow(notification.object), !reduceMotion else {
                return
            }
            if player.currentItem == nil {
                configurePlayback(looping: true)
            } else {
                player.play()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification)) { notification in
            guard isWhatsNewWindow(notification.object) else { return }
            userRequestedPlayback = false
            tearDownPlayback()
        }
        .onDisappear { tearDownPlayback() }
    }

    @ViewBuilder
    private var posterOrUnavailable: some View {
        if let posterURL, let poster = NSImage(contentsOf: posterURL) {
            Image(nsImage: poster)
                .resizable()
                .scaledToFit()
                .padding(10)
                .accessibilityLabel(accessibilityLabel)
        } else {
            WhatsNewMediaUnavailableView()
        }
    }

    private func configurePlayback(looping: Bool) {
        tearDownPlayback()
        guard let videoURL else { return }
        player.isMuted = true
        if looping {
            looper = AVPlayerLooper(
                player: player,
                templateItem: AVPlayerItem(url: videoURL))
        } else {
            player.insert(AVPlayerItem(url: videoURL), after: nil)
        }
        player.play()
    }

    private func tearDownPlayback() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    private func isWhatsNewWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier?.rawValue == "whats-new"
    }
}

/// AppKit-backed playback avoids coupling this long-lived window to
/// `_AVKit_SwiftUI`'s private `VideoPlayer` bridge. The native player view also
/// gives macOS users familiar inline controls while the SwiftUI owner retains
/// responsibility for muting, looping, and teardown.
private struct WhatsNewAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let accessibilityLabel: String

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        view.setAccessibilityLabel(accessibilityLabel)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.setAccessibilityLabel(accessibilityLabel)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

struct WhatsNewMediaUnavailableView: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28, weight: .medium))
            Text(L10n.whatsNewMediaUnavailable)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
