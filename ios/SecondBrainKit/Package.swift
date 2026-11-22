// swift-tools-version:5.9
// Models, API client and date helpers for the Second Brain app. Foundation only, so it builds and
// tests on Linux too (the tests decode real responses saved by the brain's test suite).
import PackageDescription

let package = Package(
    name: "SecondBrainKit",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [.library(name: "SecondBrainKit", targets: ["SecondBrainKit"])],
    targets: [
        .target(name: "SecondBrainKit"),
        .testTarget(name: "SecondBrainKitTests", dependencies: ["SecondBrainKit"], resources: [.copy("Fixtures")]),
    ]
)
