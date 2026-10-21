# Contributing

Fork the repository, create a focused branch, and open a pull request with the problem, behavior change and verification. You can contribute to the Windows/Linux edition without a Mac. Test the component you change using the commands below; report your OS, Python/toolchain versions and any skipped checks.

## Windows/Linux desktop development

Use Python 3.12 and an isolated environment. The pinned dependencies are in `Desktop/requirements.txt`. FFmpeg is optional for users, but required to verify all media conversions; install it separately from a trusted source and put it on PATH for tests. The application never downloads it.

On Windows, from the repository root in PowerShell:

```powershell
py -3.12 -m venv .build\desktop-windows
& .\.build\desktop-windows\Scripts\python.exe -m pip install --only-binary=:all: -r Desktop\requirements.txt pyinstaller==6.22.3
$env:QT_QPA_PLATFORM = 'windows'
$env:OPEN_TANGERINE_REQUIRE_FFMPEG = '1'
cd Desktop
& ..\.build\desktop-windows\Scripts\python.exe -m unittest discover -s tests -v
& ..\.build\desktop-windows\Scripts\python.exe app.py
& ..\.build\desktop-windows\Scripts\python.exe package.py
& ..\.build\desktop-windows\Scripts\python.exe smoke_package.py
```

On Ubuntu 24.04, install `python3-venv`, `libegl1`, `libopengl0`, `libxcb-cursor0`, `libxcb-icccm4`, `libxcb-keysyms1`, `libxcb-shape0`, `libxkbcommon-x11-0` and FFmpeg using your package manager. From the repository root:

```sh
python3 -m venv .build/desktop-linux
.build/desktop-linux/bin/python -m pip install --only-binary=:all: -r Desktop/requirements.txt pyinstaller==6.22.3
cd Desktop
OPEN_TANGERINE_REQUIRE_FFMPEG=1 ../.build/desktop-linux/bin/python -m unittest discover -s tests -v
../.build/desktop-linux/bin/python app.py
../.build/desktop-linux/bin/python package.py
OPEN_TANGERINE_REQUIRE_FFMPEG=1 ../.build/desktop-linux/bin/python smoke_package.py
```

Tests default to offscreen Qt when `QT_QPA_PLATFORM` is unset. To verify Linux X11 startup without a desktop session, install `xvfb` and `xauth`, then prefix the test and smoke commands with `xvfb-run -a env QT_QPA_PLATFORM=xcb`. CI uses the native Windows backend and X11 under Xvfb on Linux. Manually check drag-and-drop, folder opening, cancellation and window closing on your target desktop, and attach screenshots for UI changes.

Build packages on each target OS. `package.py` keeps compiler work under `Desktop/.build/` and packages under `Desktop/dist/`. `smoke_package.py` extracts the generated archive into a path with spaces and Unicode characters, launches it, checks all supported operations (including media when FFmpeg is present), verifies source/licenses/checksums, and checks original/existing file preservation. Do not commit virtual environments or generated packages. Both platform CI jobs must pass before a release is published; maintainers choose a new release version rather than replace existing binaries.

## macOS development

Requires macOS 26+ and Xcode 26 or compatible Command Line Tools. From the repository root:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

## Website checks

Use Node.js from the repository root; no npm install is needed:

```sh
node scripts/test-site.cjs
node scripts/test-desktop-site.cjs
node scripts/test-demo.cjs
node scripts/test-analytics.cjs
```

## Contribution requirements

Keep originals safe. Never overwrite user files silently. Use argument arrays for processes. Do not add network calls, telemetry, binary downloads or new permissions without an explicit design discussion. Declare codec and dependency licenses. Do not copy proprietary code or assets.

Add regression tests for data-loss, parser, naming and conversion changes. Use generated fixtures; never commit personal files or API keys. Update the README capability table when adding a feature. UI changes should include screenshots and accessibility labels.

Contributions are accepted under GPL-3.0-only for new project code; preserve MIT notices in upstream-derived code. You retain copyright. Sign off commits (`git commit -s`) to certify the Developer Certificate of Origin at https://developercertificate.org/ . No copyright assignment is required.

Suggested first issues: bounded archive worker, capability filtering, nonblocking native jobs, animation preservation, customizable shortcuts, and notarized release automation.

## How a contribution reaches a release

Forks are independent copies: editing a fork does not change this repository or the downloadable app. Open a pull request to propose changes. The maintainer reviews the diff, checks licenses and behavior, and runs tests before choosing whether to merge. Approval is not automatic. Changes ship only when the maintainer publishes a new version. Do not grant repository write access just to accept a contribution.
