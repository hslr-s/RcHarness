#!/usr/bin/env bash
set -euo pipefail

APP="${1:?signed .app path required}"
OUTPUT="${2:?output .dmg path required}"
VOLUME_NAME="${3:-RcHarness}"

case "$APP" in
  *.app) ;;
  *) echo 'Application path must end in .app.' >&2; exit 1 ;;
esac
case "$OUTPUT" in
  *.dmg) ;;
  *) echo 'DMG output path must end in .dmg.' >&2; exit 1 ;;
esac
if [[ ! -d "$APP" || ! -f "$APP/Contents/Info.plist" ]]; then
  echo 'A valid application bundle is required.' >&2
  exit 1
fi
if [[ -L "$OUTPUT" ]]; then
  echo 'Refusing to replace a symlink.' >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
PARENT="$(cd "$(dirname "$OUTPUT")" && pwd -P)"
OUTPUT="$PARENT/$(basename "$OUTPUT")"
STAGE="$(mktemp -d "$PARENT/.rcharness-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

# Keep the application bundle intact and add the conventional Applications
# shortcut. The same image is used for first-install downloads and Sparkle
# updates, so it must contain one copy of the app with its original name.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -quiet \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$OUTPUT"
hdiutil verify "$OUTPUT" >/dev/null
echo "Packaged $OUTPUT"
