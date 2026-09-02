// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "macrowhisper",
    platforms: [
        .macOS("12.4"),
    ],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "macrowhisper",
            dependencies: [.product(name: "Swifter", package: "swifter")],
            path: "macrowhisper",
            exclude: [
                ".DS_Store",
                "Info.plist",
                "macrowhisper.entitlements",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
