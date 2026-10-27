import AppKit
import Foundation
import PDFKit

@main struct HTMLTests {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTangerine-html-\(UUID())")
        let site = root.appendingPathComponent("site")
        try fm.createDirectory(at: site.appendingPathComponent("css"), withIntermediateDirectories: true)
        try fm.createDirectory(at: site.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func write(_ html: String, _ name: String, in folder: URL? = nil) throws -> URL {
            let file = (folder ?? site).appendingPathComponent(name)
            try html.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func convert(_ source: URL, _ target: FileFormat, _ name: String, _ options: HTMLOptions? = nil) async throws -> URL {
            let output = url(name)
            let request = ConversionRequest(source: source, sourceFormat: .html, target: target, destination: output, progress: { _ in })
            if let options {
                try await HTMLEngine(options: options).convert(request)
            } else {
                try await Engines.convert(request)
            }
            return output
        }
        func magic(_ file: URL, _ count: Int = 12) -> [UInt8] {
            Array((try? Data(contentsOf: file))?.prefix(count) ?? Data())
        }
        func isValid(_ file: URL, as format: FileFormat) -> Bool {
            let bytes = magic(file)
            guard bytes.count >= 12, ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { return false }
            switch format {
            case .pdf: return bytes.starts(with: Array("%PDF-".utf8)) && PDFDocument(url: file) != nil
            case .png: return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) && (try? ImageIOBridge.load(file)) != nil
            case .jpg: return bytes.starts(with: [0xFF, 0xD8, 0xFF]) && (try? ImageIOBridge.load(file)) != nil
            case .webp: return bytes.starts(with: Array("RIFF".utf8)) && Array(bytes[8..<12]) == Array("WEBP".utf8)
            case .docx: return bytes.starts(with: [0x50, 0x4B, 0x03, 0x04])
            default: return false
            }
        }
        func docx(_ file: URL) async throws -> (xml: String, text: String, listing: String) {
            let xml = try await Shell.run("/usr/bin/unzip", ["-p", file.path, "word/document.xml"])
            let listing = try await Shell.run("/usr/bin/unzip", ["-l", file.path])
            // textutil is the system Word importer; a malformed package fails here.
            let text = try await Shell.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", file.path])
            precondition(xml.succeeded && text.succeeded, "DOCX does not open: \(text.stderr)")
            return (xml.stdout, text.stdout, listing.stdout)
        }
        func pixel(_ file: URL, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
            let image = try ImageIOBridge.load(file)
            var data = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
            return (Int(data[0]), Int(data[1]), Int(data[2]))
        }
        func expectFailure(_ message: String, containing expected: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                fatalError("\(message) reported success")
            } catch {
                precondition(error.localizedDescription.contains(expected), "\(message): unexpected error \(error.localizedDescription)")
            }
        }

        // Fixtures: a 4 × 4 green PNG and an SVG used through relative paths.
        let green = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        green.setFillColor(NSColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1).cgColor)
        green.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        try ImageIOBridge.write(green.makeImage()!, to: site.appendingPathComponent("images/dot.png"), format: .png)
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="#36c"/></svg>"##
            .write(to: site.appendingPathComponent("images/bar.svg"), atomically: true, encoding: .utf8)
        try ".banner { background: rgb(255, 128, 0); height: 200px; margin: 0 } body { margin: 0; font-family: Georgia, serif } @media print { .screen-only { display: none } }"
            .write(to: site.appendingPathComponent("css/style.css"), atomically: true, encoding: .utf8)

        let simple = try write("<!doctype html><html><head><meta charset=\"utf-8\"><title>Simple</title></head><body><h1>Open Tangerine HTML test</h1><p>Caf\u{e9} &amp; &lt;content&gt;</p></body></html>", "simple.html")
        let styled = try write("""
            <!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="css/style.css"></head>
            <body><div class="banner"></div><p class="screen-only">Screen only</p><p>Printed text</p>
            <img src="images/dot.png" width="100" height="100" alt="Green dot"><img src="images/missing.png" alt="Missing picture"></body></html>
            """, "styled.htm")
        let structure = try write("""
            <!doctype html><html><head><meta charset="utf-8"><style>.hidden { display: none }</style></head><body>
            <h1>Quarterly report</h1><h2>Summary</h2>
            <p>Revenue <b>grew</b> by <i>twelve</i> percent. See <a href="https://example.com/report">the full report</a>.</p>
            <p class="hidden">Hidden paragraph</p>
            <ul><li>First bullet</li><li>Second bullet<ul><li>Nested bullet</li></ul></li></ul>
            <ol><li>Step one</li><li>Step two</li></ol>
            <table><thead><tr><th>Region</th><th>Sales</th></tr></thead><tbody><tr><td>North</td><td>120</td></tr><tr><td colspan="2">Total 120</td></tr></tbody></table>
            <blockquote>Quoted line</blockquote><pre>let x = 1
            let y = 2</pre>
            <p><img src="images/dot.png" width="40" height="40" alt="dot"> <img src="images/bar.svg" alt="bar"></p>
            <p><a href="javascript:alert(1)">Unsafe link</a></p>
            </body></html>
            """, "structure.html")
        // No charset declared on purpose: WebKit alone would read this as Windows-1252.
        let unicode = try write("<html><body><h1>नमस्ते दुनिया</h1><p>Emoji 🍊 and Café</p></body></html>", "unicode.html")
        let long = try write("<!doctype html><meta charset=utf-8><body>" + (1...400).map { "<p>Paragraph \($0) of a long page that keeps going.</p>" }.joined() + "</body>", "long.html")
        let huge = try write("<!doctype html><meta charset=utf-8><body style=\"margin:0\"><div style=\"height:60000px;background:linear-gradient(#fff,#000)\">Tall</div></body>", "huge.html")

        // PDF
        let simplePDF = try await convert(simple, .pdf, "simple.pdf")
        precondition(isValid(simplePDF, as: .pdf))
        precondition(PDFDocument(url: simplePDF)!.pageCount == 1 && PDFDocument(url: simplePDF)!.string!.contains("Open Tangerine HTML test"))
        print("PASS HTML -> PDF (default settings through Engines)")
        var a4 = HTMLOptions()
        a4.pageSize = .a4
        let styledPDF = try await convert(styled, .pdf, "styled.pdf", a4)
        let styledDoc = PDFDocument(url: styledPDF)!
        let a4Bounds = styledDoc.page(at: 0)!.bounds(for: .mediaBox)
        precondition(abs(a4Bounds.width - 595) < 2 && abs(a4Bounds.height - 842) < 2, "A4 size \(a4Bounds)")
        precondition(styledDoc.string!.contains("Printed text") && !styledDoc.string!.contains("Screen only"), "print media CSS ignored: \(styledDoc.string!.debugDescription) pages=\(styledDoc.pageCount)")
        print("PASS HTML -> PDF A4 with print media CSS")
        var landscape = HTMLOptions()
        landscape.pageSize = .letter
        landscape.landscape = true
        landscape.margins = .none
        let landscapePDF = try await convert(simple, .pdf, "landscape.pdf", landscape)
        let landscapeBounds = PDFDocument(url: landscapePDF)!.page(at: 0)!.bounds(for: .mediaBox)
        precondition(abs(landscapeBounds.width - 792) < 2 && abs(landscapeBounds.height - 612) < 2, "Letter landscape \(landscapeBounds)")
        print("PASS HTML -> PDF Letter landscape")
        // CSS @page wins over the Settings page size, as in browsers; linked stylesheets in the folder count too.
        let inlinePage = try write("<!doctype html><style>@page { size: A4 landscape; margin: 0 } body { margin: 0 } .bleed { height: 200px; background: rgb(255, 0, 0) }</style><div class=\"bleed\"></div>", "page-inline.html")
        var letterNormal = HTMLOptions()
        letterNormal.pageSize = .letter
        letterNormal.margins = .normal
        let inlinePagePDF = try await convert(inlinePage, .pdf, "page-inline.pdf", letterNormal)
        let inlineBounds = PDFDocument(url: inlinePagePDF)!.page(at: 0)!.bounds(for: .mediaBox)
        precondition(abs(inlineBounds.width - 842) < 2 && abs(inlineBounds.height - 595) < 2, "@page size ignored: \(inlineBounds)")
        let corner = PDFRenderer.render(page: PDFDocument(url: inlinePagePDF)!.page(at: 0)!, dpi: 72)!
        let cornerFile = url("page-inline.png")
        try ImageIOBridge.write(corner, to: cornerFile, format: .png)
        let cornerPixel = try pixel(cornerFile, x: 3, y: 3)
        precondition(cornerPixel.r > 200 && cornerPixel.g < 60, "@page margin: 0 ignored: \(cornerPixel)")
        try "@page { size: 210mm 148mm; margin: 1in }".write(to: site.appendingPathComponent("css/page.css"), atomically: true, encoding: .utf8)
        let linkedPage = try write("<!doctype html><link rel=\"stylesheet\" href=\"css/page.css\"><p>Linked page rule</p>", "page-linked.html")
        let linkedBounds = PDFDocument(url: try await convert(linkedPage, .pdf, "page-linked.pdf", letterNormal))!.page(at: 0)!.bounds(for: .mediaBox)
        precondition(abs(linkedBounds.width - 595) < 2 && abs(linkedBounds.height - 420) < 2, "linked @page size ignored: \(linkedBounds)")
        precondition(HTMLPage.points("2.54cm").map { abs($0 - 72) < 0.01 } == true && HTMLPage.pageSize("letter landscape").0 == CGSize(width: 792, height: 612))
        print("PASS CSS @page size and margins (inline and linked) override the Settings page")
        let longPDF = try await convert(long, .pdf, "long.pdf", a4)
        let longPages = PDFDocument(url: longPDF)!.pageCount
        precondition(longPages >= 5 && longPages <= 30, "long page count \(longPages)")
        print("PASS long HTML -> PDF paginates into \(longPages) pages")

        // Images
        var options = HTMLOptions()
        options.viewportWidth = 800
        for target: FileFormat in [.png, .jpg, .webp] {
            let out = try await convert(styled, target, "styled.\(target.fileExtension)", options)
            precondition(isValid(out, as: target), "\(target) invalid")
            if target != .webp || ImageIOBridge.canEncodeNatively(.webp) {
                let image = try ImageIOBridge.load(out)
                precondition(image.width == 800 && image.height >= 300, "\(target) size \(image.width)x\(image.height)")
            }
            if target == .png {
                let banner = try pixel(out, x: 10, y: 10)
                precondition(banner.r > 240 && (110...145).contains(banner.g) && banner.b < 20, "external CSS not applied: \(banner)")
                let dot = try pixel(out, x: 50, y: 300)
                precondition(dot.g > 150 && dot.r < 60, "relative image not rendered: \(dot)")
            }
            print("PASS HTML -> \(target.displayName) full page with external CSS and relative images")
        }
        options.scale = 2
        let retina = try ImageIOBridge.load(try await convert(simple, .png, "retina.png", options))
        precondition(retina.width == 1600, "scale 2 width \(retina.width)")
        options.scale = 1
        options.capture = .viewport
        options.viewportHeight = 600
        let fixed = try ImageIOBridge.load(try await convert(long, .png, "viewport.png", options))
        precondition(fixed.width == 800 && fixed.height == 600, "viewport \(fixed.width)x\(fixed.height)")
        let fullLong = try ImageIOBridge.load(try await convert(long, .jpg, "long.jpg", HTMLOptions()))
        precondition(fullLong.height > 4000, "full page height \(fullLong.height)")
        print("PASS HTML images: 2x scale, fixed viewport, long full page (\(fullLong.height) px)")
        await expectFailure("60,000 px screenshot", containing: "limited to 16,383 pixels") {
            _ = try await convert(huge, .png, "huge.png", HTMLOptions())
        }
        _ = try await convert(huge, .png, "huge-viewport.png", options)
        print("PASS oversized full-page screenshot rejected; visible-area capture still works")

        // DOCX
        let structureDOCX = try await convert(structure, .docx, "structure.docx", HTMLOptions())
        precondition(isValid(structureDOCX, as: .docx))
        let parts = try await docx(structureDOCX)
        for expected in ["w:val=\"Heading1\"", "w:val=\"Heading2\"", "<w:b/>", "<w:i/>", "<w:hyperlink", "<w:numPr>", "<w:tbl>", "<w:gridSpan w:val=\"2\"/>", "<w:tblHeader/>", "w:val=\"Quote\"", "w:val=\"Code\"", "<w:drawing>"] {
            precondition(parts.xml.contains(expected), "DOCX missing \(expected)")
        }
        for expected in ["Quarterly report", "the full report", "Nested bullet", "Step two", "North", "Total 120", "Quoted line", "let y = 2"] {
            precondition(parts.text.contains(expected), "DOCX text missing \(expected)")
        }
        precondition(!parts.text.contains("Hidden paragraph"), "hidden content exported")
        precondition(parts.listing.contains("word/numbering.xml") && parts.listing.contains("image1.png") && parts.listing.contains("image2.png"))
        let rels = try await Shell.run("/usr/bin/unzip", ["-p", structureDOCX.path, "word/_rels/document.xml.rels"])
        precondition(rels.stdout.contains("https://example.com/report") && !rels.stdout.contains("javascript:"), "link relationships")
        let svgData = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>"##.utf8).base64EncodedString()
        let mixedImages = try write("<!doctype html><img src=\"https://example.com/remote.png\"><img src=\"data:image/svg+xml;base64,\(svgData)\" width=\"8\" height=\"8\"><img src=\"images/dot.png\">", "images.html")
        var offline = HTMLOptions()
        offline.allowsRemoteContent = false
        let mixedParts = try await docx(try await convert(mixedImages, .docx, "images.docx", offline))
        precondition(mixedParts.listing.contains("image1.png") && mixedParts.listing.contains("image2.png"), "skipped image displaced the next one: \(mixedParts.listing)")
        print("PASS HTML -> DOCX headings, runs, links, nested lists, tables, quote, code and images")
        let styledDOCX = try await docx(try await convert(styled, .docx, "styled.docx", HTMLOptions()))
        precondition(styledDOCX.text.contains("Missing picture") && styledDOCX.listing.contains("image1.png"), "missing asset handling")
        print("PASS missing image keeps alt text and the conversion succeeds")

        // Encodings
        let unicodeDOCX = try await docx(try await convert(unicode, .docx, "unicode.docx", HTMLOptions()))
        precondition(unicodeDOCX.text.contains("नमस्ते दुनिया") && unicodeDOCX.text.contains("🍊") && unicodeDOCX.text.contains("Café"), "undeclared UTF-8 decoded wrongly")
        let latin = site.appendingPathComponent("latin1.html")
        try Data("<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\"></head><body><p>Fa\u{E7}ade na\u{EF}ve</p></body></html>".data(using: .isoLatin1)!).write(to: latin)
        let latinData = try Data(contentsOf: latin)
        precondition(HTMLSource.encodingName(latinData).lowercased() == "iso-8859-1")
        let latinDOCX = try await docx(try await convert(latin, .docx, "latin.docx", HTMLOptions()))
        precondition(latinDOCX.text.contains("Façade naïve"), "declared Latin-1 decoded wrongly")
        let unicodePNG = try await convert(unicode, .png, "unicode.png", HTMLOptions())
        precondition(isValid(unicodePNG, as: .png))
        print("PASS UTF-8 without a declaration (Devanagari, emoji) and declared ISO-8859-1")

        // JavaScript and isolation
        let outside = root.appendingPathComponent("secret.txt")
        try "TOP SECRET".write(to: outside, atomically: true, encoding: .utf8)
        try ImageIOBridge.write(green.makeImage()!, to: root.appendingPathComponent("outside.png"), format: .png)
        let scripted = try write("""
            <!doctype html><meta charset=utf-8><body><p>Static text</p><img src="../outside.png" alt="outside image">
            <script>
            document.body.insertAdjacentHTML('beforeend', '<p>Script ran</p>');
            fetch('../secret.txt').then(r => r.text()).then(t => document.body.insertAdjacentHTML('beforeend', '<p>' + t + '</p>')).catch(() => {});
            fetch('http://127.0.0.1:9/').catch(() => {});
            location.href = 'https://example.com/';
            </script></body>
            """, "scripted.html")
        let noScript = try await docx(try await convert(scripted, .docx, "noscript.docx", HTMLOptions()))
        precondition(noScript.text.contains("Static text") && !noScript.text.contains("Script ran"), "JavaScript ran while disabled")
        precondition(!noScript.listing.contains("word/media/"), "image outside the HTML folder was embedded")
        var withScript = HTMLOptions()
        withScript.allowsJavaScript = true
        let script = try await docx(try await convert(scripted, .docx, "script.docx", withScript))
        precondition(script.text.contains("Script ran") && script.text.contains("Static text"), "JavaScript did not run when enabled, or the page navigated away")
        precondition(!script.text.contains("TOP SECRET"), "file outside the HTML folder was readable")
        print("PASS JavaScript off by default, opt-in works, navigation and files outside the folder are blocked")

        // Remote content is off by default; when enabled, loopback and private addresses written in URLs stay blocked.
        precondition(!HTMLOptions().allowsRemoteContent && !HTMLOptions().allowsJavaScript, "HTML defaults changed")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            let serverLog = url("server.log")
            fm.createFile(atPath: serverLog.path, contents: nil)
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-u", "-m", "http.server", "18765", "--bind", "127.0.0.1", "--directory", root.path]
            server.standardOutput = FileHandle.nullDevice
            server.standardError = try FileHandle(forWritingTo: serverLog)
            try server.run()
            defer { server.terminate() }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let local = try write("<!doctype html><img src=\"http://127.0.0.1:18765/a.png\"><img src=\"http://localhost:18765/b.png\"><img src=\"http://localhost.:18765/d.png\"><img src=\"http://2130706433:18765/e.png\"><link rel=\"stylesheet\" href=\"http://user@127.0.0.1:18765/c.css\"><p>Private hosts</p>", "private.html")
            var remote = HTMLOptions()
            remote.allowsJavaScript = true
            remote.allowsRemoteContent = true
            _ = try await convert(local, .png, "private.png", remote)
            _ = try? Data(contentsOf: URL(string: "http://127.0.0.1:18765/control")!)
            try await Task.sleep(nanoseconds: 300_000_000)
            let requests = try String(contentsOf: serverLog, encoding: .utf8).components(separatedBy: "\n").filter { $0.contains("GET") }
            precondition(requests.count == 1 && requests[0].contains("/control"), "private address contacted: \(requests)")
            print("PASS remote content is opt-in and loopback and private addresses stay blocked")
        } else {
            print("SKIP private address check (python3 unavailable)")
        }

        // Error cases
        let empty = try write("  \n", "empty.html")
        await expectFailure("Empty HTML", containing: "is empty") { _ = try await convert(empty, .pdf, "empty.pdf", HTMLOptions()) }
        let malformed = try write("<html><body><p><b>Unclosed bold <table><tr><td>cell<div>stray</p></i></body>", "malformed.html")
        let malformedPDF = try await convert(malformed, .pdf, "malformed.pdf", HTMLOptions())
        precondition(isValid(malformedPDF, as: .pdf))
        let malformedDOCX = try await docx(try await convert(malformed, .docx, "malformed.docx", HTMLOptions()))
        precondition(malformedDOCX.text.contains("cell"))
        let spinning = try write("<!doctype html><body><p>Busy</p><script>while (true) {}</script></body>", "spin.html")
        var short = withScript
        short.timeout = 2
        let started = Date()
        await expectFailure("Endless script", containing: "took longer than 2 seconds") { _ = try await convert(spinning, .png, "spin.png", short) }
        precondition(Date().timeIntervalSince(started) < 15, "timeout was not enforced")
        await expectFailure("Script-only DOCX", containing: "no text or images") {
            _ = try await convert(try write("<!doctype html><body><script>document.write('x')</script></body>", "scriptonly.html"), .docx, "scriptonly.docx", HTMLOptions())
        }
        print("PASS empty, malformed, endless script timeout and empty DOCX cases")

        // Cleanup: no staged files next to outputs and no leftover DOCX image folders.
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".opentangerine-") }
        let tempLeftovers = try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path).filter { ["opentangerine-htmldocx-", "opentangerine-htmlpdf-", "opentangerine-docx-"].contains(where: $0.hasPrefix) }
        precondition(leftovers.isEmpty && tempLeftovers.isEmpty, "temporary files left behind: \(leftovers + tempLeftovers)")
        precondition(ConversionMatrix.targets(for: .html) == [.pdf, .docx, .png, .jpg, .webp] && FileFormat.detect(styled) == .html)
        print("PASS HTML registration and temporary file cleanup")
    }
}
