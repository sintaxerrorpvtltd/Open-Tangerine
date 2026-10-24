# Open Tangerine — Windows and Linux trial 0.2.2

This is an early cross-platform desktop edition, not a port of every Mac feature.
No account, telemetry, uploads, administrator service or automatic downloads.

## Install

- **Windows 10/11 x64:** extract the entire Windows ZIP into a local folder. Run `OpenTangerine.exe` inside it. Keep `_internal` alongside it. This trial is unsigned; Windows may warn about an unknown publisher. Do not disable Defender or SmartScreen globally. Do not run a file flagged as malware; report the exact warning.
- **Linux x64:** Ubuntu 24.04 or a compatible glibc 2.39+ desktop. Extract the `.tar.gz`, then run `OpenTangerine`. X11 or Wayland desktop libraries are required. Other distributions and ARM are unverified. No root installation is needed.
- Keep this folder to uninstall/remove it later. Updating: quit the app, extract the new package into a separate folder and launch it. Keep the old folder if you want rollback.
- Check the asset's SHA-256 against its companion `.sha256` file. This detects corruption; it is not a publisher signature.

## Use

Drop local files **into the app window**, or click Add files. Choose an output/tool and Convert files. Multiple files are processed sequentially; a failure does not stop later files. Outputs go beside originals, or into your selected folder. Existing files are never replaced. Completed outputs remain if a batch is cancelled. Per-file rows show failures.

Images: PNG, JPEG, WebP, TIFF and BMP output; PNG/JPEG/WebP/TIFF/BMP/AVIF input. JPEG transparency is flattened against white. Optional maximum-side resizing and clockwise rotation. Animated and multipage images are rejected instead of silently discarding frames. HEIC, SVG and RAW are not supported by this trial.

PDF: image to PDF, merge, split into single-page files, extract existing text. No OCR, encrypted PDFs or general Office support.

Word: **DOCX → Text** and **DOCX → PDF (text only)** extract the body paragraphs and table rows of a `.docx` (table cells become tab-separated columns). Formatting, images, text boxes, hidden text, headers, footers, footnotes, comments and deleted tracked changes are not kept; inserted tracked changes are. The PDF lays that text out on A4 pages in the standard Helvetica font, so it supports Western European Latin text only: documents with other scripts are rejected with the first unsupported character named, and DOCX → Text keeps them. Long table cells can push later columns past their tab stop. The package is read in memory with size limits and is never extracted to disk; DTD/entity declarations, macro-enabled, encrypted and legacy `.doc` files are rejected. Not a sanitizer: it does not open links or embedded objects, and the output contains only text. PDF operations can retain active content/links; this is not a PDF sanitizer.

Media: MP4, WebM, MP3, WAV, FLAC and Ogg output from supported local audio/video inputs. Select a **trusted, separately installed FFmpeg executable** using Set FFmpeg. The app does not install or bundle it. Codec support depends on that installation. No playlists or network URLs. Basic SRT/VTT subtitle conversion and SHA-256 file checksums are also included.

Windows now includes a glass conversion wheel and optional tray mode, adapted from @VandanPatell’s PR #2. The app opens a visible window by default. Enable **experimental Shift drag wheel in Explorer / Desktop** to try it: drag selected files and hold Shift briefly, then drop onto a format. Escape cancels. The wheel only starts in Explorer/Desktop; other editors are excluded. It polls modifier state without consuming keys or recording text. Selection lookup uses the built-in Windows PowerShell and may take a moment; nothing is downloaded. Actual dropped local files are validated, and only Copy drops are accepted.

Use **Run in background** for tray mode, or launch with `--background`. Double-click the tray icon to restore the window. Quit cancels active work and waits for the worker before exiting. Without a system tray the default window stays visible. `--window` always requests the window. Linux uses the window and glass format picker; no global wheel or tray is enabled there. The physical Mac notch and Mac tool editors are not included.

## Limits and safety

100 files per batch, 100 MiB per input, 40 megapixels per image, 200 pages per PDF/merged result, 512 MiB output ceiling. Each conversion uses a separate process with a 180-second parent deadline. FFmpeg jobs have a 150-second deadline and bounded decoder, encoder and filter threads. Linux workers additionally have address-space, CPU and output-file limits. Windows workers do not yet have a hard memory cap. Workers are **not an OS security sandbox**: process trusted files only. No claim of malicious-file immunity or zero errors is made.

Regular-file checks reject direct symlinks/reparse points and devices. Publication prefers atomic links and falls back to exclusive creation/copy on FAT32/exFAT. Existing destinations are never replaced. The fallback is not atomic: a hard crash can leave a partial output. Parent-owned staging is cleaned after ordinary cancellation/timeouts; an app or machine crash can still leave a hidden `.opentangerine-*` working folder. Remove leftovers only after the app is closed. Successful files from partial PDF splitting or a cancelled batch are retained.

## Build and test

Python 3.12 recommended. In a virtual environment:

```sh
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
python app.py
python -m pip install pyinstaller==6.22.3
python package.py
```

Build separately on Windows and Linux. The CI tests conversion, corruption, limits, naming collisions, original-file preservation, cancellation, timeouts and Qt window startup before packaging. Packaged executables receive a startup and real conversion smoke test. Automated CI does not establish compatibility with every desktop, GPU, codec or antivirus product.

Source: https://github.com/sintaxerrorpvtltd/Open-Tangerine/tree/main/Desktop
Downloads: https://sintaxerrorpvtltd.github.io/Open-Tangerine/#desktop
Copyright 2026 Sintax Error Private Limited. GPL-3.0-only; dependencies retain their licenses. Qt libraries are distributed dynamically in `_internal` and can be replaced with compatible builds. Dependency versions and license texts are included. For corresponding dependency source, use the exact version tags at https://code.qt.io/pyside/pyside-setup.git/ , https://code.qt.io/qt/qtbase.git/ , https://github.com/python-pillow/Pillow and https://github.com/py-pdf/pypdf . No modifications are made to those dependencies. Python is included under the PSF license; PyInstaller's bootloader uses its distribution exception.

Linux GUI packaging is exercised with the real xcb plugin under Xvfb; this does not verify every physical desktop or Wayland compositor.
