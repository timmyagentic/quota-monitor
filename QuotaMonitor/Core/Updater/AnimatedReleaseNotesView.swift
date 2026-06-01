import SwiftUI
import WebKit

enum ReleaseNotesNavigationPolicy {
    static func shouldAllow(
        navigationType: WKNavigationType,
        url: URL?
    ) -> Bool {
        guard navigationType == .other else { return false }
        return url == nil || url?.absoluteString == "about:blank"
    }
}

/// An `NSViewRepresentable` that wraps a `WKWebView` for rendering the
/// animated release-notes HTML.  All CSS + JS is injected inline — no
/// external resources are loaded.  Navigation is blocked for security
/// (the update window should never navigate away from the inline content).
struct AnimatedReleaseNotesView: NSViewRepresentable {

    /// The complete HTML document string (already wrapped by
    /// `ReleaseNotesCSS.wrapHTML(…)`).
    let htmlContent: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent background so the SwiftUI window chrome shows
        // through (macOS WKWebView uses `underPageBackgroundColor`).
        webView.underPageBackgroundColor = .clear

        loadHTML(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(webView)
    }

    // MARK: - Private

    private func loadHTML(_ webView: WKWebView) {
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        /// Block all navigation requests — the release notes are fully
        /// self-contained and should never trigger a page load.
        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if ReleaseNotesNavigationPolicy.shouldAllow(
                navigationType: navigationAction.navigationType,
                url: navigationAction.request.url) {
                // Initial loadHTMLString call. WebKit reports it as
                // about:blank on current macOS, and older behaviour may
                // surface it as a nil URL.
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
