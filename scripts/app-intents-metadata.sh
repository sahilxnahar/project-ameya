#!/bin/sh
# Writes Metadata.appintents (what Shortcuts, Siri and Spotlight read to find Ameya's actions)
# into a bundle's Resources folder. Xcode does this itself; SwiftPM doesn't, so build-app.sh calls
# this after a release build made with `-emit-const-values` (see ARCH_FLAGS there).
#
#   scripts/app-intents-metadata.sh <built Ameya executable> <App.app/Contents/Resources>
#
# Needs Xcode (the processor isn't in the Command Line Tools). Without it, the app still works;
# only the Shortcuts actions are missing.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BINARY="$1"
RESOURCES="$2"

PROCESSOR=$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
if [ -z "$PROCESSOR" ]; then
    echo "note: appintentsmetadataprocessor not found (install Xcode); building without Shortcuts actions"
    exit 0
fi

WORK="$ROOT/.build/app-intents"
rm -rf "$WORK"
mkdir -p "$WORK"
find "$ROOT/Sources/Ameya" -name '*.swift' > "$WORK/sources.txt"

# One architecture's const values describe the same intents; prefer arm64.
ARCH=arm64
if ! find "$ROOT/.build" -name '*.swiftconstvalues' -path '*/Ameya.build/*' -path '*elease*' -path '*arm64*' | grep -q .; then
    ARCH=x86_64
fi
find "$ROOT/.build" -name '*.swiftconstvalues' -path '*/Ameya.build/*' -path '*elease*' -path "*$ARCH*" > "$WORK/constvalues.txt"
if [ ! -s "$WORK/constvalues.txt" ]; then
    echo "error: no .swiftconstvalues for the Ameya module; was it built with -emit-const-values?" >&2
    exit 1
fi

TOOLCHAIN=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")
XCODE_BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')
DEPLOYMENT=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$ROOT/Resources/Info.plist")

"$PROCESSOR" \
    --output "$WORK/out" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Ameya \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "${XCODE_BUILD:-unknown}" \
    --platform-family macOS \
    --deployment-target "$DEPLOYMENT" \
    --target-triple "$ARCH-apple-macos$DEPLOYMENT" \
    --source-file-list "$WORK/sources.txt" \
    --swift-const-vals-list "$WORK/constvalues.txt" \
    --binary-file "$BINARY" \
    --quiet-warnings

if [ ! -d "$WORK/out/Metadata.appintents" ]; then
    echo "error: appintentsmetadataprocessor wrote no Metadata.appintents" >&2
    exit 1
fi
rm -rf "$RESOURCES/Metadata.appintents"
cp -R "$WORK/out/Metadata.appintents" "$RESOURCES/"
echo "Shortcuts actions: $RESOURCES/Metadata.appintents"
