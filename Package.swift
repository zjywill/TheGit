// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TheGit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        // The AI provider layer: 5 wire protocols, ~50 providers, one
        // normalized event stream. Pinned by revision in Package.resolved —
        // the package carries no tags yet.
        .package(url: "https://github.com/zjywill/aikitswift", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "TheGit",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "AIKit", package: "aikitswift"),
            ],
            path: "Sources/TheGit"
        ),
        .testTarget(
            name: "TheGitTests",
            dependencies: ["TheGit"],
            path: "Tests/TheGitTests"
        ),
    ]
)
