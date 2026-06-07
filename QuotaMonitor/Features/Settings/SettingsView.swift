import SwiftUI

// Top-level Settings window. Tab content lives in:
//   - GeneralSettingsTab.swift   (Language, menu bar window, polling, notify)
//   - AdvancedSettingsTab.swift  (CLI paths, keychain, database, CSV export,
//                                  pricing sync + restore)
//
// **Why two tabs:** General stays short on purpose so first-time users
// don't bounce off a wall of knobs. Advanced collects every "I know
// what I'm doing" toggle in one place — including the LiteLLM pricing
// sync, which used to live on its own tab around a read-only catalog
// table. Dropping the table left two buttons that fit naturally in
// Advanced.

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LocalizationStore.self) private var loc
    @State private var settings = SettingsStore.shared

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environment(settings)
                .environment(loc)
                .tabItem { Label(L10n.settingsTabGeneral, systemImage: "gearshape") }
            AdvancedSettingsTab()
                .environment(settings)
                .environment(env)
                .tabItem { Label(L10n.settingsTabAdvanced, systemImage: "wrench.and.screwdriver") }
        }
        // Use min + ideal instead of a fixed size. The previous
        // `.frame(width:height:)` pinned the content to a single
        // dimension, which made the Settings window non-resizable —
        // dragging the corners had no effect because the inner view
        // refused to grow. min keeps tabs from collapsing into illegible
        // widths; ideal is what the window opens at.
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 520)
        // Make every Text in Settings copyable. textSelection is an
        // environment value that propagates to descendant Text views, so
        // setting it once at the TabView root covers both tabs and
        // any future ones — easier than auditing every individual label.
        // Form controls (Toggle / Picker / Stepper labels) are unaffected
        // because they render as control text, not Text.
        .textSelection(.enabled)
        // Demote-on-close is owned by `AppWindowController.windowWillClose`
        // now that this is an AppKit-hosted window.
    }
}
