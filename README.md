# Open Tangerine

<a href="https://www.trymacapps.com" target="_blank" rel="noopener">
  <img src="https://www.trymacapps.com/badge.png" alt="Featured on TryMacApps" width="200" height="67" />
</a>

A local file converter and toolbox for **macOS**, with an early **Windows/Linux desktop edition**, by **Sintax Error Private Limited**.
Local processing, no account, no subscription. GPL-3.0-only. Safety limits apply.

**Mac status: 0.1.10 developer trial — ad-hoc signed, not Apple-notarized.** This is an independent project, not affiliated with Tangerine. It builds on [Satsuma](https://github.com/plyght/satsuma), with its MIT attribution preserved. It is not yet a complete replacement for Tangerine. See [limitations](#limitations).

## Windows and Linux desktop edition

The new **0.2.2 early desktop trial** is a separate implementation with a smaller feature set. [Download status and installation](https://sintaxerrorpvtltd.github.io/Open-Tangerine/#desktop) · [Desktop source and guide](Desktop/README.md) · [Windows/Linux build checks](https://github.com/sintaxerrorpvtltd/Open-Tangerine/actions/workflows/desktop.yml).

| Platform | Interface | Availability / requirements |
|---|---|---|
| macOS | Native menu bar, global drag wheel and notch | v0.1.10; macOS 15+, universal Intel/Apple silicon build |
| Windows | Batch window, glass format picker, opt-in Explorer Shift wheel and tray | 0.2.2 early trial; Windows 10/11 x64; unsigned portable ZIP |
| Linux | Batch file-drop window and progress panel | 0.2.2 early trial; x64 Ubuntu 24.04 / glibc 2.39+; portable tar.gz |

Desktop packages are published only after both CI jobs pass conversion tests and packaged startup/conversion checks. If the download page does not show a package yet, verification is still pending or the release could not be checked.

Windows/Linux include image conversion, resize/rotate, image-to-PDF, PDF merge/split/text extraction, simple SRT/VTT, SHA-256 and optional FFmpeg media conversion. Windows adds an **opt-in experimental Explorer/Desktop Shift drag wheel and tray**; Linux uses the app window. **No physical notch, HEIC/SVG, Office conversion, OCR or full Mac editor parity in this edition.** Drop files into its window. Each failed file is reported independently. Originals and existing outputs are preserved. Workers have limits but are not an OS security sandbox; use trusted files. [Detailed limits](Desktop/README.md#limits-and-safety).

The illustrations below demonstrate the **Mac app**. The remaining Mac-specific sections describe its own capabilities.

## Download for Mac

**[Website, download and installation guide](https://sintaxerrorpvtltd.github.io/Open-Tangerine/)** · [GitHub releases](https://github.com/sintaxerrorpvtltd/Open-Tangerine/releases)

Download the trial ZIP, quit the previous app, unzip, then drag Open Tangerine into Applications and choose Replace if updating. macOS may block this unnotarized trial; see the website for Apple's official per-app opening guidance. Never disable Gatekeeper globally. Check for Updates opens the website with your installed version; the website compares published releases and provides a manual download. No Apple Developer subscription is required for update checks or hosting.

The Windows glass wheel and tray are adapted from [VandanPatell’s contribution (#2)](https://github.com/sintaxerrorpvtltd/Open-Tangerine/pull/2), with additional drag/drop and shutdown checks.

## See it in motion

**Drag. Hold Shift. Drop.** Convert a selection of files together, with a separate output for each input.

![Animated illustration of dragging four PNG files onto the JPEG conversion wheel](docs/assets/showcase/readme-workflow.gif)

**Your notch. Your style.** Pure black by default, optional glass, and successful results retract automatically.

![Animated illustration of the pure-black and glass notch styles](docs/assets/showcase/readme-notch.gif)

**[Watch the 30-second launch video](https://sintaxerrorpvtltd.github.io/Open-Tangerine/assets/showcase/Open-Tangerine-Launch.mp4)** — click the preview below.

[![Open Tangerine launch video: four files, one gesture](docs/assets/showcase/launch-poster.png)](https://sintaxerrorpvtltd.github.io/Open-Tangerine/assets/showcase/Open-Tangerine-Launch.mp4)

<details>
<summary>View still previews of the conversion wheel and notch styles</summary>

![Conversion wheel with JPEG highlighted and a four-file selection](docs/assets/showcase/wheel.png)

![Pure-black and glass notch designs side by side](docs/assets/showcase/notch-styles.png)

</details>

*These are illustrated workflows, not screen recordings or conversion-speed benchmarks. The glass effect is an illustration of the native material. macOS 15+ developer trial; native Liquid Glass on macOS 26.*

## Install from source

Requires **macOS 15 or later**, Xcode 26 / compatible Command Line Tools, and Git. The build script uses Apple's Swift compiler directly; no package manager or third-party Swift dependencies are required. Building with the macOS 26 SDK renders the native Liquid Glass surfaces; older toolchains substitute a translucent material with the same shapes, while binaries built with older SDKs retain the material fallback even on macOS 26.

```sh
git clone https://github.com/sintaxerrorpvtltd/Open-Tangerine.git
cd Open-Tangerine
./scripts/build-app.sh
open "dist/Open Tangerine.app"
```

To keep the app, drag `dist/Open Tangerine.app` into your Applications folder in Finder. To share it, run `./scripts/make-dmg.sh` after building; it writes `dist/Open-Tangerine-<version>.dmg` with the app and an Applications shortcut. The local build is ad-hoc signed, not Apple-notarized. We do not recommend disabling Gatekeeper. A signed, notarized release and automatic updates are planned.

Optional: install FFmpeg from your trusted package manager (`brew install ffmpeg` if you already use Homebrew). Settings → Formats shows whether FFmpeg is available. It is already present on the development Mac. We do not bundle or silently download it.

## What changed in 0.1.10

Every menu command now has an icon. Company branding is corrected to **Sintax Error Private Limited**. Drag hover updates continuously, and internal non-file drags no longer trigger the wheel. In **Settings → General → Excluded applications**, use **Add Application…** to disable drag shortcuts in CorelDRAW or any selected application; remove it to enable them again. Menu-bar file picking remains available. Successful notch results retract automatically after two seconds, including when hovered; failures remain visible so their message can be read.

## What changed in 0.1.8

Appearance settings now offer **Pure black** (default) or **Glass** for the notch. The glass option uses native macOS material and falls back to black with Reduce Transparency. The wheel springs into view and lifts the highlighted segment; Reduce Motion disables these effects. Completed results have **Open** and **Show in Finder** actions. Results stay for eight seconds and remain visible while hovered. Settings show the actual installed version.

Website analytics use a dedicated GoatCounter Railway project, with no PostHog connection. [Project activity](https://sintaxerrorpvtltd.github.io/Open-Tangerine/stats.html) shows GitHub ZIP counts and links to the private analytics dashboard. See [analytics setup](ANALYTICS.md) and the [DragShift comparison](DRAGSHIFT_COMPARISON.md).

## What changed in 0.1.7

The notch panel now has an explicit solid sRGB black backing without the gray border. It expands from the physical notch width and top edge, and retracts into it on dismissal. Reopening interrupts dismissal safely; Reduce Motion uses immediate transitions. Includes all 0.1.6 conversion repairs.

## What changed in 0.1.6

WebP conversion now has a built-in lossless fallback when the installed FFmpeg lacks `libwebp`. AVIF and Ogg choose available encoders. Batch jobs reserve distinct filenames across overlapping requests and report unsupported inputs individually. PDF/DOCX page order, precise video trimming, silent-video operations, audio channels/bleep, PNG compression, image rotation, framing and metadata handling have regression fixes. [Test coverage and known gaps](docs/BUILD-STATUS.md).

The lossless WebP fallback prioritizes compatibility, produces larger files, and does not use the lossy quality slider. It supports up to 16,384 pixels per side and keeps outputs within the app's 100 MB input limit; larger images need a compressed WebP encoder or resizing. Audio/video still require a suitable FFmpeg build for many operations. Word support is DOCX export, not general DOCX input conversion.

## What changed in 0.1.2

Notch progress is now the default, with an original animated citrus companion, clearer job status and batch scrolling. The menu bar has Check for Updates and marks newer GitHub releases. [Update details](docs/UPDATES.md).

## What changed in 0.1.1

Roomier settings with sidebar navigation, orange selection highlights, contextual headers, animated file artwork, softer transitions and a larger menu-bar icon. Motion responds to macOS Reduce Motion. See [design notes](docs/DESIGN.md) for validation status.

## Try it

The app lives in the menu bar; Settings opens on first launch. Enable **Settings → General → Start automatically at login** after moving it to Applications. Future logins start it quietly in the menu bar. If macOS needs approval, the app links to Login Items.

1. Select one or several files in Finder (for example four PNGs), drag them together, hold **Shift**, and drop on JPEG or another common target. Each input produces its own output; a failed file does not stop the others.
2. Hold **Command** while dragging for the tool wheel. **Option + Shift** also works.
3. Hold **Control** while dragging for file actions.
4. If dragging does not trigger a wheel, use the menu-bar **Convert Files…**, **Open Tool for Files…**, or **File Actions…** commands. These also support multiple selections.
5. Converted outputs appear beside the source by default. Change this to Downloads or Desktop in Settings. Existing conversion destinations are never intentionally replaced.

Start with copies of ordinary files. Try PNG → JPEG, crop/resize, create a PDF, merge two PDFs, and copy a SHA-256 checksum.

## Features in this trial

| Area | Included implementation |
|---|---|
| Images | PNG, JPEG, HEIC, TIFF, BMP, WebP, AVIF and SVG input routes; quality settings; edit, crop, resize, rotate, visible redaction, background framing, collage, PDF creation |
| Documents | PDF to text/images/DOCX; text to PDF/images/subtitles; HTML to PDF/PNG/JPEG/WebP/DOCX; PDF merge, split and page organization |
| Media | Audio/video conversions; trim, split, join, crop, speed, snapshots, visible redaction, audio normalization/channel tools/bleeping/visualizer; many need FFmpeg |
| Subtitles | SRT, VTT and text conversions |
| File actions | Reveal in Finder, copy files, copy paths, duplicate, streaming SHA-256 checksum copied to clipboard |
| Workflow | Batch jobs, cancellation, output naming, floating or notch progress, light/dark appearance, launch at login |

The active format matrix describes **181 potential routes** and **25 tool types**. This is a catalogue, not a claim that every codec, tool or route has passed end-to-end tests. Archive routes are disabled in this trial. Optional codec availability varies by FFmpeg build.

## HTML conversion

Drop an `.html` or `.htm` file and choose PDF, DOCX, PNG, JPEG or WebP. Rendering uses WebKit, the engine behind Safari, which ships with macOS, so there is nothing extra to install.

- **PDF** is printed the way Safari prints: print stylesheets apply, text stays selectable, and the page's own `@page` size and margins take priority over the settings below.
- **PNG, JPEG and WebP** capture the whole page by default, or only the visible area. JPEG and WebP use the image quality slider (without FFmpeg's `libwebp`, the built-in WebP encoder is used: lossy for photo-like pages, lossless for simple graphics). Transparent areas become white in JPEG. Page images are limited to 16,383 pixels tall and 40 megapixels. For longer pages, lower the scale, capture the visible area or convert to PDF.
- **DOCX** rebuilds the document structure rather than its look: headings, paragraphs, bold/italic/underline/strikethrough, links, nested lists, tables (including column spans), quotes, code blocks, and images stored next to the HTML file or embedded as data URLs.
- Relative images, stylesheets and fonts load from the HTML file's own folder. The text encoding comes from the file's `<meta charset>` or byte-order mark. Files without one are read as UTF-8, or as Windows-1252 when the bytes are not valid UTF-8.

Options live in **Settings → Formats → HTML**:

| Option | Default | Applies to |
|---|---|---|
| PDF page size, Landscape, Margins (None 0, Narrow 0.25 in, Normal 0.5 in) | A4 or Letter by region, portrait, Normal | PDF |
| Print background colors and images | On | PDF |
| Page images: Full page or Visible area (viewport width × 800 px) | Full page | PNG, JPEG, WebP |
| Viewport width | 1,280 px (320–3,840) | PNG, JPEG, WebP |
| Image scale | 1× (2× and 3× for high-DPI output) | PNG, JPEG, WebP |
| Run JavaScript | Off | All |
| Load remote images, styles and fonts | Off | All |
| Give up after | 30 seconds (1–300) | All |

HTML files are treated as untrusted. Each conversion uses a fresh, hidden WebKit page with no cookies or storage, and the page's scripts are off unless you turn them on. Pages can read files only from their own folder, and navigation, redirects and pop-ups are blocked. Remote images, styles and fonts are off by default, so conversion never contacts a server; turn them on so emails and saved web pages that depend on them look as they would in Safari. Either way, `localhost`, `.local` names, loopback, link-local and private-network addresses, and all IPv6 address literals written in URLs stay blocked. A name that only resolves to a private address over DNS is not detected.

**What DOCX does not keep:** CSS layout (flexbox, grid, floats, positioning, columns), fonts, colors, backgrounds and sizes beyond the basic text styles; row spans; inline SVG, canvas, video and form controls; remote images (their alt text is kept instead); and content that JavaScript adds after loading, unless JavaScript is turned on.

## Limitations

- Not full Tangerine parity: no AI background removal, OCR, translation, universal Office conversion, watch folders, undo history or plugin installer yet.
- Background framing adds a background; it does not remove the existing one.
- Archive conversion is intentionally disabled until bounded extraction, traversal/link defenses and isolation are implemented.
- HTML conversion renders static pages; it does not interact with pages, log in, scroll infinite feeds or wait for content that keeps loading after the page has finished. Styles from linked stylesheets apply normally, but `@page` rules there are honored only when the stylesheet sits in the HTML file's folder. See [HTML conversion](#html-conversion) for what DOCX leaves out.
- Native image loading is limited to 100 MB / 40 megapixels. Animated/multipage image behavior needs further work; use single-frame images for this trial.
- This is not a security-certified sanitizer. Metadata editing and visible redaction should not be relied on to anonymize sensitive documents. Review exported files.
- Heavy native operations can temporarily block the interface. Cancellation is best-effort for external processes. Worker isolation and timeouts are release gates.
- No App Sandbox, notarization, automatic updates, Intel-specific verification or complete accessibility audit yet.
- No AI service is implemented, so there is no API key or usage charge. Update checks contact GitHub; file processing stays local. Future AI integrations must be opt-in and bring-your-own-key.

## Development

```sh
./scripts/test.sh
./scripts/build-app.sh
```

- `NativeApp/Sources/`: shipping trial implementation (SwiftUI/AppKit, ImageIO, PDFKit, AVFoundation, WebKit).
- `NativeApp/Tests/`: inherited deterministic tests and real conversion regression tests.
- `scripts/`: reproducible compiler, test and packaging entry points.
- `docs/PRD.md`: product direction; roadmap items are not current capabilities.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [build status](docs/BUILD-STATUS.md), and [third-party notices](THIRD_PARTY_NOTICES.md).

## License and attribution

Open Tangerine additions © 2026 Sintax Error Private Limited, licensed under **GPL-3.0-only**. See [LICENSE](LICENSE). Commercial use and sale are permitted under that license; distribution of covered derivatives requires corresponding source and the GPL terms. Upstream Satsuma code © 2026 plyght remains available under its original MIT terms, reproduced in [NativeApp/LICENSE](NativeApp/LICENSE). Contributors retain copyright in their contributions. The license does not grant rights to company names or logos.

Mac compatibility integrates @Teshgotcode’s Liquid Glass availability wrappers (#1) with the universal build, non-notched HUD and radial-window fixes proposed by @Devansh-Kumar-Saini (#5). Native Liquid Glass remains on macOS 26 when built with its SDK. Intel hardware and individual multi-monitor arrangements still need community testing.

Document/PDF feature proposals and contribution boundaries: [roadmap](ROADMAP.md).
