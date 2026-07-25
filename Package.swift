// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TheGit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TheGit",
            path: "Sources/TheGit"
        ),
        .testTarget(
            name: "TheGitTests",
            dependencies: ["TheGit"],
            path: "Tests/TheGitTests"
        ),
    ]
)
