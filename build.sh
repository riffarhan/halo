#!/bin/zsh
# Builds Halo, signs it, and installs it to ~/Applications/Halo.app.
# The bundle is assembled outside iCloud Drive: iCloud keeps adding Finder metadata, which codesign rejects.
set -euo pipefail
cd "$(dirname "$0")"

SCRATCH="$HOME/Library/Caches/Halo-build"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Halo"

APP="$SCRATCH/Halo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Halo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The Halo Sync audio driver travels inside the app; Settings → Video sync installs it.
Driver/build-driver.sh >/dev/null
cp -R "$SCRATCH/HaloSync.driver" "$APP/Contents/Resources/"
xattr -cr "$APP"

# Sign with the local "Halo Local Signing" certificate when it exists, so the Screen Recording and
# Microphone permissions survive rebuilds (the requirement is name + certificate, not the build's hash).
# Otherwise fall back to ad-hoc signing, which needs the permissions granted again after each build.
SIGN_DIR="$SCRATCH/signing"
KC="$SIGN_DIR/halo-signing.keychain-db"
if [[ -f "$KC" && -f "$SIGN_DIR/keychain.pass" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/keychain.pass")" "$KC"
  # codesign only looks in the search list, so add the keychain just for this step and restore it after.
  ORIG=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
  restore() { security list-keychains -d user -s "${ORIG[@]}" }
  trap restore EXIT
  security list-keychains -d user -s "${ORIG[@]}" "$KC"
  codesign --force --sign "Halo Local Signing" "$APP"
  restore
  trap - EXIT
  echo "Signed with Halo Local Signing"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (permissions must be re-allowed after this build)"
fi
codesign --verify --strict "$APP"

# Install (quit a running copy first so the new one is what launches)
DEST="$HOME/Applications/Halo.app"
mkdir -p "$HOME/Applications"
osascript -e 'tell application id "local.halo.backlight" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto --noextattr --noqtn "$APP" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed $DEST"
