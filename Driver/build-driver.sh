#!/bin/zsh
# Builds the Halo Sync audio driver into ~/Library/Caches/Halo-build/HaloSync.driver.
# Installing it needs an administrator password, so it is a separate step: ./install-driver.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT="$HOME/Library/Caches/Halo-build/HaloSync.driver"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
clang -bundle -O2 -Wall -Wextra -Wno-unused-parameter -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework CoreAudio -framework CoreFoundation -o "$OUT/Contents/MacOS/HaloSync" HaloSync.c
cp Info.plist "$OUT/Contents/Info.plist"
xattr -cr "$OUT"
codesign --force --sign - "$OUT"
codesign --verify --strict "$OUT"
echo "Built $OUT"
