import Foundation

/// CSS + JS animation framework for release-notes HTML rendered in the
/// custom update window's WKWebView.  All content is inline — no external
/// resources needed.
///
/// The HTML is structured as a two-tier layout:
/// 1. **Summary** (``<div class="release-summary">``) — always visible,
///    short bullets extracted from `#### Summary` in the changelog.
/// 2. **Details** (``<div class="release-details">``) — hidden by default,
///    expanded by a toggle button, contains the full `### Added / Fixed …`
///    sections.
///
/// Animations use `IntersectionObserver` so items fade/slide in as they
/// scroll into view.  `prefers-reduced-motion` disables all motion.
enum ReleaseNotesCSS {

    // MARK: - Content detection

    /// Whether `rawHTML` (an appcast `<description>` body, before wrapping)
    /// carries any renderable content. The update window uses this to choose
    /// between the WebView and a graceful "no notes" fallback: `wrapHTML`
    /// always returns a non-empty document, so emptiness can't be judged on
    /// the wrapped string.
    static func hasContent(_ rawHTML: String?) -> Bool {
        guard let rawHTML else { return false }
        return !rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Full HTML document

    /// Wraps raw body HTML in a complete document with our styles and
    /// animation script injected.
    ///
    /// - Parameters:
    ///   - body: The inner HTML (summary + details structure).
    ///   - isDark: Whether to use the dark colour scheme.
    ///   - locale: The user's locale identifier (e.g. `"en"`, `"zh-Hans"`).
    static func wrapHTML(_ body: String, isDark: Bool, locale: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(locale)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(stylesheet(isDark: isDark))
        </style>
        </head>
        <body>
        \(body)
        <script>
        \(animationScript)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - CSS

    /// Complete `<style>` block content.
    static func stylesheet(isDark: Bool) -> String {
        let vars = isDark ? darkVars : lightVars
        return """
        \(vars)

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
                         "Helvetica Neue", sans-serif;
            font-size: 13px;
            line-height: 1.55;
            color: var(--qm-text);
            background: transparent;
            -webkit-font-smoothing: antialiased;
        }

        /* ── Summary section ────────────────────────────────── */

        .release-summary ul {
            list-style: none;
            padding: 0;
        }

        .release-summary li {
            padding: 6px 0 6px 20px;
            position: relative;
            opacity: 0;
            transform: translateY(10px);
            transition: opacity 0.35s ease-out, transform 0.35s ease-out;
        }

        .release-summary li.visible {
            opacity: 1;
            transform: translateY(0);
        }

        .release-summary li::before {
            content: "";
            position: absolute;
            left: 2px;
            top: 12px;
            width: 6px;
            height: 6px;
            border-radius: 50%;
            background: var(--qm-accent);
        }

        /* ── Details toggle button ──────────────────────────── */

        .details-toggle {
            display: inline-block;
            margin-top: 10px;
            padding: 4px 0;
            border: none;
            background: none;
            color: var(--qm-accent);
            font-size: 12px;
            font-family: inherit;
            cursor: pointer;
            -webkit-appearance: none;
        }

        .details-toggle:hover {
            text-decoration: underline;
        }

        .details-toggle .arrow {
            display: inline-block;
            transition: transform 0.2s ease;
        }

        .details-toggle.expanded .arrow {
            transform: rotate(180deg);
        }

        /* ── Full details section ───────────────────────────── */

        .release-details {
            display: none;
            margin-top: 10px;
            padding-top: 10px;
            border-top: 1px solid var(--qm-border);
        }

        .release-details.visible-section {
            display: block;
        }

        .release-details h3 {
            font-size: 12px;
            font-weight: 600;
            color: var(--qm-secondary);
            text-transform: uppercase;
            letter-spacing: 0.3px;
            margin-top: 12px;
            margin-bottom: 4px;
            opacity: 0;
            transform: translateX(-6px);
            transition: opacity 0.3s ease-out, transform 0.3s ease-out;
        }

        .release-details h3.visible {
            opacity: 1;
            transform: translateX(0);
        }

        .release-details ul {
            list-style: none;
            padding: 0;
        }

        .release-details li {
            padding: 3px 0 3px 16px;
            position: relative;
            font-size: 12px;
            color: var(--qm-secondary);
            opacity: 0;
            transform: translateY(8px);
            transition: opacity 0.3s ease-out, transform 0.3s ease-out;
        }

        .release-details li.visible {
            opacity: 1;
            transform: translateY(0);
        }

        .release-details li::before {
            content: "";
            position: absolute;
            left: 2px;
            top: 9px;
            width: 4px;
            height: 4px;
            border-radius: 50%;
            background: var(--qm-border);
        }

        /* ── Inline markup ──────────────────────────────────── */

        b { font-weight: 600; }

        code {
            font-family: "SF Mono", "Menlo", "Monaco", monospace;
            font-size: 11.5px;
            background: var(--qm-code-bg);
            padding: 1px 4px;
            border-radius: 3px;
        }

        /* ── Accessibility ──────────────────────────────────── */

        @media (prefers-reduced-motion: reduce) {
            .release-summary li,
            .release-details li,
            .release-details h3 {
                opacity: 1;
                transform: none;
                transition: none;
            }
        }
        """
    }

    // MARK: - JavaScript

    /// Inline `<script>` content for scroll-triggered animations and
    /// the details-toggle handler.
    static var animationScript: String {
        """
        (function () {
            var step = 70;

            // Summary items animate immediately (no scroll needed).
            var summaryItems = document.querySelectorAll(
                '.release-summary li');
            summaryItems.forEach(function (el, i) {
                el.style.transitionDelay = (i * step) + 'ms';
                setTimeout(function () {
                    el.classList.add('visible');
                }, 30);
            });

            // Detail items use IntersectionObserver.
            var observer = new IntersectionObserver(
                function (entries) {
                    entries.forEach(function (entry) {
                        if (entry.isIntersecting) {
                            var idx = Array.from(
                                entry.target.parentNode.children
                            ).indexOf(entry.target);
                            entry.target.style.transitionDelay =
                                (idx * step) + 'ms';
                            entry.target.classList.add('visible');
                            observer.unobserve(entry.target);
                        }
                    });
                },
                { threshold: 0.1 }
            );

            document.querySelectorAll(
                '.release-details li, .release-details h3'
            ).forEach(function (el) { observer.observe(el); });

            // Details toggle button.
            var btn = document.querySelector('.details-toggle');
            var details = document.querySelector('.release-details');
            if (!btn || !details) return;

            var showLabel = btn.getAttribute('data-show');
            var hideLabel = btn.getAttribute('data-hide');

            btn.addEventListener('click', function () {
                var expanded =
                    details.classList.contains('visible-section');
                if (expanded) {
                    details.classList.remove('visible-section');
                    btn.classList.remove('expanded');
                    btn.innerHTML = showLabel +
                        ' <span class="arrow">&#x25BE;</span>';
                } else {
                    details.classList.add('visible-section');
                    btn.classList.add('expanded');
                    btn.innerHTML = hideLabel +
                        ' <span class="arrow">&#x25BE;</span>';

                    // Trigger animations for newly visible items.
                    details.querySelectorAll('li, h3').forEach(
                        function (el, i) {
                            el.style.transitionDelay =
                                (i * step) + 'ms';
                            setTimeout(function () {
                                el.classList.add('visible');
                            }, 30);
                        }
                    );
                }
            });
        })();
        """
    }

    // MARK: - Colour variables

    private static var lightVars: String {
        """
        :root {
            --qm-text: #1d1d1f;
            --qm-secondary: #6e6e73;
            --qm-accent: #007AFF;
            --qm-border: #d2d2d7;
            --qm-code-bg: #f5f5f7;
        }
        """
    }

    private static var darkVars: String {
        """
        :root {
            --qm-text: #f5f5f7;
            --qm-secondary: #98989d;
            --qm-accent: #0A84FF;
            --qm-border: #38383a;
            --qm-code-bg: #2c2c2e;
        }
        """
    }
}
