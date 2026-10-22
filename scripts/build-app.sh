#!/bin/bash
set -euo pipefail
# 0.1.10: reliable drag hover, per-app exclusions and two-second notch dismissal.
cd "$(dirname "$0")/.."
app="$PWD/dist/Open Tangerine.app"
module_cache="$PWD/.build/module-cache"
mkdir -p "$app/Contents/MacOS" "$module_cache" "$PWD/.build"

# macOS 15 (Sequoia) is the minimum supported release. Intel (x86_64) builds are
# first-class; set BUILD_UNIVERSAL=1 to produce one app for Intel and Apple silicon.
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
if [[ "${BUILD_UNIVERSAL:-0}" == "1" || "${ARCHS:-}" == "universal" ]]; then
  archs=(x86_64 arm64)
else
  read -r -a archs <<< "${ARCHS:-$(uname -m)}"
fi

binaries=()
for arch in "${archs[@]}"; do
  binary="$PWD/.build/OpenTangerine-$arch"
  find NativeApp/Sources -name '*.swift' -print0 | xargs -0 xcrun swiftc \
    -swift-version 5 -O -parse-as-library \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -module-cache-path "$module_cache" \
    -o "$binary"
  binaries+=("$binary")
done

if (( ${#binaries[@]} > 1 )); then
  xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/OpenTangerine"
else
  cp "${binaries[0]}" "$app/Contents/MacOS/OpenTangerine"
fi
chmod +x "$app/Contents/MacOS/OpenTangerine"

# Preserve the legacy bundle identifier so existing settings and login registration survive updates.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenTangerine</string>
<key>CFBundleIdentifier</key><string>com.syntaxerror.opentangerine</string>
<key>CFBundleName</key><string>Open Tangerine</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.10</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources"
xcrun swiftc -module-cache-path "$module_cache" NativeApp/Sources/UI/BrandArtwork.swift scripts/make-icon.swift -o .build/make-icon
.build/make-icon "$PWD/.build/AppIcon.iconset"
python3 scripts/package-icon.py .build/AppIcon.iconset "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/GPL-3.0.txt"
cp NativeApp/LICENSE "$app/Contents/Resources/Satsuma-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Developer trials use ad-hoc signing. Developer ID + notarization is required for trusted public distribution.
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
test -x "$app/Contents/MacOS/OpenTangerine"
plutil -lint "$app/Contents/Info.plist"

# Opt-in notarization for release builds. Configure a notarytool keychain profile
# once (xcrun notarytool store-credentials <profile> --apple-id ... --team-id ...)
# and set NOTARY_PROFILE together with DEVELOPER_ID_APPLICATION.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "NOTARY_PROFILE requires DEVELOPER_ID_APPLICATION; ad-hoc builds cannot be notarized." >&2
    exit 1
  fi
  notarize_zip="$PWD/.build/OpenTangerine-notarize.zip"
  rm -f "$notarize_zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$notarize_zip"
  xcrun notarytool submit "$notarize_zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  rm -f "$notarize_zip"
  echo "Notarized and stapled with profile $NOTARY_PROFILE"
fi

printf 'Built %s (%s, macOS %s+)\n' "$app" "$(xcrun lipo -archs "$app/Contents/MacOS/OpenTangerine")" "$MIN_MACOS"
