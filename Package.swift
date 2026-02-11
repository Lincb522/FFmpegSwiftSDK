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
            url: "https://github.com/Lincb522/FFmpegSwiftSDK/releases/download/0.2.0/FFmpegLibs.xcframework.zip",
            checksum: "7f774f68283784a7527b6d211d3b48fa81d716f146029f58b2ac84373b38c2d6"
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
