# Security

This is a developer trial, not a hardened file-processing boundary. Process only files you trust while worker isolation is unfinished.

No account, telemetry, file upload or AI service is implemented. Version checks contact the fixed public GitHub releases endpoint without file contents or credentials. Normal logging is off. `OPEN_TANGERINE_DEBUG=1` opts into local diagnostic logs which may contain filenames; do not publish them without review.

Conversion staging never deletes an existing destination. Native image input has file-size and pixel limits. External processes receive argument arrays and have bounded captured output. Archive conversion is disabled pending safe extraction. Original files are retained by conversion workflows.

Known release gates: sandboxed workers, hard CPU/memory/time/output limits, metadata and redaction verification, SVG external-resource analysis, archive traversal/link/bomb tests, concurrency-safe publication across every tool, malicious parser corpus, cancellation/process cleanup and code signing/notarization. File extensions are not a trust boundary.

To report a vulnerability, use GitHub private vulnerability reporting if enabled; otherwise open a non-sensitive issue asking for a private contact. Do not post private files, secrets, or a working exploit publicly. Do not claim a security audit based on the current regression tests.

## Windows/Linux desktop edition

`Desktop/` has disposable conversion workers, parent deadlines and cancellation, bounded worker diagnostics, explicit FFmpeg argument arrays and network protocol exclusion, input size/pixel/page limits, and exclusive no-overwrite output publication (atomic hardlinks where supported; non-atomic exclusive-copy fallback for removable disks). Linux adds address-space/CPU/file limits; Windows puts each worker (and the tools it starts) in a job object with a 3 GiB memory limit that also ends them if the app exits. If Windows refuses to create the job object, that worker runs without the cap. Workers retain the user's filesystem permissions and are not a sandbox. Direct symlinks/reparse points are rejected, but hostile concurrent filesystem changes and parent-path reparse points are not fully isolated. Do not process untrusted files. No archive parser or SVG renderer is enabled. PDF transformations are not sanitization; active content can remain. Normal cancellation cleans parent-owned staging after stopping the worker. An application/system crash can leave temporary work or a partial fallback copy. Platform-specific CI is a regression gate, not a security certification.
