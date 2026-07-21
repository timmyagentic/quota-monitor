import AppKit
import AVFoundation
import Foundation
import Testing
@testable import QuotaMonitor

@Suite("What's New catalog")
struct WhatsNewCatalogTests {
    @Test("Bundled catalog resolves one image and one video campaign")
    func loadsFeaturedCampaignAndMedia() throws {
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))

        #expect(content.campaign.id == "2026-07-product-highlights")
        #expect(content.campaign.autoPresent)
        #expect(content.campaign.pages.count == 3)
        #expect(content.campaign.pages.contains {
            if case .image = $0.media { return true }
            return false
        })
        #expect(content.campaign.pages.contains {
            if case .video = $0.media { return true }
            return false
        })

        for page in content.campaign.pages {
            for path in page.media.resourcePaths {
                let url = try #require(content.resourceURL(for: path))
                #expect((try Data(contentsOf: url)).isEmpty == false)
            }
        }
    }

    @Test("Every image and video poster decodes")
    func imageAssetsDecode() throws {
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))

        for page in content.campaign.pages {
            let imagePaths: [String]
            switch page.media {
            case .image(let path, _):
                imagePaths = [path]
            case .video(_, let posterPath, _):
                imagePaths = [posterPath]
            }
            for path in imagePaths {
                let url = try #require(content.resourceURL(for: path))
                let image = try #require(NSImage(contentsOf: url))
                #expect(image.size.width > 0)
                #expect(image.size.height > 0)
            }
        }
    }

    @Test("Showcase video is short, silent, and locally playable")
    func videoAssetContract() async throws {
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))
        let videoPath = try #require(content.campaign.pages.compactMap { page in
            if case .video(let path, _, _) = page.media { return path }
            return nil
        }.first)
        let url = try #require(content.resourceURL(for: videoPath))
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        #expect((values.fileSize ?? 0) < 5_000_000)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(duration.seconds >= 2)
        #expect(duration.seconds <= 10)
        #expect(videoTracks.isEmpty == false)
        #expect(audioTracks.isEmpty)
        let formatDescriptions = try await videoTracks[0].load(
            .formatDescriptions)
        let formatDescription = try #require(formatDescriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(formatDescription)
            == kCMVideoCodecType_H264)
    }

    @Test("Campaign copy resolves independently in both supported languages")
    func localizesCampaignCopy() throws {
        let content = try WhatsNewCatalog.load(
            from: Self.repositoryRoot.appendingPathComponent("Resources"))

        #expect(content.campaign.title.value(for: .english) == "Product highlights")
        #expect(content.campaign.title.value(for: .simplifiedChinese) == "近期新功能")
        #expect(content.campaign.subtitle.value(for: .english).isEmpty == false)
        #expect(content.campaign.subtitle.value(
            for: .simplifiedChinese).isEmpty == false)
        for page in content.campaign.pages {
            #expect(page.title.value(for: .english).isEmpty == false)
            #expect(page.title.value(for: .simplifiedChinese).isEmpty == false)
            #expect(page.body.value(for: .english).isEmpty == false)
            #expect(page.body.value(for: .simplifiedChinese).isEmpty == false)
            let accessibilityLabel: WhatsNewLocalizedText
            switch page.media {
            case .image(_, let label), .video(_, _, let label):
                accessibilityLabel = label
            }
            #expect(accessibilityLabel.value(for: .english).isEmpty == false)
            #expect(accessibilityLabel.value(
                for: .simplifiedChinese).isEmpty == false)
        }
    }

    @Test("Catalog rejects remote, absolute, and parent-traversal media")
    func rejectsUnsafeResourcePaths() {
        #expect(WhatsNewCatalog.isSafeRelativeResourcePath(
            "2026-07/dashboard.png"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "https://example.com/demo.mp4"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "/tmp/demo.mp4"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "../demo.mp4"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "2026-07/../demo.mp4"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "2026-07/%2E%2E/demo.mp4"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "2026-07//demo.mp4"))
        #expect(!WhatsNewCatalog.isSafeRelativeResourcePath(
            "2026-07\\demo.mp4"))
    }

    @Test("Manual app assembly copies the complete media directory")
    func buildScriptEmbedsMedia() throws {
        let buildScript = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("build.sh"),
            encoding: .utf8)
        #expect(buildScript.contains("WHATS_NEW_RESOURCES=\"Resources/WhatsNew\""))
        #expect(buildScript.contains(
            "cp -R \"${WHATS_NEW_RESOURCES}\" \"${CONTENTS}/Resources/WhatsNew\""))
    }

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/")
    }()
}
