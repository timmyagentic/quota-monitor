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
