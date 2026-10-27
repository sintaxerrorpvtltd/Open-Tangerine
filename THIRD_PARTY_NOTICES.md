# Third-party notices

## Satsuma

Source: https://github.com/plyght/satsuma
Imported revision: 6cb76b78e1932bcdb297be73454ed75d09c252cc
Copyright (c) 2026 plyght. MIT license: `NativeApp/LICENSE`.

The native app is substantially based on Satsuma's Swift implementation. Open Tangerine changes include branding, direct compiler build/test scripts, Command and Control workflows, file actions/checksums, safer conversion publication, input limits, opt-in diagnostics, bounded process output, and archive restrictions. Original MIT rights and notice are preserved. The combined distribution and new additions are GPL-3.0-only. No upstream image/logo assets were imported.

## Apple frameworks

AppKit, SwiftUI, ImageIO, PDFKit, AVFoundation, CoreImage, CryptoKit, WebKit and related system frameworks are provided by macOS. They are not redistributed separately.

## Optional external programs

FFmpeg is located on the user's machine and invoked as a separate executable. It is not bundled. Its build-specific LGPL/GPL and codec obligations must be reviewed before distributing a future bundled binary. macOS command-line utilities are supplied by the operating system.

Open Tangerine is independent of Tangerine and does not include Tangerine proprietary source or branding assets.

## DragShift design reference

Source reviewed: https://github.com/llamaboi55/DragShift (18 October 2026).
DragShift's radial-menu motion and completion controls informed the optional glass
notch and result actions in 0.1.8. These are native SwiftUI implementations;
no Python runtime, screenshot-capture renderer or mascot assets were imported.
The upstream MIT notice is retained below for attribution.

MIT License

Copyright (c) 2026 DragShift contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## Windows/Linux desktop edition

The independently authored Python/Qt desktop edition uses Pillow (HPND), pypdf (BSD-3-Clause), PySide6/Shiboken and Qt (LGPLv3/GPLv3 options), Python (PSF) and PyInstaller (GPL with bootloader distribution exception). Exact pins are in `Desktop/requirements.txt`; portable builds include dependency versions and license texts under `licenses/`, and the corresponding application source under `source/`. Qt remains dynamically linked. Optional FFmpeg is installed and selected by the user and is not redistributed. Its build-specific licenses apply.
