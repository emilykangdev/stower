// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stower",
    platforms: [.macOS(.v15), .iOS(.v17)],  // iOS only relevant for v3 photos app
    products: [
        .library(name: "StowerCore", targets: ["StowerCore"]),
        .library(name: "StowerPhotos", targets: ["StowerPhotos"]),
        .library(name: "StowerMessages", targets: ["StowerMessages"]),
        // The tested StowerMac UI library. The Xcode app links this product (Task
        // 5); only its four engine-coupled files import StowerMessages (precheck 6b).
        .library(name: "StowerMacUI", targets: ["StowerMacUI"]),
        // The target name alone does not name the binary; the explicit executable
        // product is what makes `swift run stower` resolve (eng Codex 6).
        .executable(name: "stower", targets: ["StowerCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/mattt/Madrid", exact: "0.4.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
        // Tokenizer for the semantic arm. Only the `Tokenizers` API is used; the
        // `Hub` download path stays mechanically shut (precheck greps `import Hub`).
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.17"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.19.0"),
        // TODO: swift-snapshot-testing removed from the v0 scaffold — its
        // SnapshotTesting module imports XCTest, which is unavailable under
        // Command Line Tools (`swift test` reports "no such module 'XCTest'").
        // Re-add once full Xcode is installed or an XCTest-free release ships,
        // when the first golden-file test is actually written.
        // mlx-swift added when StowerPhotos starts running FastVLM. Not in v0 scaffold.
    ],
    targets: [
        .target(
            name: "StowerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Transformers", package: "swift-transformers"),
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
                .product(name: "TypedStream", package: "Madrid"),
            ],
            path: "Sources/StowerMessages",
            exclude: ["README.md"]
        ),
        .target(
            // The StowerMac app's tested UI library. Depends on the LOCAL
            // StowerMessages target (the app is a client of the engine —
            // MacAppContract.md §2), not a .product. Only the four engine-coupled
            // files (StowerMessagesStartupAdapter, StowerLiveBoardDataSource,
            // StowerMessagesComposition, StowerMessagesMapping) import
            // StowerMessages; every other file talks to the app-owned boundary alone.
            name: "StowerMacUI",
            dependencies: [
                "StowerCore",
                "StowerMessages",
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/StowerMacUI"
        ),
        .executableTarget(
            name: "StowerCLI",
            dependencies: [
                "StowerCore",
                "StowerMessages",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/StowerCLI"
        ),
        .testTarget(
            name: "StowerCoreTests",
            dependencies: [
                "StowerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "Transformers", package: "swift-transformers"),
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
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/StowerMessagesTests"
        ),
        .testTarget(
            // Depends on BOTH StowerMacUI and StowerMessages: the adapter-mapping
            // tests drive StowerFakeMessagesEngine, which conforms to the engine's
            // StowerDebtBoardProviding.
            name: "StowerMacUITests",
            dependencies: ["StowerMacUI", "StowerMessages"],
            path: "Tests/StowerMacUITests"
        ),
    ]
)
