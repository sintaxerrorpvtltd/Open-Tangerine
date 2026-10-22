#!/bin/bash
set -euo pipefail
# Build (or verify) Open Tangerine and install it into Applications.
#
# Default: build a universal Intel/Apple-silicon app from source, then install it.
# The local build has no quarantine flag, so Gatekeeper does not evaluate it.
#
# Downloaded developer-trial ZIPs are ad-hoc signed, not Apple-notarized. macOS
# quarantines them and Gatekeeper rejects them. Passing --allow-unnotarized
# applies Apple's per-app "Open Anyway" decision to this bundle only; it never
# changes the global Gatekeeper policy.

START_DIR="$PWD"
cd "$(dirname "$0")/.."

APP_NAME="Open Tangerine"
BUNDLE_ID="com.syntaxerror.opentangerine"
MIN_MACOS_MAJOR=15
SOURCE=""
DEST_DIR="/Applications"
ALLOW_UNNOTARIZED=0
LAUNCH=1
FORCE=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/install-mac.sh [options]

Build a universal app from this checkout and install it:
  ./scripts/install-mac.sh

Install an already-downloaded trial ZIP or .app:
  ./scripts/install-mac.sh --from ~/Downloads/Open-Tangerine-0.1.10-macOS.zip

A quarantined, ad-hoc-signed download is rejected by Gatekeeper. If, and only
if, you trust the exact file you downloaded, you can apply the same per-app
decision as System Settings > Privacy & Security > Open Anyway:
  ./scripts/install-mac.sh --from <zip-or-app> --allow-unnotarized

Options:
  --from PATH          Install PATH instead of building from source.
  --dest DIR           Install into DIR (default: /Applications).
  --allow-unnotarized  Remove com.apple.quarantine from the installed copy.
  --no-launch          Do not open the app after installing.
  --force              Replace an existing install without keeping a backup.
  -h, --help           Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) SOURCE="${2:-}"; [[ -n "$SOURCE" ]] || { echo "--from needs a path" >&2; exit 2; }; shift 2 ;;
    --dest) DEST_DIR="${2:-}"; [[ -n "$DEST_DIR" ]] || { echo "--dest needs a path" >&2; exit 2; }; shift 2 ;;
    --allow-unnotarized) ALLOW_UNNOTARIZED=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Keep user-supplied relative paths relative to where the command was run.
[[ -n "$SOURCE" && "$SOURCE" != /* ]] && SOURCE="$START_DIR/$SOURCE"
[[ "$DEST_DIR" != /* ]] && DEST_DIR="$START_DIR/$DEST_DIR"

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
if (( macos_major < MIN_MACOS_MAJOR )); then
  echo "Open Tangerine requires macOS ${MIN_MACOS_MAJOR} or later; this Mac is macOS ${macos_version}." >&2
  exit 1
fi

host_arch="$(uname -m)"
case "$host_arch" in
  x86_64|arm64) ;;
  *) echo "Unsupported CPU architecture: $host_arch" >&2; exit 1 ;;
esac

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/open-tangerine-install.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

source_app=""
if [[ -z "$SOURCE" ]]; then
  echo "Building a universal app for Intel and Apple silicon…"
  BUILD_UNIVERSAL=1 ./scripts/build-app.sh
  source_app="$PWD/dist/${APP_NAME}.app"
else
  if [[ ! -e "$SOURCE" ]]; then
    echo "Not found: $SOURCE" >&2
    exit 1
  fi
  if [[ "$SOURCE" == *.zip ]]; then
    echo "SHA-256: $(shasum -a 256 "$SOURCE" | awk '{print $1}')"
    echo "Compare this with the SHA-256 published with the release before trusting it."
  fi
  case "$SOURCE" in
    *.zip)
      echo "Extracting $(basename "$SOURCE")…"
      ditto -x -k "$SOURCE" "$work_dir/extracted"
      source_app="$(find "$work_dir/extracted" -maxdepth 2 -name "${APP_NAME}.app" -type d -print -quit)"
      ;;
    *)
      source_app="$SOURCE"
      ;;
  esac
fi

if [[ -z "$source_app" || ! -d "$source_app" ]]; then
  echo "Could not find ${APP_NAME}.app in $SOURCE" >&2
  exit 1
fi

exe="$source_app/Contents/MacOS/OpenTangerine"
if [[ ! -x "$exe" ]]; then
  echo "Invalid bundle: missing executable at $exe" >&2
  exit 1
fi

archs="$(xcrun lipo -archs "$exe" 2>/dev/null || true)"
case " $archs " in
  *" $host_arch "*) ;;
  *) echo "This bundle has $archs, but this Mac is $host_arch." >&2; exit 1 ;;
esac

if ! codesign --verify --deep --strict "$source_app" >/dev/null 2>&1; then
  echo "The bundle signature is invalid; refusing to install it." >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist" 2>/dev/null || echo unknown)"
signature="$(codesign -dv "$source_app" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
signature="${signature:-ad-hoc}"
quarantined=0
if xattr -p com.apple.quarantine "$source_app" >/dev/null 2>&1; then
  quarantined=1
fi

echo "Verified ${APP_NAME} ${version} (${archs}, ${signature})"
if [[ "$quarantined" == "1" ]]; then
  echo "This copy carries com.apple.quarantine, so Gatekeeper will block it: it is not Apple-notarized."
  if [[ "$ALLOW_UNNOTARIZED" != "1" ]]; then
    cat >&2 <<'BLOCKED'
Refusing to install a quarantined, unnotarized trial by default.

Choose one of these:
  1. Run again with --allow-unnotarized after checking the download and its
     SHA-256 against the release notes. This is the per-app equivalent of
     System Settings > Privacy & Security > Open Anyway.
  2. Install Apple-notarized software when the project publishes it.
  3. Build from source (no quarantine flag): ./scripts/install-mac.sh
BLOCKED
    exit 1
  fi
  echo "Proceeding because --allow-unnotarized was requested. Gatekeeper is not disabled globally."
fi

# Quit any running copy so the bundle can be replaced safely.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x OpenTangerine >/dev/null 2>&1 || break
  sleep 0.25
done
pkill -x OpenTangerine >/dev/null 2>&1 || true
sleep 0.5

mkdir -p "$DEST_DIR" 2>/dev/null || true
if [[ ! -w "$DEST_DIR" ]]; then
  echo "$DEST_DIR is not writable by $(id -un). Re-run with sudo, or use --dest \"$HOME/Applications\"." >&2
  exit 1
fi

installed="$DEST_DIR/${APP_NAME}.app"
if [[ -d "$installed" ]]; then
  if [[ "$FORCE" == "1" ]]; then
    rm -rf "$installed"
  else
    backup_root="$HOME/Library/Application Support/Open Tangerine/Backups"
    mkdir -p "$backup_root"
    backup="$backup_root/${APP_NAME} ${version} $(date +%Y%m%d-%H%M%S)-$$.app"
    echo "Backing up the existing app to $backup"
    ditto "$installed" "$backup"
    rm -rf "$installed"
  fi
fi

echo "Installing to $installed"
ditto "$source_app" "$installed"

if [[ "$quarantined" == "1" && "$ALLOW_UNNOTARIZED" == "1" ]]; then
  xattr -dr com.apple.quarantine "$installed"
fi

codesign --verify --deep --strict "$installed"
test -x "$installed/Contents/MacOS/OpenTangerine"

echo "Installed ${APP_NAME} ${version} (${archs}) on macOS ${macos_version}."

if [[ "$LAUNCH" == "1" ]]; then
  open "$installed"
  sleep 3
  if pgrep -x OpenTangerine >/dev/null 2>&1; then
    echo "Open Tangerine is running in the menu bar."
  else
    echo "The app did not stay running. Check Console.app or run:" >&2
    echo "  \"$installed/Contents/MacOS/OpenTangerine\"" >&2
    exit 1
  fi
fi
