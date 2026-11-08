// swift-tools-version: 6.1
// FirmwareKit: IPSW -> emulated device preparation.
// Swift owns device preparation. Tests use frozen reference hashes and
// optional corpus inputs; strict acceptance fails when selected prerequisites are absent. Each module lives in its own
// subdirectory of Sources/FirmwareKit so agents can add modules without editing this file.
//
// Dependencies are pinned to exact versions and recorded with their licenses in build-support/dependencies.json
// (BuildTools' dependency sources manifest): ZIPFoundation (IPSW members), MachOKit (Mach-O headers, fat
// files, code signatures), swift-subprocess (`diskutil image` / `hdiutil` through DiskImage), Unrar.swift (a "rar"
// source's IPSW: RARLAB's UnRAR, extraction only), swift-argument-parser (the firmwarekit command
// lines, FirmwareSchema's FirmwareCommand).
import PackageDescription

// Off Apple platforms (Linux, Android, Windows): swift-crypto stands in for CryptoKit and CommonCrypto, swift-system
// for System, and HostRuntime's zlib module for the SDK's.
let nonApple: [Platform] = [.linux, .android, .windows]
// Android's SDK has its own zlib module (as Apple's do); Linux and Windows take HostRuntime's.
let noZlibModule: [Platform] = [.linux, .windows]

let package = Package(
    name: "FirmwareKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FirmwareKit", targets: ["FirmwareKit"]),
        .library(name: "FirmwareSchema", type: .static, targets: ["FirmwareSchema"]),
        .executable(name: "firmwarekit", targets: ["FirmwareKitCLI"]),
        // Standalone assertions for native CLT installations without SwiftTesting.
        .executable(name: "firmware-memory-probe", targets: ["FirmwareKitMemoryProbe"]),
    ],
    dependencies: [
        .package(path: "../HostRuntime"),
        // development after 0.9.20: its Android and Windows imports (weichsel/ZIPFoundation#380)
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", revision: "e7a17d57c583067eaa6659cd6d9521265b7664e9"),
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.53.0"),
        .package(url: "https://github.com/mtgto/Unrar.swift.git", exact: "0.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
    ],
    targets: [
        .target(
            name: "FirmwareSchema",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "CActivation", cSettings: [.define("LT_ACTIVATION_LIBRARY")]),
        // Linux and Android: AES-CBC through the libcrypto Foundation links already, and the fast cores (CHostFast.h).
        .target(name: "CHostFast", linkerSettings: [.linkedLibrary("crypto", .when(platforms: [.linux, .android]))]),
        .target(
            name: "FirmwareKit",
            dependencies: [
                "CActivation", "CHostFast", "FirmwareSchema",
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                // MachOKit builds on Apple platforms and Linux, not Android; MachOHeaders stands in off the Mac.
                .product(name: "MachOKit", package: "MachOKit", condition: .when(platforms: [.macOS])),
                .product(name: "Unrar", package: "Unrar.swift"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
                .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: nonApple)),
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: nonApple)),
                .product(name: "zlib", package: "HostRuntime", condition: .when(platforms: noZlibModule)),
                .product(name: "CPortability", package: "HostRuntime", condition: .when(platforms: nonApple)),
            ]
        ),
        .executableTarget(
            name: "FirmwareKitCLI",
            dependencies: [
                "FirmwareKit", "CHostFast",
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "FirmwareKitMemoryProbe", dependencies: ["FirmwareKit"]),
        .testTarget(
            name: "FirmwareKitTests",
            dependencies: [
                "FirmwareKit", "FirmwareSchema", .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
                .product(name: "zlib", package: "HostRuntime", condition: .when(platforms: noZlibModule)),
            ],
            exclude: ["iboot-trees"]  // KBootIBootTests reads them from the source tree
        ),
    ]
)
