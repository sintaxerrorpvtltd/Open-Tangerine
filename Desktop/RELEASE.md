First Windows/Linux desktop trial. **This is a separate, smaller feature set than the Mac app.**

- Windows 10/11 x64 portable ZIP; Linux x64 Ubuntu 24.04 / glibc 2.39+ tar.gz.
- Multi-file drag into the app, image conversion/resize/rotation, image to PDF, PDF merge/split/text, simple SRT/VTT and SHA-256.
- Optional audio/video conversion with your own trusted FFmpeg installation.
- Originals retained; exclusive output naming; separate workers, cancellation and time/output limits.
- Source, dependency versions and license texts are included in each package.

Both platform CI jobs must pass conversion/safety tests and packaged startup/conversion smoke checks before this release is published. This is not a guarantee of compatibility with every machine. Unsigned Windows binary; no administrator access required. Includes global Shift wheel, progress HUD, and background system tray on Windows; physical-notch integration and Mac editors remain Mac-only. Windows hard memory isolation remains unfinished; process trusted files.

Extract the full archive, then run OpenTangerine.exe (Windows) or OpenTangerine (Linux). Keep the _internal folder alongside the executable. Compare SHA-256 with the companion checksum. Do not disable OS protection globally.

Full installation, capabilities and limitations: https://github.com/sintaxerrorpvtltd/Open-Tangerine/blob/main/Desktop/README.md
Mac users: keep using the separate macOS release.
