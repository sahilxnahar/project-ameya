#!/bin/sh
# Builds dist/Ameya.app: a sandboxed, ad-hoc signed app bundle with the worker inside it.
#
#   ./scripts/build-app.sh              universal (Apple silicon + Intel), release
#   NATIVE=1 ./scripts/build-app.sh     this Mac's architecture only (faster)
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/dist/Ameya.app"

if [ "${NATIVE:-0}" = "1" ]; then
    ARCH_FLAGS=""
else
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS --product Ameya
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS --product AmeyaWorker
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS --product AmeyaLauncher
# shellcheck disable=SC2086
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

rm -rf "$APP"
# Workers live inside the launcher XPC service: it starts them, and they inherit its sandbox,
# which (unlike the app's) has no access to the user's files.
XPC="$APP/Contents/XPCServices/AmeyaLauncher.xpc"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$XPC/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN/Ameya" "$APP/Contents/MacOS/Ameya"
cp "$ROOT/Resources/AmeyaLauncher-Info.plist" "$XPC/Contents/Info.plist"
cp "$BIN/AmeyaLauncher" "$XPC/Contents/MacOS/AmeyaLauncher"
cp "$BIN/AmeyaWorker" "$XPC/Contents/MacOS/AmeyaWorker"
# The LGPL FFmpeg helper (scripts/build-ffmpeg.sh). Without it, Ogg/Opus/MP3-out/MKV/WebM/AVI aren't offered.
FFMPEG="$ROOT/.build-deps/ffmpeg/bin/ameya-ffmpeg"
if [ -x "$FFMPEG" ]; then
    cp "$FFMPEG" "$XPC/Contents/MacOS/ameya-ffmpeg"
    cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSES/LGPL-2.1.txt" "$APP/Contents/Resources/"
else
    echo "note: $FFMPEG not found; building without the FFmpeg formats (run scripts/build-ffmpeg.sh)"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign inside-out: the FFmpeg helper and the worker, the launcher service, then the app.
# "-" is an ad-hoc signature. Replace with a Developer ID identity once the project has one.
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ -f "$XPC/Contents/MacOS/ameya-ffmpeg" ]; then
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
        --entitlements "$ROOT/Resources/AmeyaWorker.entitlements" "$XPC/Contents/MacOS/ameya-ffmpeg"
fi
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/AmeyaWorker.entitlements" "$XPC/Contents/MacOS/AmeyaWorker"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/AmeyaLauncher.entitlements" "$XPC"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/Ameya.entitlements" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Ameya"))"
