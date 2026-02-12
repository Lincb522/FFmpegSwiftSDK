// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FFmpegSwiftSDK",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "FFmpegSwiftSDK",
            targets: ["FFmpegSwiftSDK"]
        ),
    ],
    dependencies: [],
    targets: [
        // CFFmpeg: C bridging target with bundled headers
        // On macOS: links against Homebrew-installed FFmpeg dylibs
        // On iOS: the xcframework binaryTargets provide the static libs
        .target(
            name: "CFFmpeg",
            dependencies: [
                .target(name: "FFmpegLibs", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/CFFmpeg",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("avformat", .when(platforms: [.macOS])),
                .linkedLibrary("avcodec", .when(platforms: [.macOS])),
                .linkedLibrary("avutil", .when(platforms: [.macOS])),
                .linkedLibrary("swresample", .when(platforms: [.macOS])),
                .linkedLibrary("avfilter", .when(platforms: [.macOS])),
            ]
        ),

        // Single merged XCFramework for iOS (device + simulator)
        // 远程引用：从 GitHub Release 下载预编译的 xcframework
        .binaryTarget(
            name: "FFmpegLibs",
            url: "https://github.com/Lincb522/FFmpegSwiftSDK/releases/download/0.4.0/FFmpegLibs.xcframework.zip",
            checksum: "ac0db7b26d380eabe2051fdde7eb7becd6a5cd4e2c02ebdf93e8d5c9ffe532b8"
        ),

        .target(
            name: "FFmpegSwiftSDK",
            dependencies: [
                "CFFmpeg",
                .target(name: "FFmpegLibs", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
