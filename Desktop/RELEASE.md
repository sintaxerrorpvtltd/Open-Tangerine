# Windows/Linux desktop 0.2.3 — console fix, progress feedback and focused DOCX export

Thanks to the contributors of #16, #17 and #18 for focused changes and detailed testing.

- Fix #17: Windows uses a GUI executable without a console and a separate OpenTangerineWorker.exe with redirected pipes and CREATE_NO_WINDOW. Keep the worker and _internal folder beside the app. Linux keeps its existing launcher.
- Integrate #16: Windows Shift-wheel conversions get a non-activating progress island with Pure black, painted Glass or Off styles. Success/cancellation retract after two seconds; failures stay dismissible. Switching Off during a batch restores tray feedback. Reduced motion follows the Windows setting.
- Integrate #18: DOCX body/table text to UTF-8 text or a searchable text-only PDF, with no new dependencies. The PDF route supports Western European Latin only and names unsupported characters; use DOCX → Text for other scripts. Formatting, images, text boxes, hidden runs, headers/footers and notes are not preserved. This is not formatted Word export or a sanitizer.
- Harden DOCX parsing: parser-level DTD rejection covers UTF-8 and UTF-16; extracted-text limits count UTF-8 bytes. Originals and existing outputs remain protected by the same workers/publication rules.
- Add regression tests and frozen GUI-to-worker conversion checks; verify the Windows archive contains distinct GUI/console PE subsystems and all rebuildable source.

Unsigned early desktop trial. The Shift wheel remains opt-in; Linux has no global wheel/island. Windows workers have no hard memory cap and are not an OS sandbox. Multi-monitor/high-DPI/Windows Terminal configurations still need real user confirmation. Mac remains 0.1.10, ad-hoc signed and unnotarized. Keep the previous release for rollback.
