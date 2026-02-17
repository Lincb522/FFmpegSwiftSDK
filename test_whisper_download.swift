#!/usr/bin/env swift

import Foundation

// 简单测试脚本：验证 WhisperKit 模型下载路径

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let modelDir = homeDir
    .appendingPathComponent("Library")
    .appendingPathComponent("Caches")
    .appendingPathComponent("huggingface")
    .appendingPathComponent("models")

print("WhisperKit 模型缓存目录:")
print(modelDir.path)
print()

// 检查目录是否存在
if FileManager.default.fileExists(atPath: modelDir.path) {
    print("✅ 缓存目录存在")
    
    // 列出已下载的模型
    do {
        let contents = try FileManager.default.contentsOfDirectory(atPath: modelDir.path)
        if contents.isEmpty {
            print("📦 没有已下载的模型")
        } else {
            print("📦 已下载的模型:")
            for item in contents {
                print("  - \(item)")
            }
        }
    } catch {
        print("❌ 无法读取目录: \(error)")
    }
} else {
    print("📦 缓存目录不存在（首次下载时会自动创建）")
}

print()
print("支持的模型:")
print("  - openai_whisper-tiny")
print("  - openai_whisper-base")
print("  - openai_whisper-small")
print("  - openai_whisper-medium")
print("  - openai_whisper-large-v3")
