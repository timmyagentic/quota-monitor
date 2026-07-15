import AppKit
import Testing
@testable import QuotaMonitor

@MainActor
@Suite("Menu-bar title builder")
struct MenuBarTitleBuilderTests {
    private struct MissingFont: Error {}

    @Test("Native style uses plain system menu-bar spacing")
    func nativeStyleUsesMenuBarFont() throws {
        let title = MenuBarTitleBuilder.make(
            rows: [.init(tag: "CX", fiveHour: "8%", sevenDay: "1%")],
            style: .native)

        #expect(title.string == "5h 8% · 7d 1%")

        let labelFont = try font(at: "5h", in: title)
        let valueFont = try font(at: "8%", in: title)
        let menuBarFont = NSFont.menuBarFont(ofSize: 0)

        #expect(labelFont.pointSize == menuBarFont.pointSize)
        #expect(valueFont.pointSize == menuBarFont.pointSize)
    }

    @Test("Emphasis style keeps the rounded weighted readout")
    func emphasisStyleUsesWeightedPercentages() throws {
        let title = MenuBarTitleBuilder.make(
            rows: [.init(tag: "CX", fiveHour: "8%", sevenDay: "1%")],
            style: .emphasis)

        #expect(title.string == "5h\u{2009}8%  ·  7d\u{2009}1%")

        let labelFont = try font(at: "5h", in: title)
        let valueFont = try font(at: "8%", in: title)

        #expect(labelFont.pointSize == 9)
        #expect(valueFont.pointSize == 11)
    }

    @Test("Weekly-only window omits the inactive 5-hour segment")
    func weeklyOnlyWindowOmitsFiveHourSegment() {
        let row = MenuBarLabelModel.Row(
            tag: "CX", fiveHour: "--", sevenDay: "64%")

        let native = MenuBarTitleBuilder.make(rows: [row], style: .native)
        let emphasis = MenuBarTitleBuilder.make(rows: [row], style: .emphasis)

        #expect(native.string == "7d 64%")
        #expect(emphasis.string == "7d\u{2009}64%")
    }

    @Test("Five-hour-only window omits the inactive weekly segment")
    func fiveHourOnlyWindowOmitsWeeklySegment() {
        let row = MenuBarLabelModel.Row(
            tag: "CX", fiveHour: "17%", sevenDay: "--")

        let native = MenuBarTitleBuilder.make(rows: [row], style: .native)
        let emphasis = MenuBarTitleBuilder.make(rows: [row], style: .emphasis)

        #expect(native.string == "5h 17%")
        #expect(emphasis.string == "5h\u{2009}17%")
    }

    @Test("No available windows retains the established placeholders")
    func unavailableWindowsRetainPlaceholders() {
        let row = MenuBarLabelModel.Row(
            tag: "CX", fiveHour: "--", sevenDay: "--")

        let native = MenuBarTitleBuilder.make(rows: [row], style: .native)
        let emphasis = MenuBarTitleBuilder.make(rows: [row], style: .emphasis)

        #expect(native.string == "5h -- · 7d --")
        #expect(emphasis.string == "5h\u{2009}--  ·  7d\u{2009}--")
    }

    @Test("Mixed-window providers retain stable tags and order")
    func mixedWindowProvidersRetainTags() {
        let rows = [
            MenuBarLabelModel.Row(tag: "CX", fiveHour: "--", sevenDay: "64%"),
            MenuBarLabelModel.Row(tag: "CC", fiveHour: "18%", sevenDay: "--")
        ]

        let native = MenuBarTitleBuilder.make(rows: rows, style: .native)
        let emphasis = MenuBarTitleBuilder.make(rows: rows, style: .emphasis)

        #expect(native.string == "CX 7d 64%   CC 5h 18%")
        #expect(emphasis.string == "CX 7d\u{2009}64%   CC 5h\u{2009}18%")
    }

    @Test("Multi-provider native style includes stable provider tags")
    func nativeStyleTagsMultipleProviders() {
        let title = MenuBarTitleBuilder.make(
            rows: [
                .init(tag: "CX", fiveHour: "8%", sevenDay: "1%"),
                .init(tag: "CC", fiveHour: "60%", sevenDay: "12%")
            ],
            style: .native)

        #expect(title.string == "CX 5h 8% · 7d 1%   CC 5h 60% · 7d 12%")
    }

    @Test("Missing update version returns the exact original attributed title")
    func missingUpdateVersionPreservesOriginalTitle() {
        let base = NSMutableAttributedString(
            string: "5h 42% · 7d 68%",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .kern: 0.4
            ])

        let nilResult = StatusItemUpdateMarker.title(base: base, version: nil)
        let emptyResult = StatusItemUpdateMarker.title(base: base, version: "")

        #expect(nilResult === base)
        #expect(emptyResult === base)
    }

    @Test("Update marker appends one orange suffix without changing base attributes")
    func updateMarkerPreservesBaseAttributes() {
        let base = NSMutableAttributedString(
            string: "5h 42% · ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
        base.append(NSAttributedString(
            string: "7d 68%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.systemBlue,
                .kern: 0.25
            ]))
        let original = base.copy() as! NSAttributedString

        let decorated = StatusItemUpdateMarker.title(base: base, version: "0.2.41")

        #expect(decorated.string == "5h 42% · 7d 68% ↓")
        #expect(base.isEqual(to: original))
        for index in 0..<base.length {
            #expect(
                NSDictionary(dictionary: decorated.attributes(at: index, effectiveRange: nil))
                    .isEqual(to: base.attributes(at: index, effectiveRange: nil)))
        }
        let markerRange = NSRange(location: base.length, length: 2)
        for index in markerRange.location..<NSMaxRange(markerRange) {
            let attributes = decorated.attributes(at: index, effectiveRange: nil)
            #expect(
                (attributes[.foregroundColor] as? NSColor)?
                    .isEqual(NSColor.systemOrange) == true)
            #expect(attributes.count == 1)
        }
    }

    @Test("Emphasis changes only marker styling and keeps the exact title width")
    func updateMarkerEmphasisKeepsFixedStringWidth() {
        let base = NSAttributedString(
            string: "5h 42% · 7d 68%",
            attributes: [.foregroundColor: NSColor.labelColor])

        let normal = StatusItemUpdateMarker.title(
            base: base,
            version: "0.2.41",
            emphasized: false)
        let emphasized = StatusItemUpdateMarker.title(
            base: base,
            version: "0.2.41",
            emphasized: true)

        #expect(normal.string == emphasized.string)
        #expect((normal.string as NSString).length == (emphasized.string as NSString).length)
        for index in 0..<base.length {
            #expect(NSDictionary(dictionary: normal.attributes(at: index, effectiveRange: nil))
                .isEqual(to: emphasized.attributes(at: index, effectiveRange: nil)))
        }
        let markerIndex = base.length
        #expect(normal.attribute(.backgroundColor, at: markerIndex, effectiveRange: nil) == nil)
        #expect(emphasized.attribute(.backgroundColor, at: markerIndex, effectiveRange: nil) != nil)
    }

    @Test("Accessibility label keeps quota copy and restores it after an update clears")
    func accessibilityLabelRestoresQuotaCopyAfterUpdateClears() {
        let base = NSAttributedString(string: "5h 42% · 7d 68%")
        let version = "0.2.41"
        let button = NSButton()
        button.attributedTitle = base

        let updateLabel = StatusItemUpdateMarker.accessibilityLabel(
            base: base,
            fallback: Branding.appDisplayName,
            version: version)
        button.setAccessibilityLabel(updateLabel)

        #expect(button.accessibilityLabel() == updateLabel)
        #expect(button.accessibilityLabel()?.contains(base.string) == true)
        #expect(button.accessibilityLabel()?.contains(version) == true)

        let restoredLabel = StatusItemUpdateMarker.accessibilityLabel(
            base: base,
            fallback: Branding.appDisplayName,
            version: nil)
        button.setAccessibilityLabel(restoredLabel)

        #expect(restoredLabel == base.string)
        #expect(button.accessibilityLabel() == base.string)
    }

    @Test("Gauge fallback always has an explicit accessible name")
    func gaugeFallbackHasExplicitAccessibleName() {
        let emptyTitle = NSAttributedString(string: "")
        let version = "0.2.41"

        let noUpdate = StatusItemUpdateMarker.accessibilityLabel(
            base: emptyTitle,
            fallback: Branding.appDisplayName,
            version: nil)
        let withUpdate = StatusItemUpdateMarker.accessibilityLabel(
            base: emptyTitle,
            fallback: Branding.appDisplayName,
            version: version)

        #expect(noUpdate == Branding.appDisplayName)
        #expect(withUpdate.contains(Branding.appDisplayName))
        #expect(withUpdate.contains(version))
    }

    private func font(at needle: String,
                      in title: NSAttributedString) throws -> NSFont {
        let range = (title.string as NSString).range(of: needle)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound,
              let font = title.attribute(
                .font,
                at: range.location,
                effectiveRange: nil) as? NSFont else {
            throw MissingFont()
        }
        return font
    }
}
