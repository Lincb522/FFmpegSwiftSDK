#!/bin/bash
set -e

# FFmpeg iOS cross-compilation script
# Builds FFmpeg static libraries for iOS arm64 and simulator arm64
# Then creates an xcframework for Swift Package Manager integration

FFMPEG_VERSION="8.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build-ffmpeg"
OUTPUT_DIR="$PROJECT_DIR/Frameworks"

# iOS deployment target
IOS_MIN_VERSION="16.0"

echo "=== FFmpeg iOS Build Script ==="
echo "FFmpeg version: $FFMPEG_VERSION"
echo "Build dir: $BUILD_DIR"
echo "Output dir: $OUTPUT_DIR"

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Download FFmpeg source
cd "$BUILD_DIR"
if [ ! -f "ffmpeg-${FFMPEG_VERSION}.tar.xz" ]; then
    echo ">>> Downloading FFmpeg ${FFMPEG_VERSION}..."
    curl -L -o "ffmpeg-${FFMPEG_VERSION}.tar.xz" \
        "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
fi

echo ">>> Extracting..."
tar xf "ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SRC="$BUILD_DIR/ffmpeg-${FFMPEG_VERSION}"

# Function to build FFmpeg for a specific platform/arch
build_ffmpeg() {
    local PLATFORM=$1  # iphoneos or iphonesimulator
    local ARCH=$2      # arm64 or x86_64
    local PREFIX="$BUILD_DIR/output-${PLATFORM}-${ARCH}"

    echo ""
    echo ">>> Building FFmpeg for ${PLATFORM} ${ARCH}..."

    local SDK_PATH=$(xcrun --sdk ${PLATFORM} --show-sdk-path)
    local CC=$(xcrun --sdk ${PLATFORM} --find clang)

    local EXTRA_CFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH}"
    local EXTRA_LDFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH}"

    if [ "$PLATFORM" = "iphoneos" ]; then
        EXTRA_CFLAGS="$EXTRA_CFLAGS -mios-version-min=${IOS_MIN_VERSION} -fembed-bitcode"
        EXTRA_LDFLAGS="$EXTRA_LDFLAGS -mios-version-min=${IOS_MIN_VERSION}"
    else
        EXTRA_CFLAGS="$EXTRA_CFLAGS -mios-simulator-version-min=${IOS_MIN_VERSION} -target ${ARCH}-apple-ios${IOS_MIN_VERSION}-simulator"
        EXTRA_LDFLAGS="$EXTRA_LDFLAGS -mios-simulator-version-min=${IOS_MIN_VERSION} -target ${ARCH}-apple-ios${IOS_MIN_VERSION}-simulator"
    fi

    cd "$FFMPEG_SRC"
    make clean 2>/dev/null || true

    ./configure \
        --prefix="$PREFIX" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=${ARCH} \
        --cc="$CC" \
        --sysroot="$SDK_PATH" \
        --extra-cflags="$EXTRA_CFLAGS" \
        --extra-ldflags="$EXTRA_LDFLAGS" \
        --enable-static \
        --disable-shared \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-autodetect \
        --enable-pic \
        --enable-small \
        --enable-swresample \
        --enable-avfilter \
        --enable-decoder=h264,hevc,aac,mp3,mp3float,pcm_s16le,pcm_f32le \
        --enable-demuxer=mov,mpegts,flv,hls,rtsp,mp3,aac,pcm_s16le,pcm_f32le \
        --enable-parser=h264,hevc,aac,mpegaudio \
        --enable-protocol=file,http,https,tcp,udp,hls,rtmp \
        --enable-muxer=null \
        --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
        --disable-avdevice \
        --disable-network \
        --enable-network \
        --disable-asm

    make -j$(sysctl -n hw.ncpu)
    make install
}

# Build for iOS device (arm64)
build_ffmpeg "iphoneos" "arm64"

# Build for iOS simulator (arm64 for Apple Silicon Macs)
build_ffmpeg "iphonesimulator" "arm64"

echo ""
echo ">>> Creating xcframework..."

DEVICE_PREFIX="$BUILD_DIR/output-iphoneos-arm64"
SIM_PREFIX="$BUILD_DIR/output-iphonesimulator-arm64"

# Create fat libraries per platform (only one arch each here, but structure is ready)
LIBS="libavformat libavcodec libavutil libswresample libavfilter"

# Create xcframework output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# For each library, create an xcframework
for LIB in $LIBS; do
    echo "  Creating ${LIB}.xcframework..."
    xcodebuild -create-xcframework \
        -library "$DEVICE_PREFIX/lib/${LIB}.a" \
        -headers "$DEVICE_PREFIX/include" \
        -library "$SIM_PREFIX/lib/${LIB}.a" \
        -headers "$SIM_PREFIX/include" \
        -output "$OUTPUT_DIR/${LIB}.xcframework"
done

# Also copy headers to a local include directory for the CFFmpeg module
echo ">>> Copying headers for CFFmpeg module..."
HEADERS_DIR="$PROJECT_DIR/Sources/CFFmpeg/include"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp -R "$DEVICE_PREFIX/include/"* "$HEADERS_DIR/"

echo ""
echo "=== Build Complete ==="
echo "XCFrameworks: $OUTPUT_DIR/"
echo "Headers: $HEADERS_DIR/"
echo ""
echo "Libraries built:"
for LIB in $LIBS; do
    echo "  - ${LIB}.xcframework"
done
