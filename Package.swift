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
            url: "https://github.com/Lincb522/FFmpegSwiftSDK/releases/download/0.3.0/FFmpegLibs.xcframework.zip",
            checksum: "44badabd5d362561e74cbb914db3e42a263f332c51fa4c18f6c2600a47ab52c5"
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
