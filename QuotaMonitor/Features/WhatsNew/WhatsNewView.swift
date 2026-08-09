import AppKit
import SwiftUI

struct WhatsNewView: View {
    @Environment(LocalizationStore.self) private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: WhatsNewContent
    @State private var selectedIndex = 0

    private var campaign: WhatsNewCampaign { content.campaign }
    private var selectedPage: WhatsNewPage {
        campaign.pages[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 34)
                .padding(.top, 26)
                .padding(.bottom, 18)

            VStack(spacing: 18) {
                WhatsNewMediaView(page: selectedPage, content: content)
                    .id(selectedPage.id)
                    .transition(.opacity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 720, maxHeight: 405)

                VStack(spacing: 7) {
                    Text(selectedPage.title.value(
                        for: localization.currentLanguage))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(selectedPage.body.value(
                        for: localization.currentLanguage))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 620)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id("copy-\(selectedPage.id)")
                .transition(.opacity)
            }
            .padding(.horizontal, 34)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: selectedIndex)

            Spacer(minLength: 18)
            footer
                .padding(.horizontal, 34)
                .padding(.bottom, 26)
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { WindowManager.shared.close("whats-new") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(campaign.title.value(for: localization.currentLanguage))
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(campaign.subtitle.value(for: localization.currentLanguage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty, version != "0.0.0" {
                Text(L10n.whatsNewVersion(version))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L10n.whatsNewPage(selectedIndex + 1,
                                   of: campaign.pages.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                ForEach(Array(campaign.pages.enumerated()), id: \.element.id) {
                    index, page in
                    Button {
                        selectedIndex = index
                    } label: {
                        Circle()
                            .fill(index == selectedIndex
                                  ? Color.accentColor
                                  : Color.secondary.opacity(0.28))
                            .frame(width: 7, height: 7)
                            .contentShape(Rectangle().inset(by: -5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.whatsNewPage(index + 1, of: campaign.pages.count))
                    .accessibilityValue(
                        page.title.value(for: localization.currentLanguage))
                }
            }

            Spacer()

            Button(L10n.whatsNewPrevious) {
                selectedIndex = WhatsNewPageNavigation.previousIndex(
                    from: selectedIndex,
                    pageCount: campaign.pages.count)
            }
            .disabled(selectedIndex == 0)
            .keyboardShortcut(.leftArrow, modifiers: [])

            if selectedIndex == campaign.pages.count - 1 {
                Button(L10n.whatsNewDone) {
                    WindowManager.shared.close("whats-new")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.whatsNewNext) {
                    selectedIndex = WhatsNewPageNavigation.nextIndex(
                        from: selectedIndex,
                        pageCount: campaign.pages.count)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
    }
}

enum WhatsNewPageNavigation {
    static func previousIndex(from index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return max(0, min(index - 1, pageCount - 1))
    }

    static func nextIndex(from index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return max(0, min(index + 1, pageCount - 1))
    }
}
