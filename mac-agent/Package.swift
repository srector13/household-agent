// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path to the Info.plist that gets embedded into the binary's __TEXT,__info_plist
// section. EventKit/TCC require NSRemindersFullAccessUsageDescription etc. even for a CLI tool.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlist = "\(packageDir)/Sources/MacAgent/Info.plist"

let package = Package(
    name: "MacAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-agent", targets: ["MacAgent"]),
    ],
    targets: [
        // Linux-only shim so the pure logic (and its tests) can be built off-Mac.
        // On macOS the SDK's `SQLite3` module is used instead.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "MacAgentCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MacAgent",
            dependencies: ["MacAgentCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "MacAgentCoreTests",
            dependencies: ["MacAgentCore"]
        ),
    ]
)
