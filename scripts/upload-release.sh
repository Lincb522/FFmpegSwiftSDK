#!/bin/bash
# 上传 xcframework zip 到 GitHub Release
# 用法: ./scripts/upload-release.sh <tag>
# 依赖: gh (GitHub CLI) — brew install gh

set -e

TAG="${1:-0.2.0}"
ZIP_PATH="/tmp/FFmpegLibs.xcframework.zip"

if [ ! -f "$ZIP_PATH" ]; then
    echo "正在打包 xcframework..."
    zip -r "$ZIP_PATH" Frameworks/FFmpegLibs.xcframework/
fi

echo "checksum: $(swift package compute-checksum "$ZIP_PATH")"

# 创建 Release 并上传
echo "正在创建 GitHub Release $TAG 并上传..."
gh release create "$TAG" "$ZIP_PATH" \
    --title "v$TAG" \
    --notes "FFmpegSwiftSDK v$TAG — 包含预编译的 FFmpeg iOS xcframework" \
    --repo Lincb522/FFmpegSwiftSDK \
    2>/dev/null || \
gh release upload "$TAG" "$ZIP_PATH" --clobber --repo Lincb522/FFmpegSwiftSDK

echo "完成！远程项目现在可以通过 SPM 引用了。"
