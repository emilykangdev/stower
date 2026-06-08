// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stower",
    platforms: [.macOS(.v15), .iOS(.v17)],  // iOS only relevant for v3 photos app
    products: [
        .library(name: "StowerCore", targets: ["StowerCore"]),
        .library(name: "StowerPhotos", targets: ["StowerPhotos"]),
        .library(name: "StowerMessages", targets: ["StowerMessages"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
        // TODO: swift-snapshot-testing removed from the v0 scaffold — its
        // SnapshotTesting module imports XCTest, which is unavailable under
        // Command Line Tools (`swift test` reports "no such module 'XCTest'").
        // Re-add once full Xcode is installed or an XCTest-free release ships,
        // when the first golden-file test is actually written.
        // Madrid (attributedBody parser) deferred per D2 — add when implementing chat.db reader.
        // mlx-swift added when StowerPhotos starts running FastVLM. Not in v0 scaffold.
    ],
    targets: [
        .target(
            name: "StowerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Sources/StowerCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "StowerPhotos",
            dependencies: ["StowerCore"],
            path: "Sources/StowerPhotos",
            exclude: ["README.md"]
        ),
        .target(
            name: "StowerMessages",
            dependencies: [
                "StowerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                // Madrid deferred per D2 — add when implementing the chat.db reader.
            ],
            path: "Sources/StowerMessages",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "StowerCoreTests",
            dependencies: [
                "StowerCore",
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/StowerCoreTests"
        ),
        .testTarget(
            name: "StowerPhotosTests",
            dependencies: [
                "StowerPhotos",
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/StowerPhotosTests"
        ),
        .testTarget(
            name: "StowerMessagesTests",
            dependencies: [
                "StowerMessages",
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/StowerMessagesTests"
        ),
    ]
)
