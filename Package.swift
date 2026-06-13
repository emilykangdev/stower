// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stower",
    platforms: [.macOS(.v15), .iOS(.v17)],  // iOS only relevant for v3 photos app
    products: [
        .library(name: "StowerCore", targets: ["StowerCore"]),
        .library(name: "StowerPhotos", targets: ["StowerPhotos"]),
        .library(name: "StowerMessages", targets: ["StowerMessages"]),
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
    ]
)
