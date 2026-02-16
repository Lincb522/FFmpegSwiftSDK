#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════════
# FFmpeg xcframework 打包 + GitHub Release 上传 + Package.swift 更新
# 一键脚本，避免 pty 中断问题
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build-ffmpeg"
RELEASE_TAG="0.5.0"
SDK_TAG="1.1.12"
REPO="Lincb522/FFmpegSwiftSDK"

DEVICE_PREFIX="$BUILD_DIR/output-iphoneos-arm64"
SIM_ARM64="$BUILD_DIR/output-iphonesimulator-arm64"
SIM_X86="$BUILD_DIR/output-iphonesimulator-x86_64"
SIM_PREFIX="$BUILD_DIR/output-iphonesimulator-fat"

# 如果 fat 目录不存在，先用 lipo 合并
if [ ! -d "$SIM_PREFIX" ]; then
    echo ">>> 合并模拟器架构 (arm64 + x86_64)..."
    mkdir -p "$SIM_PREFIX/lib"
    cp -R "$SIM_ARM64/include" "$SIM_PREFIX/include"
    for LIB in libavformat libavcodec libavutil libswresample libswscale libavfilter; do
        if [ -f "$SIM_ARM64/lib/${LIB}.a" ] && [ -f "$SIM_X86/lib/${LIB}.a" ]; then
            lipo -create "$SIM_ARM64/lib/${LIB}.a" "$SIM_X86/lib/${LIB}.a" -output "$SIM_PREFIX/lib/${LIB}.a"
        elif [ -f "$SIM_ARM64/lib/${LIB}.a" ]; then
            cp "$SIM_ARM64/lib/${LIB}.a" "$SIM_PREFIX/lib/${LIB}.a"
        fi
    done
fi

echo "=== Step 1: 合并静态库 (libtool -static) ==="

# 每个平台合并 6 个 .a 为一个
for PLATFORM_PREFIX in "$DEVICE_PREFIX" "$SIM_PREFIX"; do
    PLATFORM_NAME=$(basename "$PLATFORM_PREFIX")
    echo "  合并 $PLATFORM_NAME ..."
    libtool -static -o "$PLATFORM_PREFIX/lib/FFmpegLibs.a" \
        "$PLATFORM_PREFIX/lib/libavformat.a" \
        "$PLATFORM_PREFIX/lib/libavcodec.a" \
        "$PLATFORM_PREFIX/lib/libavutil.a" \
        "$PLATFORM_PREFIX/lib/libswresample.a" \
        "$PLATFORM_PREFIX/lib/libswscale.a" \
        "$PLATFORM_PREFIX/lib/libavfilter.a"
    echo "  => $(du -h "$PLATFORM_PREFIX/lib/FFmpegLibs.a" | cut -f1)"
done

echo ""
echo "=== Step 2: 清理平台特定头文件 ==="

# 删除 Windows/Linux/CUDA/Vulkan 等不需要的头文件
for PREFIX in "$DEVICE_PREFIX" "$SIM_PREFIX"; do
    for header in d3d11va.h dxva2.h hwcontext_cuda.h hwcontext_d3d11va.h \
        hwcontext_d3d12va.h hwcontext_dxva2.h hwcontext_vulkan.h \
        hwcontext_drm.h hwcontext_vaapi.h hwcontext_vdpau.h \
        hwcontext_opencl.h hwcontext_qsv.h hwcontext_mediacodec.h \
        hwcontext_amf.h hwcontext_oh.h; do
        find "$PREFIX/include" -name "$header" -delete 2>/dev/null || true
    done
done
echo "  清理完成"

echo ""
echo "=== Step 3: 创建 xcframework ==="

XCFW_DIR="$BUILD_DIR/FFmpegLibs.xcframework"
rm -rf "$XCFW_DIR"

xcodebuild -create-xcframework \
    -library "$DEVICE_PREFIX/lib/FFmpegLibs.a" \
    -headers "$DEVICE_PREFIX/include" \
    -library "$SIM_PREFIX/lib/FFmpegLibs.a" \
    -headers "$SIM_PREFIX/include" \
    -output "$XCFW_DIR"

echo "  xcframework 创建成功"

echo ""
echo "=== Step 4: 打包 zip ==="

ZIP_PATH="$BUILD_DIR/FFmpegLibs.xcframework.zip"
rm -f "$ZIP_PATH"
cd "$BUILD_DIR"
zip -r -y "FFmpegLibs.xcframework.zip" "FFmpegLibs.xcframework" -x "*.DS_Store"
echo "  zip 大小: $(du -h "$ZIP_PATH" | cut -f1)"

echo ""
echo "=== Step 5: 计算 checksum ==="

CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
echo "  checksum: $CHECKSUM"

echo ""
echo "=== Step 6: 上传 GitHub Release ($RELEASE_TAG) ==="

cd "$PROJECT_DIR"

# 删除旧 release（如果存在）
gh release delete "$RELEASE_TAG" --yes 2>/dev/null || true
git tag -d "$RELEASE_TAG" 2>/dev/null || true
git push origin ":refs/tags/$RELEASE_TAG" 2>/dev/null || true

# 创建新 release 并上传
gh release create "$RELEASE_TAG" \
    "$ZIP_PATH" \
    --title "FFmpeg 8.0 iOS Binary (with HTTPS/TLS)" \
    --notes "FFmpeg 8.0 预编译静态库 (arm64 device + arm64/x86_64 simulator)
包含: avformat, avcodec, avutil, swresample, swscale, avfilter
新增: SecureTransport TLS 支持 (HTTPS 协议可用)
硬件加速: VideoToolbox (H.264/HEVC)
音频滤镜: equalizer, superequalizer, volume, loudnorm, atempo"

echo "  上传完成"

echo ""
echo "=== Step 7: 更新 Package.swift ==="

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/FFmpegLibs.xcframework.zip"

# 用 sed 替换 Package.swift 中的 url 和 checksum
sed -i '' "s|url: \"https://github.com/$REPO/releases/download/[^\"]*\"|url: \"$DOWNLOAD_URL\"|" "$PROJECT_DIR/Package.swift"
sed -i '' "s|checksum: \"[a-f0-9]*\"|checksum: \"$CHECKSUM\"|" "$PROJECT_DIR/Package.swift"

echo "  Package.swift 已更新"
echo "  URL: $DOWNLOAD_URL"
echo "  Checksum: $CHECKSUM"

echo ""
echo "=== Step 8: 提交 + 打 SDK tag ($SDK_TAG) + 推送 ==="

cd "$PROJECT_DIR"
git add -A
git commit -m "feat: FFmpeg 8.0 with SecureTransport HTTPS - binary $RELEASE_TAG, SDK $SDK_TAG"
git tag -a "$SDK_TAG" -m "SDK $SDK_TAG - 新增 HTTPS/TLS 支持 (SecureTransport)"
git push origin main --tags

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  全部完成!"
echo "  二进制 Release: $RELEASE_TAG"
echo "  SDK Tag: $SDK_TAG"
echo "  Checksum: $CHECKSUM"
echo ""
echo "  下一步: 在 asidemusic-main 中更新 Package.swift"
echo "  将 FFmpegSwiftSDK 版本改为 from: \"$SDK_TAG\""
echo "═══════════════════════════════════════════════════════"
