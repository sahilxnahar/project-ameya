#!/bin/sh
# Builds ameya-ffmpeg: a static, universal (arm64 + x86_64), LGPL-only FFmpeg command-line
# tool that the worker runs as a separate process for Ogg, Opus, MP3, MKV, WebM and AVI.
#
#   ./scripts/build-ffmpeg.sh                 -> .build-deps/ffmpeg/bin/ameya-ffmpeg
#   ARCHS=arm64 ./scripts/build-ffmpeg.sh     one architecture only (faster)
#   ./scripts/build-ffmpeg.sh --sources-only  download and verify the source tarballs, build nothing
#
# The exact upstream tarballs are kept in .build-deps/sources/ with a SHA256SUMS file. Releases
# attach them (with this script) as the LGPL "complete corresponding source"; see release.yml.
#
# Licence rules (see THIRD_PARTY_NOTICES.md): FFmpeg is configured WITHOUT --enable-gpl and
# WITHOUT --enable-nonfree, so the result is LGPL-2.1-or-later. External libraries are LAME
# (LGPL), libopus, libvorbis, libogg and libvpx (all BSD-3-Clause). H.264/HEVC come from Apple's
# VideoToolbox; AAC from FFmpeg's own encoder. Sources are downloaded only from the projects'
# official sites and checked against the SHA-256 sums below before anything is built.
set -eu

case "${1:-}" in
    "" | --sources-only) ;;
    *) echo "usage: $0 [--sources-only]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DEPS="$ROOT/.build-deps"
SRC="$DEPS/sources"
OUT="$DEPS/ffmpeg/bin"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS=14.0
JOBS=$(sysctl -n hw.ncpu)

FFMPEG_VERSION=8.1.3
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3

LAME_VERSION=3.100
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e

OPUS_VERSION=1.5.2
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
OPUS_SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1

OGG_VERSION=1.3.6
OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.xz"
OGG_SHA256=5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061

VORBIS_VERSION=1.3.7
VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.xz"
VORBIS_SHA256=b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b

VPX_VERSION=1.15.2
VPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VERSION.tar.gz"
VPX_SHA256=26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa

# Build tool only (assembler for libvpx and FFmpeg's x86 code); not shipped.
NASM_VERSION=2.16.03
NASM_URL="https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/nasm-$NASM_VERSION.tar.xz"
NASM_SHA256=1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148

# Downloads $1 to $SRC/$2, verifies the SHA-256 $3 and unpacks it into $SRC/<dir>.
fetch() {
    url=$1 file=$2 sum=$3
    mkdir -p "$SRC"
    if [ ! -f "$SRC/$file" ]; then
        echo "==> Downloading $url"
        curl -fL --retry 3 --proto '=https' -o "$SRC/$file.part" "$url"
        mv "$SRC/$file.part" "$SRC/$file"
    fi
    actual=$(shasum -a 256 "$SRC/$file" | cut -d' ' -f1)
    if [ "$actual" != "$sum" ]; then
        echo "error: checksum mismatch for $file" >&2
        echo "  expected $sum" >&2
        echo "  actual   $actual" >&2
        rm -f "$SRC/$file"
        exit 1
    fi
}

# Unpacks a verified tarball into a fresh directory $2 and prints nothing.
unpack() {
    rm -rf "$2"
    mkdir -p "$2"
    tar -xf "$SRC/$1" -C "$2" --strip-components 1
}

fetch "$FFMPEG_URL" "ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
fetch "$LAME_URL" "lame-$LAME_VERSION.tar.gz" "$LAME_SHA256"
fetch "$OPUS_URL" "opus-$OPUS_VERSION.tar.gz" "$OPUS_SHA256"
fetch "$OGG_URL" "libogg-$OGG_VERSION.tar.xz" "$OGG_SHA256"
fetch "$VORBIS_URL" "libvorbis-$VORBIS_VERSION.tar.xz" "$VORBIS_SHA256"
fetch "$VPX_URL" "libvpx-$VPX_VERSION.tar.gz" "$VPX_SHA256"
fetch "$NASM_URL" "nasm-$NASM_VERSION.tar.xz" "$NASM_SHA256"

# A checksum list for the source bundle, re-verified so it can't drift from the sums above.
(cd "$SRC" && shasum -a 256 \
    "ffmpeg-$FFMPEG_VERSION.tar.xz" "lame-$LAME_VERSION.tar.gz" "opus-$OPUS_VERSION.tar.gz" \
    "libogg-$OGG_VERSION.tar.xz" "libvorbis-$VORBIS_VERSION.tar.xz" "libvpx-$VPX_VERSION.tar.gz" \
    "nasm-$NASM_VERSION.tar.xz" > SHA256SUMS && shasum -a 256 -c --quiet SHA256SUMS)

if [ "${1:-}" = "--sources-only" ]; then
    echo "Verified sources in $SRC"
    exit 0
fi

for tool in curl shasum clang make lipo pkg-config; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required (pkg-config: brew install pkgconf)" >&2; exit 1; }
done

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    arm64) BUILD_TRIPLE=aarch64-apple-darwin ;;
    *) BUILD_TRIPLE=x86_64-apple-darwin ;;
esac

# NASM, for this Mac only.
TOOLS="$DEPS/tools"
if [ ! -x "$TOOLS/bin/nasm" ]; then
    echo "==> Building nasm $NASM_VERSION"
    unpack "nasm-$NASM_VERSION.tar.xz" "$DEPS/build/nasm"
    (cd "$DEPS/build/nasm" && ./configure --prefix="$TOOLS" >/dev/null && make -j"$JOBS" nasm >/dev/null \
        && mkdir -p "$TOOLS/bin" && cp nasm "$TOOLS/bin/nasm")
fi
PATH="$TOOLS/bin:$PATH"
export PATH

# Components FFmpeg is allowed to contain. Everything else is left out.
DEMUXERS=mov,matroska,avi,flv,asf,mpegts,mpegps,mpegvideo,ogg,mp3,wav,aiff,flac,caf,aac,h264,hevc,m4v
MUXERS=mp4,mov,ipod,matroska,webm,avi,ogg,opus,mp3,wav,aiff,flac,caf,null
DECODERS=h264,hevc,mpeg4,mpeg1video,mpeg2video,h263,flv,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,vp8,vp9,mjpeg,theora,prores,aac,aac_latm,mp1,mp2,mp3,mp3float,ac3,eac3,vorbis,opus,flac,alac,wmav1,wmav2,wmapro,amrnb,amrwb,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_qt,adpcm_ms,adpcm_ima_wav
ENCODERS=libmp3lame,libvorbis,libopus,libvpx_vp8,libvpx_vp9,h264_videotoolbox,hevc_videotoolbox,aac,mpeg4,flac,alac,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be
PARSERS=h264,hevc,mpeg4video,mpegvideo,mpegaudio,aac,aac_latm,ac3,vorbis,opus,flac,vp8,vp9,vc1,h263,mjpeg
BSFS=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,vp9_superframe,vp9_superframe_split,extract_extradata,mpeg4_unpack_bframes,null
FILTERS=aresample,aformat,anull,null,format,scale,fps,setsar,setpts,asetpts,trim,atrim,pad,crop,transpose,hflip,vflip,copy,acopy

for ARCH in $ARCHS; do
    case "$ARCH" in
        arm64) TRIPLE=aarch64-apple-darwin VPX_TARGET=arm64-darwin23-gcc FF_ARCH=aarch64 ;;
        x86_64) TRIPLE=x86_64-apple-darwin VPX_TARGET=x86_64-darwin23-gcc FF_ARCH=x86_64 ;;
        *) echo "error: unknown arch $ARCH" >&2; exit 1 ;;
    esac
    PREFIX="$DEPS/prefix/$ARCH"
    WORK="$DEPS/build/$ARCH"
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX" "$WORK"
    CFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2"
    LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS"
    AUTOCONF="--host=$TRIPLE --build=$BUILD_TRIPLE --prefix=$PREFIX --disable-shared --enable-static"

    echo "==> [$ARCH] libogg $OGG_VERSION"
    unpack "libogg-$OGG_VERSION.tar.xz" "$WORK/ogg"
    # shellcheck disable=SC2086
    (cd "$WORK/ogg" && CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ./configure $AUTOCONF >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] libvorbis $VORBIS_VERSION"
    unpack "libvorbis-$VORBIS_VERSION.tar.xz" "$WORK/vorbis"
    # Apple's linker rejects this obsolete flag that the 2020 configure script adds on macOS.
    sed -i '' 's/-force_cpusubtype_ALL//g' "$WORK/vorbis/configure"
    # shellcheck disable=SC2086
    (cd "$WORK/vorbis" && CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ./configure $AUTOCONF \
        --with-ogg="$PREFIX" --disable-docs --disable-examples --disable-oggtest >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] opus $OPUS_VERSION"
    unpack "opus-$OPUS_VERSION.tar.gz" "$WORK/opus"
    # shellcheck disable=SC2086
    (cd "$WORK/opus" && CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ./configure $AUTOCONF \
        --disable-doc --disable-extra-programs >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] lame $LAME_VERSION"
    unpack "lame-$LAME_VERSION.tar.gz" "$WORK/lame"
    # lame_init_old is listed for export but not defined; newer linkers refuse that.
    sed -i '' '/lame_init_old/d' "$WORK/lame/include/libmp3lame.sym"
    # shellcheck disable=SC2086
    (cd "$WORK/lame" && CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ./configure $AUTOCONF \
        --disable-frontend --disable-gtktest --disable-dependency-tracking >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] libvpx $VPX_VERSION"
    unpack "libvpx-$VPX_VERSION.tar.gz" "$WORK/vpx"
    (cd "$WORK/vpx" && ./configure --target="$VPX_TARGET" --prefix="$PREFIX" \
        --extra-cflags="-mmacosx-version-min=$MIN_MACOS" --extra-cxxflags="-mmacosx-version-min=$MIN_MACOS" \
        --enable-vp8 --enable-vp9 --enable-pic --enable-static --disable-shared \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --enable-runtime-cpu-detect --as=nasm >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] FFmpeg $FFMPEG_VERSION"
    unpack "ffmpeg-$FFMPEG_VERSION.tar.xz" "$WORK/ffmpeg"
    CROSS=""
    [ "$ARCH" != "$HOST_ARCH" ] && CROSS="--enable-cross-compile"
    # This exact line is reproduced in THIRD_PARTY_NOTICES.md.
    # shellcheck disable=SC2086
    (cd "$WORK/ffmpeg" && PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ./configure \
        --prefix="$PREFIX" --arch="$FF_ARCH" --target-os=darwin $CROSS \
        --cc="clang -arch $ARCH" --cxx="clang++ -arch $ARCH" \
        --extra-cflags="-mmacosx-version-min=$MIN_MACOS -I$PREFIX/include" \
        --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --disable-everything --disable-autodetect --disable-network \
        --disable-shared --enable-static --disable-debug --disable-doc \
        --disable-ffplay --disable-ffprobe --disable-avdevice \
        --enable-ffmpeg --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample \
        --enable-protocol=file,pipe \
        --enable-demuxer=$DEMUXERS --enable-muxer=$MUXERS \
        --enable-decoder=$DECODERS --enable-encoder=$ENCODERS \
        --enable-parser=$PARSERS --enable-bsf=$BSFS --enable-filter=$FILTERS \
        --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
        --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx \
        >"$WORK/ffmpeg-configure.log" \
        && make -j"$JOBS" ffmpeg >/dev/null)
    # Refuse to continue if the build somehow became GPL or non-free.
    if grep -E '^#define CONFIG_(GPL|NONFREE) 1' "$WORK/ffmpeg/config.h" >/dev/null; then
        echo "error: FFmpeg was configured as GPL or non-free" >&2
        exit 1
    fi
    strip -x "$WORK/ffmpeg/ffmpeg" -o "$WORK/ameya-ffmpeg"
done

mkdir -p "$OUT"
set --
for ARCH in $ARCHS; do set -- "$@" "$DEPS/build/$ARCH/ameya-ffmpeg"; done
lipo -create "$@" -output "$OUT/ameya-ffmpeg"
chmod 755 "$OUT/ameya-ffmpeg"

# Only system frameworks and libraries may be linked dynamically.
if otool -L "$OUT/ameya-ffmpeg" | grep -E '^[[:space:]]' | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
    echo "error: ameya-ffmpeg links a non-system library" >&2
    exit 1
fi
"$OUT/ameya-ffmpeg" -hide_banner -L | head -n 3
echo "Built $OUT/ameya-ffmpeg ($(lipo -archs "$OUT/ameya-ffmpeg"), $(du -h "$OUT/ameya-ffmpeg" | cut -f1))"
