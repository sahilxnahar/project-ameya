#!/bin/sh
# Builds ameya-ffmpeg.exe for Windows (x64 and arm64): a static, self-contained, LGPL-only FFmpeg
# command-line tool, the Windows twin of scripts/build-ffmpeg.sh (the macOS helper).
#
#   ./scripts/build-ffmpeg-windows.sh                -> .build-deps/ffmpeg-windows/bin/ameya-ffmpeg-windows-{x64,arm64}.exe
#   ARCHS=x64 ./scripts/build-ffmpeg-windows.sh      one architecture only (faster)
#   ./scripts/build-ffmpeg-windows.sh --sources-only download and verify the source tarballs, build nothing
#
# Build approach: cross-compilation with llvm-mingw (clang + lld + the mingw-w64 UCRT runtime), which
# targets both x86_64 and aarch64 Windows from one toolchain. It runs on Linux (x86_64 or aarch64, what
# GitHub's ubuntu-latest runners use) or on macOS. The toolchain release is pinned by version and
# SHA-256 like every source below. Binaries are linked with -static, so they need nothing beyond
# Windows itself (UCRT is part of Windows 10 and 11); the script stops if the .exe imports any DLL
# that is not a Windows system DLL. Target: Windows 10 22H2 and Windows 11.
#
# Licence rules (see THIRD_PARTY_NOTICES.md): FFmpeg is configured WITHOUT --enable-gpl and WITHOUT
# --enable-nonfree, so the result is LGPL-2.1-or-later. External libraries: LAME (LGPL), libopus,
# libvorbis, libogg, libvpx (BSD-3-Clause) and zlib (zlib licence; macOS uses the system copy).
# H.264, HEVC and AAC can be encoded by Windows' Media Foundation (h264_mf, hevc_mf, aac_mf), which
# is part of the operating system - FFmpeg loads mfplat.dll at run time, so the helper still starts
# on Windows "N" editions without it. AAC is also available from FFmpeg's own encoder.
# The mingw-w64 runtime and winpthreads (permissive licences) are linked in statically; their
# licence texts are copied to .build-deps/ffmpeg-windows/bin/licenses/ for shipping with the .exe.
#
# Differences from the macOS helper: h264_videotoolbox/hevc_videotoolbox are replaced by
# h264_mf/hevc_mf, aac_mf is added, and zlib is built from source. Every demuxer, muxer, decoder,
# parser, bitstream filter and filter is the same list as in build-ffmpeg.sh.
#
# Sources are kept in .build-deps/sources/ (shared with the macOS script) with SHA256SUMS-windows,
# so a release can attach them as the LGPL "complete corresponding source".
set -eu

case "${1:-}" in
    "" | --sources-only) ;;
    *) echo "usage: $0 [--sources-only]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DEPS="$ROOT/.build-deps"
SRC="$DEPS/sources"
OUT="$DEPS/ffmpeg-windows/bin"
ARCHS="${ARCHS:-x64 arm64}"

# Same versions and checksums as build-ffmpeg.sh.
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

# Windows only: there is no system zlib to link against. The sum matches the one on zlib.net.
ZLIB_VERSION=1.3.2
ZLIB_URL="https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz"
ZLIB_SHA256=d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3

# Build tool only (assembler for libvpx and FFmpeg's x86 code); not shipped.
NASM_VERSION=2.16.03
NASM_URL="https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/nasm-$NASM_VERSION.tar.xz"
NASM_SHA256=1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148

# Cross toolchain (build tool; its mingw-w64 runtime is linked in). Sums from the GitHub release.
LLVM_MINGW_VERSION=20261006
LLVM_MINGW_BASE="https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION"
LLVM_MINGW_LINUX_X86_64_SHA256=5f9c6ed95b2d4bdb2869a488c5fd5857fbdabcf288a0aa3eb1da43f6a08d8ab4
LLVM_MINGW_LINUX_AARCH64_SHA256=e77c4acfa44184f6b0c52b814d724ad63b2ecebb3c3f6f842c0846e717cbd23c
LLVM_MINGW_MACOS_SHA256=a7a19b11048e89372637d26279cdb7c430ed3cf8c1e224310421312bf986ebf6

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Downloads $1 to $4/$2 (default $SRC), verifies the SHA-256 $3.
fetch() {
    url=$1 file=$2 sum=$3 dir=${4:-$SRC}
    mkdir -p "$dir"
    if [ ! -f "$dir/$file" ]; then
        echo "==> Downloading $url"
        curl -fL --retry 3 --proto '=https' -o "$dir/$file.part" "$url"
        mv "$dir/$file.part" "$dir/$file"
    fi
    actual=$(sha256 "$dir/$file")
    if [ "$actual" != "$sum" ]; then
        echo "error: checksum mismatch for $file" >&2
        echo "  expected $sum" >&2
        echo "  actual   $actual" >&2
        rm -f "$dir/$file"
        exit 1
    fi
}

# Unpacks a verified tarball $1 (in $SRC) into a fresh directory $2.
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
fetch "$ZLIB_URL" "zlib-$ZLIB_VERSION.tar.xz" "$ZLIB_SHA256"
fetch "$NASM_URL" "nasm-$NASM_VERSION.tar.xz" "$NASM_SHA256"

# A checksum list for the source bundle, re-verified so it can't drift from the sums above.
# (SHA256SUMS without suffix belongs to the macOS script.)
(cd "$SRC" && shasum -a 256 \
    "ffmpeg-$FFMPEG_VERSION.tar.xz" "lame-$LAME_VERSION.tar.gz" "opus-$OPUS_VERSION.tar.gz" \
    "libogg-$OGG_VERSION.tar.xz" "libvorbis-$VORBIS_VERSION.tar.xz" "libvpx-$VPX_VERSION.tar.gz" \
    "zlib-$ZLIB_VERSION.tar.xz" "nasm-$NASM_VERSION.tar.xz" > SHA256SUMS-windows \
    && shasum -a 256 -c --quiet SHA256SUMS-windows)

if [ "${1:-}" = "--sources-only" ]; then
    echo "Verified sources in $SRC"
    exit 0
fi

for tool in curl shasum cc make pkg-config tar xz; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) LM_ASSET=ucrt-ubuntu-22.04-x86_64 LM_SUM=$LLVM_MINGW_LINUX_X86_64_SHA256
        BUILD_TRIPLE=x86_64-pc-linux-gnu JOBS=$(nproc) ;;
    Linux-aarch64) LM_ASSET=ucrt-ubuntu-22.04-aarch64 LM_SUM=$LLVM_MINGW_LINUX_AARCH64_SHA256
        BUILD_TRIPLE=aarch64-unknown-linux-gnu JOBS=$(nproc) ;;
    Darwin-arm64) LM_ASSET=ucrt-macos-universal LM_SUM=$LLVM_MINGW_MACOS_SHA256
        BUILD_TRIPLE=aarch64-apple-darwin JOBS=$(sysctl -n hw.ncpu) ;;
    Darwin-x86_64) LM_ASSET=ucrt-macos-universal LM_SUM=$LLVM_MINGW_MACOS_SHA256
        BUILD_TRIPLE=x86_64-apple-darwin JOBS=$(sysctl -n hw.ncpu) ;;
    *) echo "error: unsupported build host $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

# The toolchain is kept out of $SRC: it is a build tool, not part of the helper's source.
TOOLDL="$DEPS/toolchain-downloads"
LM_NAME="llvm-mingw-$LLVM_MINGW_VERSION-$LM_ASSET"
fetch "$LLVM_MINGW_BASE/$LM_NAME.tar.xz" "$LM_NAME.tar.xz" "$LM_SUM" "$TOOLDL"
LLVM_MINGW="$DEPS/tools/$LM_NAME"
if [ ! -x "$LLVM_MINGW/bin/clang" ]; then
    echo "==> Unpacking $LM_NAME"
    rm -rf "$LLVM_MINGW"
    mkdir -p "$LLVM_MINGW"
    tar -xf "$TOOLDL/$LM_NAME.tar.xz" -C "$LLVM_MINGW" --strip-components 1
fi

# NASM, for the build machine only.
TOOLS="$DEPS/tools/host"
if [ ! -x "$TOOLS/bin/nasm" ]; then
    echo "==> Building nasm $NASM_VERSION"
    unpack "nasm-$NASM_VERSION.tar.xz" "$DEPS/build/nasm"
    (cd "$DEPS/build/nasm" && ./configure --prefix="$TOOLS" >/dev/null && make -j"$JOBS" nasm >/dev/null \
        && mkdir -p "$TOOLS/bin" && cp nasm "$TOOLS/bin/nasm")
fi
PATH="$LLVM_MINGW/bin:$TOOLS/bin:$PATH"
export PATH

# Components FFmpeg is allowed to contain - identical to build-ffmpeg.sh except the hardware
# encoders (VideoToolbox there, Media Foundation here). Everything else is left out.
DEMUXERS=mov,matroska,avi,flv,asf,mpegts,mpegps,mpegvideo,ogg,mp3,wav,aiff,flac,caf,aac,h264,hevc,m4v
MUXERS=mp4,mov,ipod,matroska,webm,avi,ogg,opus,mp3,wav,aiff,flac,caf,null
DECODERS=h264,hevc,mpeg4,mpeg1video,mpeg2video,h263,flv,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,vp8,vp9,mjpeg,theora,prores,aac,aac_latm,mp1,mp2,mp3,mp3float,ac3,eac3,vorbis,opus,flac,alac,wmav1,wmav2,wmapro,amrnb,amrwb,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_qt,adpcm_ms,adpcm_ima_wav
ENCODERS=libmp3lame,libvorbis,libopus,libvpx_vp8,libvpx_vp9,h264_mf,hevc_mf,aac_mf,aac,mpeg4,flac,alac,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be
PARSERS=h264,hevc,mpeg4video,mpegvideo,mpegaudio,aac,aac_latm,ac3,vorbis,opus,flac,vp8,vp9,vc1,h263,mjpeg
BSFS=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,vp9_superframe,vp9_superframe_split,extract_extradata,mpeg4_unpack_bframes,null
FILTERS=aresample,aformat,anull,null,format,scale,fps,setsar,setpts,asetpts,trim,atrim,pad,crop,transpose,hflip,vflip,copy,acopy

# Windows system DLLs the helper may import. Anything else (libwinpthread-1.dll, libc++.dll, a codec
# DLL...) means the build is not self-contained.
SYSTEM_DLLS='^(kernel32|user32|advapi32|shell32|ole32|oleaut32|bcrypt|psapi|shlwapi|ucrtbase|api-ms-win-[a-z0-9-]+)\.dll$'

for ARCH in $ARCHS; do
    case "$ARCH" in
        x64) TRIPLE=x86_64-w64-mingw32 VPX_TARGET=x86_64-win64-gcc FF_ARCH=x86_64 VPX_AS="--as=nasm" ;;
        arm64) TRIPLE=aarch64-w64-mingw32 VPX_TARGET=arm64-win64-gcc FF_ARCH=aarch64 VPX_AS="" ;;
        *) echo "error: unknown arch $ARCH (use x64 or arm64)" >&2; exit 1 ;;
    esac
    PREFIX="$DEPS/prefix/windows-$ARCH"
    WORK="$DEPS/build/windows-$ARCH"
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX/include" "$PREFIX/lib" "$WORK"
    CROSSENV="CC=$TRIPLE-clang CXX=$TRIPLE-clang++ AR=$TRIPLE-ar RANLIB=$TRIPLE-ranlib STRIP=$TRIPLE-strip"
    CFLAGS="-O2"
    AUTOCONF="--host=$TRIPLE --build=$BUILD_TRIPLE --prefix=$PREFIX --disable-shared --enable-static"

    echo "==> [$ARCH] zlib $ZLIB_VERSION"
    unpack "zlib-$ZLIB_VERSION.tar.xz" "$WORK/zlib"
    (cd "$WORK/zlib" && make -j"$JOBS" -f win32/Makefile.gcc PREFIX="$TRIPLE-" CC="$TRIPLE-clang" \
        CFLAGS="$CFLAGS" libz.a >/dev/null \
        && cp zlib.h zconf.h "$PREFIX/include/" && cp libz.a "$PREFIX/lib/")

    echo "==> [$ARCH] libogg $OGG_VERSION"
    unpack "libogg-$OGG_VERSION.tar.xz" "$WORK/ogg"
    # shellcheck disable=SC2086
    (cd "$WORK/ogg" && env $CROSSENV CFLAGS="$CFLAGS" ./configure $AUTOCONF >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] libvorbis $VORBIS_VERSION"
    unpack "libvorbis-$VORBIS_VERSION.tar.xz" "$WORK/vorbis"
    # shellcheck disable=SC2086
    (cd "$WORK/vorbis" && env $CROSSENV CFLAGS="$CFLAGS" ./configure $AUTOCONF \
        --with-ogg="$PREFIX" --disable-docs --disable-examples --disable-oggtest >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] opus $OPUS_VERSION"
    unpack "opus-$OPUS_VERSION.tar.gz" "$WORK/opus"
    # shellcheck disable=SC2086
    (cd "$WORK/opus" && env $CROSSENV CFLAGS="$CFLAGS" ./configure $AUTOCONF \
        --disable-doc --disable-extra-programs >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] lame $LAME_VERSION"
    unpack "lame-$LAME_VERSION.tar.gz" "$WORK/lame"
    # lame_init_old is listed for export but not defined; newer linkers refuse that (same fix as macOS).
    sed -i.orig '/lame_init_old/d' "$WORK/lame/include/libmp3lame.sym"
    # LAME 3.100's config.sub (2017) predates aarch64-w64-mingw32; use FFmpeg-independent copies
    # from the libogg 1.3.6 tarball (2025), which know it. Nothing else changes.
    cp "$WORK/ogg/config.sub" "$WORK/ogg/config.guess" "$WORK/lame/"
    # shellcheck disable=SC2086
    (cd "$WORK/lame" && env $CROSSENV CFLAGS="$CFLAGS" ./configure $AUTOCONF \
        --disable-frontend --disable-gtktest --disable-dependency-tracking >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] libvpx $VPX_VERSION"
    unpack "libvpx-$VPX_VERSION.tar.gz" "$WORK/vpx"
    # shellcheck disable=SC2086
    (cd "$WORK/vpx" && env $CROSSENV CROSS="$TRIPLE-" LD="$TRIPLE-clang" ./configure \
        --target="$VPX_TARGET" --prefix="$PREFIX" \
        --enable-vp8 --enable-vp9 --enable-static --disable-shared \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --enable-runtime-cpu-detect $VPX_AS >"$WORK/vpx-configure.log" \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)

    echo "==> [$ARCH] FFmpeg $FFMPEG_VERSION"
    unpack "ffmpeg-$FFMPEG_VERSION.tar.xz" "$WORK/ffmpeg"
    # This exact line is reproduced in THIRD_PARTY_NOTICES.md.
    # shellcheck disable=SC2086
    (cd "$WORK/ffmpeg" && PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ./configure \
        --prefix="$PREFIX" --arch="$FF_ARCH" --target-os=mingw32 --enable-cross-compile \
        --cross-prefix="$TRIPLE-" --cc="$TRIPLE-clang" --cxx="$TRIPLE-clang++" \
        --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib -static" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --disable-everything --disable-autodetect --disable-network \
        --disable-shared --enable-static --disable-debug --disable-doc \
        --disable-ffplay --disable-ffprobe --disable-avdevice \
        --enable-ffmpeg --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample \
        --enable-protocol=file,pipe \
        --enable-demuxer=$DEMUXERS --enable-muxer=$MUXERS \
        --enable-decoder=$DECODERS --enable-encoder=$ENCODERS \
        --enable-parser=$PARSERS --enable-bsf=$BSFS --enable-filter=$FILTERS \
        --enable-zlib --enable-mediafoundation \
        --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx \
        >"$WORK/ffmpeg-configure.log" \
        && make -j"$JOBS" ffmpeg.exe >/dev/null) || { tail -n 40 "$WORK/ffmpeg/ffbuild/config.log" >&2 || true; exit 1; }

    # Refuse to continue if the build somehow became GPL or non-free.
    if grep -E '^#define CONFIG_(GPL|NONFREE|VERSION3) 1' "$WORK/ffmpeg/config.h" >/dev/null; then
        echo "error: FFmpeg was configured as GPL, LGPLv3 or non-free" >&2
        exit 1
    fi
    # Every encoder asked for must really be there (configure drops ones whose deps are missing).
    for enc in $(echo "$ENCODERS" | tr ',' ' '); do
        name=$(echo "$enc" | tr '[:lower:]' '[:upper:]')
        grep -q "^#define CONFIG_${name}_ENCODER 1" "$WORK/ffmpeg/config.h" \
            || { echo "error: encoder $enc was not enabled" >&2; exit 1; }
    done
    grep -q '^#define HAVE_W32THREADS 1' "$WORK/ffmpeg/config.h" \
        || { echo "error: FFmpeg was built without threads" >&2; exit 1; }

    mkdir -p "$OUT"
    EXE="$OUT/ameya-ffmpeg-windows-$ARCH.exe"
    "$TRIPLE-strip" -o "$EXE" "$WORK/ffmpeg/ffmpeg.exe"

    # Only Windows system DLLs may be imported.
    DLLS=$("$TRIPLE-objdump" -p "$EXE" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr '[:upper:]' '[:lower:]' | sort -u)
    echo "    imports: $(echo "$DLLS" | tr '\n' ' ')"
    BAD=$(echo "$DLLS" | grep -vE "$SYSTEM_DLLS" || true)
    if [ -n "$BAD" ]; then
        echo "error: ameya-ffmpeg-windows-$ARCH.exe imports non-system DLLs: $BAD" >&2
        exit 1
    fi
    echo "Built $EXE ($(wc -c < "$EXE" | tr -d ' ') bytes)"
done

# Licence texts to ship next to the .exe: FFmpeg's LGPL, and the statically linked toolchain runtime.
mkdir -p "$OUT/licenses"
cp "$WORK/ffmpeg/COPYING.LGPLv2.1" "$OUT/licenses/FFmpeg-LGPL-2.1.txt"
cp "$LLVM_MINGW/x86_64-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt" "$OUT/licenses/"
cp "$LLVM_MINGW/x86_64-w64-mingw32/share/mingw32/COPYING.winpthreads.txt" "$OUT/licenses/"
cp "$LLVM_MINGW/LICENSE.TXT" "$OUT/licenses/LLVM-compiler-rt-LICENSE.txt"
