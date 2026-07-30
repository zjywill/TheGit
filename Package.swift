// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TheGit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "TheGit",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/TheGit",
            // Reachable through Bundle.module. scripts/bundle.sh has to copy
            // the generated TheGit_TheGit.bundle into the .app alongside the
            // binary, or the packaged build finds no catalog.
            resources: [.copy("Resources/providers.json")]
        ),
        .testTarget(
            name: "TheGitTests",
            dependencies: ["TheGit"],
            path: "Tests/TheGitTests"
        ),
    ]
)
