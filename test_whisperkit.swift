#!/usr/bin/env swift

// 测试 WhisperKit 模型下载
// 运行: swift test_whisperkit.swift

import Foundation

print("🎤 WhisperKit 模型下载测试")
print(String(repeating: "=", count: 50))
print()

// 检查缓存目录
let homeDir = FileManager.default.homeDirectoryForCurrentUser
let cacheDir = homeDir
    .appendingPathComponent("Library")
    .appendingPathComponent("Caches")
    .appendingPathComponent("huggingface")

print("📁 缓存目录: \(cacheDir.path)")

if FileManager.default.fileExists(atPath: cacheDir.path) {
    print("✅ 缓存目录存在")
    
    // 列出已下载的内容
    do {
        let contents = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        if contents.isEmpty {
            print("📦 缓存为空")
        } else {
            print("📦 缓存内容:")
            for item in contents {
                let itemPath = cacheDir.appendingPathComponent(item)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: itemPath.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        // 列出子目录
                        if let subContents = try? FileManager.default.contentsOfDirectory(atPath: itemPath.path) {
                            print("  📂 \(item)/")
                            for subItem in subContents {
                                print("    - \(subItem)")
                            }
                        }
                    } else {
                        print("  📄 \(item)")
                    }
                }
            }
        }
    } catch {
        print("❌ 无法读取缓存目录: \(error)")
    }
} else {
    print("📦 缓存目录不存在（首次下载时会自动创建）")
}

print()
print("📋 支持的模型:")
let models = [
    "openai_whisper-tiny",
    "openai_whisper-base", 
    "openai_whisper-small",
    "openai_whisper-medium",
    "openai_whisper-large-v3"
]

for model in models {
    print("  - \(model)")
}

print()
print("💡 提示:")
print("  1. 首次使用时，WhisperKit 会自动从 HuggingFace 下载模型")
print("  2. 模型会缓存在 ~/Library/Caches/huggingface/")
print("  3. 下载速度取决于网络连接")
print("  4. tiny 模型约 40MB，base 约 150MB，small 约 500MB")
