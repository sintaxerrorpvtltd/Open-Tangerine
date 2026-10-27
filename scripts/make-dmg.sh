#!/bin/bash
set -euo pipefail
# Packages dist/Open Tangerine.app (built by build-app.sh) into a drag-to-Applications disk image.
cd "$(dirname "$0")/.."
app="$PWD/dist/Open Tangerine.app"
test -d "$app" || { echo "Build the app first: ./scripts/build-app.sh" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$PWD/dist/Open-Tangerine-$version.dmg"
staging=$(mktemp -d "${TMPDIR:-/tmp}/opentangerine-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# ditto keeps the code signature and extended attributes intact.
ditto "$app" "$staging/Open Tangerine.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Open Tangerine" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
# Developer ID signing matches build-app.sh; trials stay unsigned like the ZIP.
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg"
fi
hdiutil verify "$dmg" >/dev/null
shasum -a 256 "$dmg"
printf 'Built %s\n' "$dmg"
