import SwiftUI

/// The view that lives in the macOS menu bar slot itself (NOT the
/// popover — that's `MenuBarContentView`). Renders a single
/// horizontal row showing the user's selected provider(s):
///   single-pick → "5h 23% · 7d 8%"
///   both        → "CX 5h 23% · 7d 8% | CC 5h 50% · 7d 12%"
/// Falls back to a static SF Symbol when no selected provider has
/// usable data yet (cold start, not signed in, transient API error).
/// Percent values follow Settings → General → Menu bar → Quota
/// percentage, so the same slot can show used or remaining quota.
///
/// **Why text instead of an icon.** Text in the menu bar is the
/// canonical pattern for "live quantity" indicators (Stats, iStat,
/// Bartender's battery widget). It tracks the user's appearance
/// (template-rendered as black-on-light / white-on-dark) and stays
/// readable at the system font's 9pt floor. A circular gauge at this
/// size loses fidelity under the 4-bin SF Symbol rendering steps.
///
/// **Always one line.** macOS reserves vertical padding inside the
/// menu-bar slot we can't reclaim, so any 2-row stack ends up
/// clipped — even at 8pt with zero VStack spacing the system still
/// eats the second row. We always render one row.
///
/// **Inline type hierarchy.** Within that one line the labels
/// ("5h" / "7d") render at 9pt medium and the percent values at
/// 11pt heavy monospacedDigit, separated by a thin space. This
/// turns the row into a caption→headline rhythm — the number is
/// the content, the label is supporting text — without needing a
/// second row. Between the two windows a slightly wider " · "
/// at the lighter weight reads as a calm pause; between providers
/// a triple space puts visible distance between "CX …" and
/// "CC …" without introducing yet another glyph.
///
/// **Provider tag in multi mode.** "CX" / "CC" prefix tells the user
/// which CLI each percent belongs to. We omit the prefix in
/// single-provider mode since there's nothing to disambiguate.
///
/// **No watch-mode rendering math here.** All percent picking is
/// done off the `AppEnvironment` snapshots (`latestRateLimits` /
/// `latestClaudeUsage`) so this view stays pure UI — no DB, no I/O,
/// no `Task`. Recomputes whenever those snapshots change because
/// `@Environment(AppEnvironment.self)` triggers it via Observation.
struct MenuBarLabelView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let rows = pickRows()
        Group {
            if rows.isEmpty {
                // Same icon the app shipped with before — keeps the menu
                // bar's visual identity stable when there's nothing
                // useful to show. The popover still works (it has its
                // own loading / sign-in copy).
                Image(systemName: "gauge.with.dots.needle.50percent")
            } else {
                // Mixed-font Text concatenation — SwiftUI converts
                // this to an NSAttributedString with per-run fonts,
                // which the menu-bar slot renders honoring each
                // run's size + weight. That gives us caption-style
                // labels and headline-weight values on one line
                // without breaking the slot's one-row constraint.
                // `.fixedSize` stops the system from squeezing the
                // intrinsic width when other bar items crowd in.
                styledTitle(rows)
                    .fixedSize()
            }
        }
        // First-launch onboarding is now opened by `AppDelegate` on
        // launch (via `WindowRouter`), not from this label. The label is
        // hosted in an AppKit `NSStatusItem` button and no longer has a
        // reliable `openWindow` action of its own.
    }

    // MARK: - styled rendering

    /// Builds the inline-hierarchy `Text` from the row list. Each
    /// piece is its own `Text(...).font(...)` so SwiftUI emits a
    /// proper AttributedString with mixed runs that the menu-bar
    /// slot's title rendering respects.
    ///
    /// Why three fonts:
    ///   * `label`  — 9pt medium, the caption ("5h" / "7d" / tag)
    ///   * `value`  — 11pt heavy monospacedDigit, the headline ("65%")
    ///   * `sep`    — 9pt regular, the punctuation (" · ", spacing)
    /// Putting the punctuation at the lighter weight keeps the eye
    /// moving from value to value without the separator competing
    /// for attention. monospacedDigit on the value side stops the
    /// bar from shifting horizontally as percentages flip between
    /// 1-digit and 2-digit (9% → 10%).
    private func styledTitle(_ rows: [Row]) -> Text {
        let label = Font.system(size: 9, weight: .medium, design: .rounded)
        let value = Font.system(size: 11, weight: .heavy, design: .rounded)
            .monospacedDigit()
        let sep = Font.system(size: 9, weight: .regular, design: .rounded)
        let multi = rows.count > 1

        func provider(_ r: Row) -> Text {
            var t = Text("")
            if multi {
                t = t + Text("\(r.tag) ").font(label.weight(.semibold))
            }
            // U+2009 THIN SPACE between label and value — couples
            // them tighter than a regular space without making the
            // glyphs touch.
            t = t + Text("5h\u{2009}").font(label)
            t = t + Text(r.fiveHour).font(value)
            t = t + Text("  ·  ").font(sep)
            t = t + Text("7d\u{2009}").font(label)
            t = t + Text(r.sevenDay).font(value)
            return t
        }

        var out = Text("")
        for (i, r) in rows.enumerated() {
            if i > 0 {
                // Triple space between providers — wider than the
                // intra-provider " · " so the two CLI groups read
                // as separate units without introducing a second
                // glyph (which would clutter the row).
                out = out + Text("   ").font(sep)
            }
            out = out + provider(r)
        }
        return out
    }

    // MARK: - data picking

    private struct Row {
        /// Two-letter provider tag ("CX" / "CC"). Visible prefix
        /// in multi-provider mode; suppressed in single mode.
        let tag: String
        /// "23%" / "5%" / "--" — already clamped + formatted.
        let fiveHour: String
        let sevenDay: String
    }

    private func pickRows() -> [Row] {
        // Order matters for the visible row — keep it stable across
        // renders (`Set` iteration is not stable) by hard-coding the
        // canonical "codex first, claude second" sequence.
        var out: [Row] = []
        for id in ["codex", "claude"] {
            guard settings.menuBarIconProviders.contains(id),
                  settings.enabledProviders.contains(id) else { continue }
            switch id {
            case "codex":
                guard let snap = env.latestRateLimits else { continue }
                let five = snap.primary?.usedPercent
                let seven = snap.secondary?.usedPercent
                // Drop the provider entirely if neither window has
                // a number — avoids "5h -- · 7d --" hogging width.
                guard five != nil || seven != nil else { continue }
                out.append(Row(tag: "CX",
                               fiveHour: format(five),
                               sevenDay: format(seven)))
            case "claude":
                guard let u = env.latestClaudeUsage else { continue }
                let five = u.fiveHour?.usedPercent
                let seven = u.sevenDay?.usedPercent
                guard five != nil || seven != nil else { continue }
                out.append(Row(tag: "CC",
                               fiveHour: format(five),
                               sevenDay: format(seven)))
            default: break
            }
        }
        return out
    }

    /// "23%" — clamped to 0...100, no decimals (the menu bar slot is
    /// too narrow to be precise and the popover already shows the
    /// exact figure to one decimal).
    private func format(_ pct: Double?) -> String {
        guard let pct else { return "--" }
        let display = settings.quotaDisplayMode.displayPercent(forUsedPercent: pct)
        return "\(Int(display.rounded()))%"
    }
}
