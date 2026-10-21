# Repository guidance

## Project and layout

Open Tangerine is a local file converter and toolbox. The macOS app and the
Windows/Linux desktop edition are separate implementations with different
capabilities; changes to one do not automatically apply to the other.

- `NativeApp/Sources/`: native macOS app using SwiftUI/AppKit, ImageIO, PDFKit
  and AVFoundation. `Engines/` handles conversions, `Operations/` implements
  tools, `Core/` handles jobs/processes, and `Radial/` implements drag gestures.
- `NativeApp/Tests/`: executable Swift regression suites.
- `Desktop/`: Python/Qt desktop edition. `app.py` provides the UI, `engine.py`
  implements conversions and output publication, and `runner.py` manages workers.
  Tests live in `Desktop/tests/`; packaging uses `package.py` and
  `smoke_package.py`.
- `docs/`: static website with plain HTML, CSS and JavaScript in `assets/`.
  There is no npm build step. `docs/PRD.md` describes direction, not shipped
  functionality; consult implementation and current README files for behavior.
- `scripts/`: macOS compiler/build scripts and Node website checks.
- `.github/workflows/`: macOS checks/releases and Windows/Linux checks/releases.

Read `CONTRIBUTING.md`, `SECURITY.md` and the relevant platform README before
changing behavior. `docs/BUILD-STATUS.md` records native test coverage and gaps.

## Development and validation

Run commands from the repository root unless a different directory is stated.
Choose checks for the affected component and report failures, skipped checks and
platform limitations explicitly.

### macOS app

Requires macOS 26+ and Xcode 26 or compatible Command Line Tools. Scripts invoke
`xcrun swiftc` directly with Swift 5 language mode; there is no Swift package or
third-party Swift dependency setup. Python 3 is also used by the scripts.

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The test script compiles once and runs each suite in a fresh process. FFmpeg is
needed for media coverage; codec availability varies by installation. Build
output is `dist/Open Tangerine.app`; local builds are ad-hoc signed by default.
Windows/Linux cannot validate the native app; use a compatible Mac or macOS CI.

### Windows/Linux desktop

Use Python 3.12 in an isolated environment. From `Desktop/`:

```sh
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
python app.py
```

For headless Qt tests set `QT_QPA_PLATFORM=offscreen` before running unittest
(PowerShell: `$env:QT_QPA_PLATFORM = 'offscreen'`). Media tests need a separately
installed FFmpeg. Dependencies are pinned in `requirements.txt`.

For packaging changes, also run from `Desktop/`:

```sh
python -m pip install pyinstaller==6.22.3
python package.py
python smoke_package.py
```

Build and smoke-test packages separately on Windows and Linux. Preserve the
bundled corresponding source, dependency versions, licenses and SHA-256 files.

### Website

Use Node.js; these checks use built-in modules and need no npm install:

```sh
node scripts/test-site.cjs
node scripts/test-desktop-site.cjs
node scripts/test-demo.cjs
node scripts/test-analytics.cjs
```

## Implementation rules

- Keep changes focused and follow nearby language/style conventions. No shared
  formatter or linter configuration is present; avoid unrelated reformatting.
- Preserve originals and existing outputs. Retain collision-safe staging and
  publication; never silently overwrite user files or remove completed outputs
  on partial failure or cancellation.
- Pass external process arguments as arrays, never interpolated shell commands.
  Retain input/output limits, bounded diagnostics, timeouts, cancellation and
  process cleanup. Keep file processing local.
- Do not add network calls, telemetry, binary downloads or new permissions
  without an explicit design discussion. FFmpeg is optional and separately
  installed, not bundled or silently downloaded.
- Archive conversion remains disabled pending bounded extraction and isolation.
  Desktop workers are not an OS security sandbox; do not present PDF conversion,
  metadata changes or visible redaction as certified sanitization.
- Add regression tests for data-loss, parser, naming and conversion changes.
  Generate fixtures; never commit personal files, credentials or API keys.
- UI changes should include screenshots and accessibility labels. Respect native
  Reduce Motion/Reduce Transparency behavior and document unverified UI behavior.
- Update README capability descriptions when adding features, distinguishing
  macOS from desktop support. Keep trial, signing and verification claims honest.
- Preserve the legacy macOS bundle identifier so settings and login registration
  survive updates. Published release versions/assets must not be silently replaced.
- Do not commit generated `.build/`, `dist/`, packaging outputs, caches or local
  environment files. Avoid unrelated workspace changes.
- New project code is GPL-3.0-only. Preserve upstream Satsuma MIT notices and
  declare dependency/codec licenses; do not copy proprietary code or assets.
  When creating commits, use DCO sign-off (`git commit -s`) as required by
  `CONTRIBUTING.md`.

Describe the problem, resulting behavior and verification in pull requests.
