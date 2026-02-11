#!/bin/bash
set -e

echo "=== Step 1: Remove platform-specific headers not needed on iOS/macOS ==="

HEADERS_DIR="Sources/CFFmpeg/include"

# Remove Windows/Linux-only headers that cause build failures
REMOVE_HEADERS=(
    "libavcodec/d3d11va.h"
    "libavcodec/dxva2.h"
    "libavcodec/qsv.h"
    "libavcodec/vdpau.h"
    "libavcodec/mediacodec.h"
    "libavcodec/jni.h"
    "libavcodec/smpte_436m.h"
    "libavutil/hwcontext_cuda.h"
    "libavutil/hwcontext_d3d11va.h"
    "libavutil/hwcontext_d3d12va.h"
    "libavutil/hwcontext_drm.h"
    "libavutil/hwcontext_dxva2.h"
    "libavutil/hwcontext_mediacodec.h"
    "libavutil/hwcontext_opencl.h"
    "libavutil/hwcontext_qsv.h"
    "libavutil/hwcontext_vaapi.h"
    "libavutil/hwcontext_vdpau.h"
    "libavutil/hwcontext_vulkan.h"
    "libavutil/hwcontext_amf.h"
    "libavutil/hwcontext_oh.h"
)

for h in "${REMOVE_HEADERS[@]}"; do
    if [ -f "$HEADERS_DIR/$h" ]; then
        rm "$HEADERS_DIR/$h"
        echo "  Removed $h"
    fi
done

echo ""
echo "=== Step 2: Remove same headers from xcframework ==="

for variant in Frameworks/FFmpegLibs.xcframework/*/Headers; do
    if [ -d "$variant" ]; then
        for h in "${REMOVE_HEADERS[@]}"; do
            if [ -f "$variant/$h" ]; then
                rm "$variant/$h"
                echo "  Removed $variant/$h"
            fi
        done
    fi
done

echo ""
echo "=== Step 3: Verify swift build on macOS ==="
swift build 2>&1 | tail -5

echo ""
echo "=== Step 4: Regenerate Xcode project ==="
xcodegen generate --spec Example/project.yml --project Example/ 2>&1

echo ""
echo "=== Done! Clean build in Xcode (Shift+Cmd+K) then rebuild ==="
