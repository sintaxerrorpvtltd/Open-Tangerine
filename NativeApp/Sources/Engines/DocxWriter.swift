import Foundation
import ImageIO

enum ZipTool {
    static func zip(directory: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let result = try await Shell.run("/usr/bin/zip", ["-r", "-X", "-q", destination.path, "."], currentDirectory: directory)
        guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
    }

    static func zipOrdered(directory: URL, entries: [String], to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        var args = ["-X", "-q", destination.path]
        args += entries
        let result = try await Shell.run("/usr/bin/zip", args, currentDirectory: directory)
        guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
    }

    static func unzip(_ archive: URL, into directory: URL) async throws {
        let result = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        guard result.succeeded else { throw OpenTangerineError.toolFailed("ditto", result.stderr) }
    }
}

enum DocxWriter {
    enum Block {
        case paragraph(String), image(URL), pageBreak
        /// Formatted paragraph; `size` on images is the rendered size in CSS pixels (96 per inch).
        case text([Run], Style)
        case sizedImage(URL, CGSize)
        case table([[Cell]])
    }

    enum Style: Equatable {
        case body
        case heading(Int)
        case quote
        case code
        case listItem(ordered: Bool, level: Int, list: Int)
    }

    struct Run: Equatable {
        var text: String
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var monospace = false
        var link: URL?
    }

    struct Cell: Equatable {
        var runs: [Run]
        var header = false
        var span = 1
    }

    static func write(paragraphs: [String], images: [URL], to destination: URL) async throws {
        try await write(blocks: paragraphs.map { .paragraph($0) } + images.map { .image($0) }, to: destination)
    }

    static func write(blocks: [Block], to destination: URL) async throws {
        let images = blocks.compactMap { block -> URL? in
            switch block {
            case .image(let url), .sizedImage(let url, _): return url
            default: return nil
            }
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("opentangerine-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        var relationships = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        var body = ""
        var contentTypesExtra = ""
        var seenExtensions = Set<String>()
        var imageIndex = 0
        var links: [URL: String] = [:]
        var orderedLists: [Int: Int] = [:]
        func linkID(_ url: URL) -> String {
            if let id = links[url] { return id }
            let id = "rIdL\(links.count + 1)"
            links[url] = id
            relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escape(url.absoluteString))\" TargetMode=\"External\"/>"
            return id
        }
        func numberingID(ordered: Bool, list: Int) -> Int {
            guard ordered else { return 1 }
            if let id = orderedLists[list] { return id }
            let id = orderedLists.count + 2
            orderedLists[list] = id
            return id
        }
        for block in blocks {
            let image: URL
            var displaySize: CGSize?
            switch block {
            case .paragraph(let paragraph):
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(escape(paragraph))</w:t></w:r></w:p>"
                continue
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                continue
            case .text(let runs, let style):
                var properties = ""
                switch style {
                case .body: break
                case .heading(let level): properties = "<w:pStyle w:val=\"Heading\(min(max(level, 1), 6))\"/>"
                case .quote: properties = "<w:pStyle w:val=\"Quote\"/>"
                case .code: properties = "<w:pStyle w:val=\"Code\"/>"
                case .listItem(let ordered, let level, let list):
                    properties = "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(max(level, 0), 8))\"/><w:numId w:val=\"\(numberingID(ordered: ordered, list: list))\"/></w:numPr>"
                }
                body += "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runsXML(runs, linkID: linkID) + "</w:p>"
                continue
            case .table(let rows):
                body += tableXML(rows, linkID: linkID)
                continue
            case .image(let url):
                image = url
            case .sizedImage(let url, let size):
                image = url
                displaySize = size
            }
            let index = imageIndex
            imageIndex += 1
            let ext = image.pathExtension.lowercased().isEmpty ? "png" : image.pathExtension.lowercased()
            let name = "image\(index + 1).\(ext)"
            try fm.copyItem(at: image, to: staging.appendingPathComponent("word/media/\(name)"))
            let rid = "rId\(index + 10)"
            relationships += "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
            let size = displaySize ?? ImageIOBridge.pixelSize(image)
            let maxWidthEMU = 5_943_600.0
            let maxHeightEMU = 8_229_600.0
            var widthEMU = max(size.width, 1) * 9525
            var heightEMU = max(size.height, 1) * 9525
            let scale = min(maxWidthEMU / widthEMU, maxHeightEMU / heightEMU, 1)
            widthEMU *= scale
            heightEMU *= scale
            body += drawing(rid: rid, id: index + 1, name: name, cx: Int(widthEMU), cy: Int(heightEMU))
            if !seenExtensions.contains(ext) {
                seenExtensions.insert(ext)
                let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext)"
                contentTypesExtra += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
            }
        }
        let usesNumbering = blocks.contains { if case .text(_, .listItem) = $0 { return true }; return false }
        let usesRichText = blocks.contains {
            switch $0 {
            case .text, .table: return true
            case .paragraph, .image, .sizedImage, .pageBreak: return false
            }
        }
        if usesNumbering {
            relationships += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
        }

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(contentTypesExtra)
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        \(usesNumbering ? "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>" : "")
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body>
        </w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        \(usesRichText ? richStyles : "")
        </w:styles>
        """

        try contentTypes.write(to: staging.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: staging.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try documentRels.write(to: staging.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try document.write(to: staging.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try styles.write(to: staging.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)

        var entries = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/_rels/document.xml.rels"]
        if usesNumbering {
            try numberingXML(orderedLists: orderedLists.values.sorted()).write(to: staging.appendingPathComponent("word/numbering.xml"), atomically: true, encoding: .utf8)
            entries.append("word/numbering.xml")
        }
        for index in images.indices {
            let ext = images[index].pathExtension.lowercased().isEmpty ? "png" : images[index].pathExtension.lowercased()
            entries.append("word/media/image\(index + 1).\(ext)")
        }
        try await ZipTool.zipOrdered(directory: staging, entries: entries, to: destination)
    }

    private static func runsXML(_ runs: [Run], bold forceBold: Bool = false, linkID: (URL) -> String) -> String {
        var xml = ""
        var index = runs.startIndex
        while index < runs.endIndex {
            guard let link = runs[index].link else {
                xml += runXML(runs[index], bold: forceBold)
                index += 1
                continue
            }
            // Adjacent runs that share a target become one clickable hyperlink.
            var linked = ""
            while index < runs.endIndex, runs[index].link == link {
                linked += runXML(runs[index], bold: forceBold)
                index += 1
            }
            xml += "<w:hyperlink r:id=\"\(linkID(link))\">\(linked)</w:hyperlink>"
        }
        return xml
    }

    private static func runXML(_ run: Run, bold forceBold: Bool) -> String {
        var properties = ""
        if run.link != nil { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
        if run.monospace { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
        if run.bold || forceBold { properties += "<w:b/>" }
        if run.italic { properties += "<w:i/>" }
        if run.strike { properties += "<w:strike/>" }
        if run.underline { properties += "<w:u w:val=\"single\"/>" }
        let cleaned = String(String.UnicodeScalarView(run.text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }))
        var content = ""
        for (lineIndex, line) in cleaned.components(separatedBy: "\n").enumerated() {
            if lineIndex > 0 { content += "<w:br/>" }
            for (tabIndex, piece) in line.components(separatedBy: "\t").enumerated() {
                if tabIndex > 0 { content += "<w:tab/>" }
                if !piece.isEmpty { content += "<w:t xml:space=\"preserve\">\(escape(piece))</w:t>" }
            }
        }
        return "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + content + "</w:r>"
    }

    private static func tableXML(_ rows: [[Cell]], linkID: (URL) -> String) -> String {
        let columns = max(rows.map { $0.reduce(0) { $0 + max($1.span, 1) } }.max() ?? 1, 1)
        let width = 9360 / columns
        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\""
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders><w:top \(border)/><w:left \(border)/><w:bottom \(border)/><w:right \(border)/><w:insideH \(border)/><w:insideV \(border)/></w:tblBorders><w:tblCellMar><w:left w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"80\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
        for row in rows {
            let isHeader = !row.isEmpty && row.allSatisfy(\.header)
            xml += "<w:tr>" + (isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            var used = 0
            for cell in row {
                let span = min(max(cell.span, 1), columns - used)
                guard span > 0 else { break }
                used += span
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width * span)\" w:type=\"dxa\"/>" + (span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "") + "</w:tcPr><w:p>\(runsXML(cell.runs, bold: cell.header, linkID: linkID))</w:p></w:tc>"
            }
            // Word expects every row to fill the grid.
            for _ in used..<columns { xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>" }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p/>"
    }

    private static let richStyles = """
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="300" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="22"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:i/><w:sz w:val="22"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="40"/></w:pPr></w:style>
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
    """

    private static func numberingXML(orderedLists: [Int]) -> String {
        let bullets = ["•", "◦", "▪"]
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        func level(_ index: Int, format: String, text: String) -> String {
            "<w:lvl w:ilvl=\"\(index)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (index + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        """
        xml += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        xml += (0..<9).map { level($0, format: "bullet", text: bullets[$0 % 3]) }.joined() + "</w:abstractNum>"
        xml += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        xml += (0..<9).map { level($0, format: formats[$0 % 3], text: "%\($0 + 1).") }.joined() + "</w:abstractNum>"
        xml += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        // Each HTML <ol> restarts at 1, so it gets its own numbering instance.
        for id in orderedLists {
            xml += "<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"1\"/>" + (0..<9).map { "<w:lvlOverride w:ilvl=\"\($0)\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" }.joined() + "</w:num>"
        }
        return xml + "</w:numbering>"
    }

    private static func drawing(rid: String, id: Int, name: String, cx: Int, cy: Int) -> String {
        """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(id)" name="\(name)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
