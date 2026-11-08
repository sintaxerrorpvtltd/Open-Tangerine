import AppKit
import Foundation
import PDFKit

@main struct DocumentTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTangerine-documents-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func convert(_ source: URL, _ from: FileFormat, _ to: FileFormat, _ name: String) async throws -> URL {
            let output = url(name)
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: from, target: to, destination: output, progress: { _ in }))
            return output
        }
        let text = "Open Tangerine document test\nCafé & <content>\n\nSecond paragraph."
        try text.write(to: url("input.txt"), atomically: true, encoding: .utf8)
        let pdf = try await convert(url("input.txt"), .txt, .pdf, "text.pdf")
        precondition(PDFDocument(url: pdf)!.string!.contains("Open Tangerine"))
        for target: FileFormat in [.png, .jpg, .srt, .vtt] {
            let out = try await convert(url("input.txt"), .txt, target, "text.\(target.fileExtension)")
            if target == .png || target == .jpg { precondition(try! ImageIOBridge.load(out).width == 1275) }
            else { precondition(try! String(contentsOf: out, encoding: .utf8).contains("Second paragraph")) }
            print("PASS TXT -> \(target)")
        }
        for target: FileFormat in [.png, .jpg, .txt, .docx] {
            let out = try await convert(pdf, .pdf, target, "pdf.\(target.fileExtension)")
            switch target {
            case .png, .jpg: precondition(try! ImageIOBridge.load(out).width == 2550)
            case .txt: precondition(try! String(contentsOf: out, encoding: .utf8).contains("Open Tangerine"))
            case .docx:
                let result = try await Shell.run("/usr/bin/unzip", ["-p", out.path, "word/document.xml"])
                precondition(result.succeeded && result.stdout.contains("Open Tangerine") && result.stdout.contains("&amp;"))
            default: break
            }
            print("PASS PDF -> \(target)")
        }
        let second = url("second.pdf")
        try TextRenderer.writePDF("Second page marker", to: second)
        let merged = url("merged.pdf")
        try PDFOps.merge([pdf, second], to: merged)
        let mergedDoc = try PDFOps.document(merged)
        precondition(mergedDoc.pageCount == 2 && mergedDoc.page(at: 1)!.string!.contains("Second page"))
        for mode: PDFOps.SplitMode in [.everyPage, .everyN, .ranges] {
            let outputs = try PDFOps.split(merged, mode: mode, every: 2, ranges: "2", into: url("split-\(mode.rawValue)"))
            precondition(outputs.count == (mode == .everyPage ? 2 : 1))
            precondition(try! PDFOps.document(outputs[0]).pageCount == (mode == .everyN ? 2 : 1))
            print("PASS PDF split \(mode)")
        }
        try PDFOps.assemble(pages: [PDFPageRef(sourceIndex: 1, rotation: 90, sourceURL: merged), PDFPageRef(sourceIndex: 0, rotation: 0, sourceURL: merged)], to: url("reordered.pdf"))
        let reordered = try PDFOps.document(url("reordered.pdf"))
        precondition(reordered.page(at: 0)!.rotation == 90 && reordered.page(at: 0)!.string!.contains("Second page"))
        for strong in [false, true] {
            let out = url("compressed-\(strong).pdf")
            try PDFOps.compress(merged, strong: strong, to: out)
            precondition(try! PDFOps.document(out).pageCount == 2)
            print("PASS PDF compression strong=\(strong), preserves page count (size reduction not guaranteed)")
        }
        let imagePDF = url("images.pdf")
        try PDFOps.fromImages([url("text.png"), url("text.jpg")], to: imagePDF, progress: { _ in })
        precondition(try! PDFOps.document(imagePDF).pageCount == 2)
        let multiImages = try await convert(merged, .pdf, .png, "pages.png")
        let pages = try fm.contentsOfDirectory(at: multiImages, includingPropertiesForKeys: nil)
        precondition(pages.count == 2)
        for page in pages { precondition(try! ImageIOBridge.load(page).width == 2550) }
        let scanDOCX = try await convert(imagePDF, .pdf, .docx, "scanned.docx")
        let listing = try await Shell.run("/usr/bin/unzip", ["-l", scanDOCX.path])
        precondition(listing.stdout.contains("image1.png") && listing.stdout.contains("image2.png"))
        do { _ = try await convert(imagePDF, .pdf, .txt, "scan.txt"); fatalError("Empty scanned text reported as success") } catch { }
        let protected = url("protected.pdf")
        precondition(mergedDoc.write(to: protected, withOptions: [.userPasswordOption: "test-password", .ownerPasswordOption: "owner-password"]))
        do { _ = try await convert(protected, .pdf, .png, "locked.png"); fatalError("Locked PDF accepted") } catch { }
        let mixed = url("mixed.pdf")
        try PDFOps.merge([imagePDF, pdf], to: mixed)
        let mixedDocx = try await convert(mixed, .pdf, .docx, "mixed.docx")
        let mixedXML = try await Shell.run("/usr/bin/unzip", ["-p", mixedDocx.path, "word/document.xml"])
        precondition(mixedXML.stdout.range(of: "<w:drawing>")!.lowerBound < mixedXML.stdout.range(of: "Open Tangerine")!.lowerBound)
        precondition(mixedXML.stdout.contains("w:type=\"page\""))
        print("PASS mixed scanned/text PDF -> DOCX preserves page order and breaks")
        print("PASS PDF merge/reorder/rotate, images-to-PDF, multipage export, scanned DOCX, scanned/locked rejection")
        let srt = "1\n00:00:01,250 --> 00:00:03,000\nHello <i>world</i>\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond cue\n"
        try srt.write(to: url("captions.srt"), atomically: true, encoding: .utf8)
        let vtt = try await convert(url("captions.srt"), .srt, .vtt, "captions.vtt")
        let roundtrip = try await convert(vtt, .vtt, .srt, "roundtrip.srt")
        let cues = SubtitleParser.parse(try String(contentsOf: roundtrip, encoding: .utf8), hint: .srt)
        precondition(cues.count == 2 && cues[0].start == 1.25 && cues[1].end == 5)
        for (source, format) in [(url("captions.srt"), FileFormat.srt), (vtt, .vtt)] {
            let out = try await convert(source, format, .txt, "\(format).txt")
            precondition(try! String(contentsOf: out, encoding: .utf8).contains("Hello world"))
        }
        precondition(SubtitleParser.format(59.9999, separator: ",") == "00:01:00,000")
        precondition(SubtitleParser.parseTimestamp("nan") == nil)
        print("PASS SRT/VTT round trip + both TXT exports; millisecond carry and invalid timestamp")
        try await markdownTests(root: root, convert: convert)
    }

    /// Draws positioned lines with named fonts, which survive PDFKit text extraction.
    static func structuredPDF(_ pages: [[(x: CGFloat, y: CGFloat, runs: [(String, String, CGFloat)])]], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            for line in page {
                let text = NSMutableAttributedString()
                for (string, font, size) in line.runs {
                    text.append(NSAttributedString(string: string, attributes: [.font: NSFont(name: font, size: size)!]))
                }
                context.textPosition = CGPoint(x: line.x, y: line.y)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor static func markdownTests(root: URL, convert: (URL, FileFormat, FileFormat, String) async throws -> URL) async throws {
        let regular = "Helvetica", bold = "Helvetica-Bold", italic = "Helvetica-Oblique", mono = "Courier"
        func plain(_ x: CGFloat, _ y: CGFloat, _ text: String) -> (x: CGFloat, y: CGFloat, runs: [(String, String, CGFloat)]) {
            (x, y, [(text, regular, 11)])
        }
        let draft = root.appendingPathComponent("structured-draft.pdf")
        structuredPDF([[
            (72, 740, [("Quarterly Report", bold, 24)]),
            (72, 704, [("Overview", bold, 16)]),
            (72, 680, [("This report covers ", regular, 11), ("bold", bold, 11), (" and ", regular, 11), ("italic", italic, 11), (" text with a conver-", regular, 11)]),
            plain(72, 666, "sion that wraps onto a second line."),
            plain(72, 640, "Prices use 5*3 and file_name values."),
            plain(72, 614, "• First item"),
            plain(72, 600, "• Second item"),
            plain(90, 586, "◦ Nested item"),
            plain(72, 560, "1. Step one"),
            plain(72, 546, "2. Step two"),
            (72, 520, [("let x = 1", mono, 11)]),
            (72, 506, [("print(x)", mono, 11)]),
            plain(72, 480, "Visit Open Tangerine for details."),
            plain(72, 454, "# not a heading"),
            plain(72, 428, "This sentence continues on the"),
            plain(300, 40, "1"),
        ], [
            plain(72, 740, "next page as well."),
        ]], to: draft)
        let document = PDFDocument(url: draft)!
        let target = document.findString("Open Tangerine", withOptions: []).first!
        let link = PDFAnnotation(bounds: target.bounds(for: document.page(at: 0)!), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/open-tangerine")
        document.page(at: 0)!.addAnnotation(link)
        let source = root.appendingPathComponent("structured.pdf")
        precondition(document.write(to: source))

        let output = try await convert(source, .pdf, .md, "structured.md")
        precondition(output.pathExtension == "md")
        let markdown = try String(contentsOf: output, encoding: .utf8)
        let expected = """
        # Quarterly Report

        ## Overview

        This report covers **bold** and *italic* text with a conversion that wraps onto a second line.

        Prices use 5\\*3 and file\\_name values.

        - First item
        - Second item
            - Nested item
        1. Step one
        2. Step two

        ```
        let x = 1
        print(x)
        ```

        Visit [Open Tangerine](https://example.com/open-tangerine) for details.

        \\# not a heading

        This sentence continues on the next page as well.

        """
        if markdown != expected {
            FileHandle.standardError.write(Data("Expected:\n\(expected)\nActual:\n\(markdown)\n".utf8))
            fatalError("PDF -> Markdown structure mismatch")
        }
        print("PASS PDF -> Markdown headings, emphasis, hyphenation, escaping, lists, code, links, page numbers, page continuation")

        let scanned = root.appendingPathComponent("images.pdf")
        do { _ = try await convert(scanned, .pdf, .md, "scan.md"); fatalError("Empty scanned Markdown reported as success") } catch { }
        let mixed = try await convert(root.appendingPathComponent("mixed.pdf"), .pdf, .md, "mixed.md")
        let mixedText = try String(contentsOf: mixed, encoding: .utf8)
        precondition(mixedText.contains("<!-- Page 1 has no selectable text") && mixedText.contains("Open Tangerine document test"))
        print("PASS PDF -> Markdown rejects scanned-only PDFs and notes scanned pages in mixed PDFs")

        let notes = root.appendingPathComponent("notes.md")
        try "# Notes\n\nPlain **markdown** input.".write(to: notes, atomically: true, encoding: .utf8)
        let notesPDF = try await convert(notes, .md, .pdf, "notes.pdf")
        precondition(PDFDocument(url: notesPDF)!.string!.contains("Plain"))
        print("PASS Markdown input still converts to PDF")
    }
}
