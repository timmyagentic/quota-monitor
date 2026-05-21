// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuotaMonitor",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        // Auto-update framework. Ed25519-signed appcast means we can ship
        // secure updates without an Apple Developer ID. See
        // docs/release.md for the key generation + per-release workflow.
        // SwiftPM-as-app gotcha: Sparkle.framework must be hand-copied
        // into Contents/Frameworks/ by build.sh — SwiftPM won't do that.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "QuotaMonitor",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "QuotaMonitor",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "QuotaMonitorTests",
            dependencies: ["QuotaMonitor"],
            path: "Tests/QuotaMonitorTests",
            // Bundle JSON fixtures as resources so XCTest can locate them
            // via Bundle.module regardless of working directory. Keep the
            // _comment-key fixtures human-editable — no preprocessing.
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
