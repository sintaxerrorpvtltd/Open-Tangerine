# Trial build status

Version 0.1.9 compatibility pass, 21 October 2026. Native Swift app, macOS 15 (Sequoia)+, Intel and Apple silicon. Verified locally on macOS 15.8 (x86_64, Swift 6.1.2).

## macOS 15 and Intel compatibility pass

The app previously required the macOS 26 SDK because of Liquid Glass calls (`GlassEffectContainer`, `.glassEffect`). Those calls are replaced with `.ultraThinMaterial` backgrounds and explicit accent overlays; macOS 15 and later render the same layouts without the macOS 26-only API. The radial wheel panel also no longer uses `.transient` window collection behavior, which kept it offscreen on macOS 15 when another app was active.

Both slices of the universal build were compiled against the macOS 15.5 SDK with a 15.0 deployment target (`xcrun lipo -archs` reports `x86_64 arm64`). On the Intel test machine, `./scripts/test.sh` passed every compiled suite; the media suite skipped because FFmpeg/ffprobe were unavailable. The settings window, radial convert/tools wheel, pill and card progress HUDs, and all 25 tool windows opened and rendered through the screenshot driver. The current trial remains ad-hoc signed and is not notarized.

## Findings and repairs

The installed 0.1.5 app was inspected with REA (`inspect-macho`), confirming the native arm64 executable. The WebP error was reproduced independently: the configured FFmpeg has no `libwebp` encoder. It also lacks `libaom-av1` and `libvorbis`. An executable being present does not establish codec support.

WebP now uses a built-in literal-only lossless VP8L fallback when native/FFmpeg encoding is unavailable. Both ImageIO and FFmpeg independently decode its output. The user's actual HEIC output was converted to WebP and checked for dimensions and RGBA agreement. AVIF selects libaom-av1 or libsvtav1; Ogg selects Vorbis or Opus. An AVIF-to-PNG pixel-layout failure found by the matrix is repaired through an 8-bit sRGB raster fallback.

Batch conversion retains every selected input, reports individual failures, and reserves destination names across overlapping batches. Four PNGs produced four distinct, decodable JPEGs; a subsequent overlapping job produced a fifth distinct output. Mixed PNG/TIFF selection and corrupt/unknown inputs are covered.

Other repairs include PDF/DOCX page ordering, scanned text extraction errors, subtitle timestamp rollover, accurate non-native video trimming, silent-video speed/join, actual blur/pixelate, channel mapping, bleep generation, PNG compression payload/transparency, image rotation fallback, frame aspect ratio and metadata deletion.

The 0.1.7 follow-up adds a pure-black notch backing and top-anchored expand/retract animation, with interrupted dismissal protection and Reduce Motion support. Local optimized build and bundle validation passed; physical-notch animation appearance still needs a normal interactive Mac check.

## Executed coverage

`./scripts/test.sh` compiles once, then runs each suite in a separate process:

| Suite | Coverage |
|---|---|
| Deterministic | 20 checks: target matrix, names, parsing, tools and timestamp handling |
| Integration | Real JPEG/TIFF/PDF output; failure then successful conversion without restart; collision and original preservation; malformed input; disabled archive guard |
| Interaction | HTTP update detection, version comparison and website handoff; companion state transitions |
| Image conversion | 30 routes among PNG/JPEG/TIFF/BMP/WebP/AVIF; three asymmetric lossless WebP RGBA checks; user's HEIC-to-WebP check (34 local checks) |
| Documents | TXT/PDF/image/DOCX/subtitle outputs; all PDF split modes, merge/reorder/rotate, compression page integrity, mixed scanned/text ordering, locked/scanned rejection |
| Batch | Four-file conversion, overlapping output reservation, mixed targets, individual corrupt/unknown failures |
| Image tools | 30 local assertions: rotation/flip pixel round trips, resize/crop, frame, four collage layouts, metadata deletion, checksum and duplication |
| Media | 55 checks: all audio/video target families, reverse input routes, trim/split/crop/speed/join/snapshot/redaction, channels and actual signal content, bleep frequency, loudness, compression and three visualizers |

Media checks inspect streams, dimensions, duration and channels, then decode the complete short output. Native export failures fall back to FFmpeg where applicable. Website version/download validation, SEO metadata, links and interactive-demo tests also pass.

GitHub macOS 26 release CI for 0.1.6 completed successfully: native PNG-to-HEIC round trip, all 42 routes among seven image formats plus three lossless WebP checks (45), drag-pasteboard preservation of four inputs, all 17 image adjustments and all three redaction modes passed. The media suite passed all 55 checks. This closes the local graphics/pasteboard service gaps at the automated-test level, but does not substitute for live Finder drag UX verification.

## Explicit limits

- Local restricted execution cannot use native HEIC encoding or CoreImage rendering. PNG-to-HEIC has been confirmed by the user in the normal app; local HEIC decoding-to-WebP passed. Adjustment/redaction pixel tests passed on the GitHub macOS runner; local blocked checks were not counted as success.
- Finder pasteboard service was unavailable locally; its four-file test passed in GitHub CI. The four-file engine path passes; this does not claim live Finder drag verification. Clipboard/reveal actions and AV metadata export were not exercised.
- Word support is DOCX output, not general Word input. PDF-to-DOCX reconstructs text or page images, without OCR or exact layout preservation.
- Compression cannot guarantee smaller output. The WebP fallback is lossless, ignores lossy quality, and produces larger files. Its output must stay under 100 MB; dimensions are limited to 16,384 per side. All images retain the 40 MP input limit.
- Archive conversion is disabled and no longer offered. SVG, malformed-file fuzzing, huge-batch performance, accessibility and every possible codec/profile combination are not exhaustively verified. Intel and macOS 15 were build- and UI-tested locally; Apple silicon remains covered by the universal build target, not by this local run.
- The app remains ad-hoc signed, not Apple-notarized. Updates use the website for manual download/replacement. No Apple Developer subscription is needed for the update check.

Tests establish specific behavior on these fixtures; they are not a promise that arbitrary files can never fail. Existing compiler deprecation warnings remain.
