# Document and PDF roadmap

Tracks [issue #11](https://github.com/sintaxerrorpvtltd/Open-Tangerine/issues/11). These are proposals, not shipped capabilities or promised dates.

## Current boundary

The native Mac app exports PDF content/images to DOCX and has text/image/PDF tools. It does not import DOCX. The Windows/Linux edition handles image-to-PDF, PDF merge/split, existing-text extraction and DOCX body/table text to plain text or a Latin-only text-layout PDF; it has no formatted Office import, OCR or encrypted-PDF tools. Both keep processing local.

## Separate, reviewable contributions

1. **DOCX text extraction / explicit text-layout PDF:** bounded ZIP and XML parsing; reject entity expansion, oversize packages and unsupported fonts; label formatting loss. Test malformed archives, tables, Unicode and batches before shipping. Formatted Office conversion is a separate route. *Windows/Linux: implemented for body text and tables; the PDF uses built-in Helvetica (Latin only). Embedded Unicode fonts remain open.*
2. **Formatted Office to PDF:** opt-in trusted local converter, isolated profile, macros disabled, no silent download. Verify cancellation kills descendants, external-link behavior and output limits on Windows/Linux. PR #2 starts LibreOffice in a new POSIX session, escaping the parent worker’s cancellation group; this must be fixed before integration.
3. **PDF password protection:** a separate design/test pass for encryption choices, password handling, permissions and round-trip opening. Do not describe PDF permissions as absolute protection.
4. **OCR/searchable PDFs and compression:** optional local tooling, language/layout tests, clear resource limits and measured fidelity. Never silently replace originals or discard pages.

Forms, digital signatures/certificate verification, content editing, true redaction, PDF/A, Bates numbering, portfolios and document comparison each need a focused proposal. They are not treated as one bug fix. Redaction must remove underlying content, not merely cover it; signing requires actual cryptographic verification.

Every contribution needs original preservation, collision-safe output, batch error reporting, timeout/cancellation tests and accurate platform documentation. Please split Office work out of the Windows wheel PR so its parser/dependency changes can be reviewed independently.
