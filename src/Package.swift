// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "superproxy",
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "superproxy",
            dependencies: [.product(name: "Swifter", package: "swifter")]),
    ]
)
