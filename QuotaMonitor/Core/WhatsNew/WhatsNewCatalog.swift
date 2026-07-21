import Foundation

/// Versioned, offline product-showcase content bundled with the app.
///
/// Campaign IDs are the presentation boundary: keep the same ID across patch
/// releases, and change it only when a release contains product changes worth
/// interrupting an existing user to explain. This is intentionally independent
/// from onboarding and Sparkle release notes.
struct WhatsNewCatalog: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let featuredCampaignID: String
    let campaigns: [WhatsNewCampaign]

    var featuredCampaign: WhatsNewCampaign? {
        campaigns.first { $0.id == featuredCampaignID }
    }

    static func load(from resourceRoot: URL) throws -> WhatsNewContent {
        let whatsNewRoot = resourceRoot.appendingPathComponent(
            "WhatsNew", isDirectory: true)
        let manifestURL = whatsNewRoot.appendingPathComponent("catalog.json")
        let data = try Data(contentsOf: manifestURL)
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        guard let campaign = catalog.featuredCampaign else {
            throw WhatsNewCatalogError.missingFeaturedCampaign(
                catalog.featuredCampaignID)
        }
        return WhatsNewContent(campaign: campaign, resourceRoot: whatsNewRoot)
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw WhatsNewCatalogError.unsupportedSchema(schemaVersion)
        }
        guard !featuredCampaignID.isEmpty else {
            throw WhatsNewCatalogError.emptyIdentifier("featured campaign")
        }

        var campaignIDs: Set<String> = []
        for campaign in campaigns {
            guard !campaign.id.isEmpty else {
                throw WhatsNewCatalogError.emptyIdentifier("campaign")
            }
            guard campaignIDs.insert(campaign.id).inserted else {
                throw WhatsNewCatalogError.duplicateIdentifier(campaign.id)
            }
            guard !campaign.pages.isEmpty else {
                throw WhatsNewCatalogError.campaignHasNoPages(campaign.id)
            }

            var pageIDs: Set<String> = []
            for page in campaign.pages {
                guard !page.id.isEmpty else {
                    throw WhatsNewCatalogError.emptyIdentifier("page")
                }
                guard pageIDs.insert(page.id).inserted else {
                    throw WhatsNewCatalogError.duplicateIdentifier(page.id)
                }
                for path in page.media.resourcePaths {
                    guard Self.isSafeRelativeResourcePath(path) else {
                        throw WhatsNewCatalogError.unsafeResourcePath(path)
                    }
                }
            }
        }
        guard featuredCampaign != nil else {
            throw WhatsNewCatalogError.missingFeaturedCampaign(
                featuredCampaignID)
        }
    }

    /// Media is always local to `Contents/Resources/WhatsNew`. Reject remote,
    /// absolute, and parent-traversal paths before a view ever tries to load it.
    static func isSafeRelativeResourcePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("%"),
              URL(string: path)?.scheme == nil else { return false }
        let components = path.split(
            separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct WhatsNewContent: Equatable, Sendable {
    let campaign: WhatsNewCampaign
    let resourceRoot: URL

    func resourceURL(for relativePath: String) -> URL? {
        guard WhatsNewCatalog.isSafeRelativeResourcePath(relativePath) else {
            return nil
        }
        let url = resourceRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}

struct WhatsNewCampaign: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let autoPresent: Bool
    let title: WhatsNewLocalizedText
    let subtitle: WhatsNewLocalizedText
    let pages: [WhatsNewPage]
}

struct WhatsNewPage: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: WhatsNewLocalizedText
    let body: WhatsNewLocalizedText
    let media: WhatsNewMedia
}

struct WhatsNewLocalizedText: Decodable, Equatable, Sendable {
    let en: String
    let zhHans: String

    private enum CodingKeys: String, CodingKey {
        case en
        case zhHans = "zh-Hans"
    }

    func value(for language: LocalizationStore.Language) -> String {
        switch language {
        case .english: return en
        case .simplifiedChinese: return zhHans
        }
    }
}

enum WhatsNewMedia: Decodable, Equatable, Sendable {
    case image(path: String, accessibilityLabel: WhatsNewLocalizedText)
    case video(path: String,
               posterPath: String,
               accessibilityLabel: WhatsNewLocalizedText)

    var resourcePaths: [String] {
        switch self {
        case .image(let path, _):
            return [path]
        case .video(let path, let posterPath, _):
            return [path, posterPath]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, path, posterPath, accessibilityLabel
    }

    private enum MediaType: String, Decodable {
        case image, video
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MediaType.self, forKey: .type)
        let path = try container.decode(String.self, forKey: .path)
        let label = try container.decode(
            WhatsNewLocalizedText.self,
            forKey: .accessibilityLabel)
        switch type {
        case .image:
            self = .image(path: path, accessibilityLabel: label)
        case .video:
            self = .video(
                path: path,
                posterPath: try container.decode(String.self, forKey: .posterPath),
                accessibilityLabel: label)
        }
    }
}

enum WhatsNewCatalogError: Error, Equatable {
    case unsupportedSchema(Int)
    case emptyIdentifier(String)
    case duplicateIdentifier(String)
    case campaignHasNoPages(String)
    case unsafeResourcePath(String)
    case missingFeaturedCampaign(String)
}
