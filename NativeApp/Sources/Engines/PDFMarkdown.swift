import AppKit
import Foundation
import PDFKit

/// Converts the selectable text of a PDF into CommonMark-style Markdown.
///
/// PDFs store positioned glyphs rather than document structure, so the result is a
/// best-effort reconstruction from font sizes, font traits, line positions and link
/// annotations: headings, paragraphs, bold/italic/code spans, bullet and numbered
/// lists, code blocks and web links. Tables, images and multi-column reading order are
/// not reconstructed. Scanned pages have no selectable text and need OCR.
enum PDFMarkdown {
    struct Style: Equatable {
        var bold = false
        var italic = false
        var mono = false
    }

    struct Run {
        var text: String
        var style: Style
        var size: CGFloat
        var link: URL? = nil
    }

    struct Line {
        var runs: [Run]
        var bounds: CGRect
        var links: [(text: String, url: URL)] = []

        var text: String { runs.map(\.text).joined() }
    }

    enum Block {
        case heading(level: Int, runs: [Run])
        case paragraph([Run])
        case listItem(ordered: String?, level: Int, runs: [Run])
        case code([String])
        /// Raw Markdown emitted verbatim (used for notes such as pages without text).
        case note(String)
    }

    // MARK: - Public entry points

    static func convert(_ document: PDFDocument, progress: (Double) -> Void = { _ in }) throws -> String {
        let pageCount = document.pageCount
        var pages: [[Line]] = []
        for index in 0..<pageCount {
            pages.append(document.page(at: index).map(lines(on:)) ?? [])
            progress(Double(index + 1) / Double(pageCount) * 0.8)
        }
        guard pages.contains(where: { !$0.isEmpty }) else {
            throw OpenTangerineError.invalidInput("This PDF has no selectable text. Scanned pages require OCR, which is not supported yet.")
        }
        let markdown = render(pages: pages)
        progress(1)
        return markdown
    }

    // MARK: - Extraction

    static func lines(on page: PDFPage) -> [Line] {
        let box = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: box) else { return [] }
        let linkAnnotations: [(CGRect, URL)] = page.annotations.compactMap { annotation in
            guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
            return (annotation.bounds, url)
        }
        var result: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            guard let attributed = lineSelection.attributedString else { continue }
            var runs: [Run] = []
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                let raw = (attributed.string as NSString).substring(with: range)
                let text = raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                guard !text.isEmpty else { return }
                let font = attributes[.font] as? NSFont
                let run = Run(text: text, style: style(of: font), size: font?.pointSize ?? 0)
                if let last = runs.last, last.style == run.style, abs(last.size - run.size) < 0.5 {
                    runs[runs.count - 1].text += text
                } else {
                    runs.append(run)
                }
            }
            let bounds = lineSelection.bounds(for: page)
            guard !runs.isEmpty, runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            var line = Line(runs: runs, bounds: bounds)
            for (rect, url) in linkAnnotations where rect.intersects(bounds) {
                let clipped = rect.intersection(bounds).insetBy(dx: -1, dy: -1)
                if let text = page.selection(for: clipped)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    line.links.append((text, url))
                }
            }
            result.append(line)
        }
        return dropPageNumbers(result)
    }

    static func style(of font: NSFont?) -> Style {
        guard let font else { return Style() }
        let traits = font.fontDescriptor.symbolicTraits
        let name = font.fontName.lowercased()
        let bold = traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
        let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
        let mono = traits.contains(.monoSpace) || ["mono", "courier", "consolas", "menlo", "code"].contains { name.contains($0) }
        return Style(bold: bold, italic: italic, mono: mono)
    }

    /// Removes a bare page number ("12", "Page 3", "3 of 10") at the top or bottom of a page.
    static func dropPageNumbers(_ lines: [Line]) -> [Line] {
        guard lines.count > 1 else { return lines }
        let pattern = #"^\s*(page\s+)?\d{1,4}(\s*(of|/)\s*\d{1,4})?\s*$"#
        func isPageNumber(_ line: Line) -> Bool {
            line.text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        var lines = lines
        if let last = lines.last, isPageNumber(last) { lines.removeLast() }
        if let first = lines.first, isPageNumber(first), lines.count > 1 { lines.removeFirst() }
        return lines
    }

    // MARK: - Structure

    static let bulletMarkers: Set<Character> = ["•", "◦", "▪", "▫", "■", "□", "●", "○", "‣", "⁃", "·", "–", "-", "*", "\u{F0B7}", "\u{F0A7}"]

    /// Returns (ordered marker, characters to drop) when a line starts a list item.
    /// `indentedLikeList` allows bare numbers ("1 Step"), which some writers emit without a period.
    static func listMarker(_ text: String, indentedLikeList: Bool = false) -> (ordered: String?, drop: Int)? {
        let leading = text.prefix { $0 == " " || $0 == "\t" }.count
        let body = text.dropFirst(leading)
        guard let first = body.first else { return nil }
        if bulletMarkers.contains(first) {
            let rest = body.dropFirst()
            let symbolBullet = !["-", "*", "–"].contains(first)
            // ASCII-like dashes need a following space; typographic bullets may touch the text.
            if let next = rest.first, next == " " || next == "\t" {
                let spaces = rest.prefix { $0 == " " || $0 == "\t" }.count
                guard spaces < rest.count else { return nil }
                return (nil, leading + 1 + spaces)
            }
            if symbolBullet, let next = rest.first, !next.isWhitespace { return (nil, leading + 1) }
            return nil
        }
        if let match = body.range(of: #"^\d{1,3}[.)][ \t]+"#, options: .regularExpression) {
            let marker = body[match].trimmingCharacters(in: .whitespaces)
            guard body[match.upperBound...].contains(where: { !$0.isWhitespace }) else { return nil }
            let number = marker.dropLast()
            return ("\(number).", leading + body.distance(from: body.startIndex, to: match.upperBound))
        }
        if indentedLikeList, let match = body.range(of: #"^\d{1,2}[ \t]+(?=\p{L})"#, options: .regularExpression) {
            let number = body[match].trimmingCharacters(in: .whitespaces)
            return ("\(number).", leading + body.distance(from: body.startIndex, to: match.upperBound))
        }
        return nil
    }

    static func bodySize(_ pages: [[Line]]) -> CGFloat {
        var histogram: [CGFloat: Int] = [:]
        for line in pages.joined() {
            for run in line.runs where run.size > 0 {
                let key = (run.size * 2).rounded() / 2
                histogram[key, default: 0] += run.text.filter { !$0.isWhitespace }.count
            }
        }
        return histogram.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? 11
    }

    static func dominantSize(_ line: Line) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for run in line.runs { weights[(run.size * 2).rounded() / 2, default: 0] += run.text.filter { !$0.isWhitespace }.count }
        return weights.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key ?? 0
    }

    static func headingLevel(_ line: Line, body: CGFloat) -> Int? {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard text.count <= 200, body > 0 else { return nil }
        let ratio = dominantSize(line) / body
        if ratio >= 1.6 { return 1 }
        if ratio >= 1.3 { return 2 }
        if ratio >= 1.12 { return 3 }
        return nil
    }

    static func isCode(_ line: Line) -> Bool {
        let visible = line.runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return !visible.isEmpty && visible.allSatisfy(\.style.mono)
    }

    /// Lower quartile: ordinary line spacing even on pages dominated by paragraph or list gaps.
    static func lowerQuartile(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 4]
    }

    static func blocks(pages: [[Line]]) -> [Block] {
        let body = bodySize(pages)
        var blocks: [Block] = []
        var listBaseX: CGFloat?
        var lastListLevel = -1

        for (pageIndex, lines) in pages.enumerated() {
            if lines.isEmpty {
                blocks.append(.note("<!-- Page \(pageIndex + 1) has no selectable text. Scanned pages require OCR, which is not supported yet. -->"))
                listBaseX = nil; lastListLevel = -1
                continue
            }
            let gaps = zip(lines, lines.dropFirst()).map { $0.bounds.minY - $1.bounds.maxY }.filter { $0 >= 0 }
            let typicalGap = lowerQuartile(gaps) ?? 0
            let paragraphGap = max(typicalGap * 1.6, typicalGap + body * 0.35)
            let rightEdge = lines.map(\.bounds.maxX).max() ?? 0
            let leftEdge = lines.map(\.bounds.minX).min() ?? 0
            var previous: Line?

            for line in lines {
                let text = line.text
                let gap = previous.map { $0.bounds.minY - line.bounds.maxY }
                let separated = previous == nil || gap! < -body || gap! > paragraphGap

                if isCode(line) {
                    let raw = text.replacingOccurrences(of: "\t", with: "    ")
                    if let previous, isCode(previous), let gap, gap >= 0, gap <= paragraphGap * 2, case .code(var codeLines)? = blocks.last {
                        if separated { codeLines.append("") }
                        codeLines.append(raw)
                        blocks[blocks.count - 1] = .code(codeLines)
                    } else {
                        blocks.append(.code([raw]))
                    }
                    listBaseX = nil; lastListLevel = -1
                    previous = line
                    continue
                }

                if let level = headingLevel(line, body: body) {
                    let runs = withLinks(line)
                    if !separated, case .heading(let lastLevel, let lastRuns)? = blocks.last, lastLevel == level {
                        blocks[blocks.count - 1] = .heading(level: level, runs: join(lastRuns, runs))
                    } else {
                        blocks.append(.heading(level: level, runs: runs))
                    }
                    listBaseX = nil; lastListLevel = -1
                    previous = line
                    continue
                }

                let indent = line.bounds.minX - leftEdge
                if let marker = listMarker(text, indentedLikeList: indent > body * 0.5 && indent < body * 4) {
                    let base = listBaseX ?? line.bounds.minX
                    if listBaseX == nil || line.bounds.minX < base { listBaseX = line.bounds.minX }
                    let indentStep = max(body * 1.2, 8)
                    var level = max(0, Int(((line.bounds.minX - (listBaseX ?? base)) / indentStep).rounded(.down)))
                    level = min(level, lastListLevel + 1, 3)
                    lastListLevel = level
                    let runs = dropPrefix(withLinks(line), count: marker.drop)
                    blocks.append(.listItem(ordered: marker.ordered, level: level, runs: runs))
                    previous = line
                    continue
                }

                let runs = withLinks(line)
                let previousText = previous?.text.trimmingCharacters(in: .whitespaces) ?? ""
                let previousEndedShort = previous.map { rightEdge - $0.bounds.maxX > body * 4 } ?? false
                // Far shorter than the text width: the end of a paragraph or a table cell, not a wrap.
                let previousEndedVeryShort = previous.map { rightEdge - $0.bounds.maxX > (rightEdge - leftEdge) * 0.4 } ?? false
                let endsSentence = previousText.last.map { ".!?:".contains($0) } ?? false
                let indented = previous.map { line.bounds.minX - $0.bounds.minX > body * 0.9 } ?? false
                let wholeLineBold = runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy(\.style.bold)

                if let last = blocks.last, previous != nil, !separated {
                    switch last {
                    case .listItem(let ordered, let level, let itemRuns) where line.bounds.minX > (listBaseX ?? leftEdge) + 1:
                        blocks[blocks.count - 1] = .listItem(ordered: ordered, level: level, runs: join(itemRuns, runs))
                        previous = line
                        continue
                    case .paragraph(let paragraphRuns):
                        let previousBold = previous!.runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy(\.style.bold)
                        let breaks = (previousEndedShort && endsSentence) || previousEndedVeryShort || indented || (previousBold != wholeLineBold && (previousBold || previousEndedShort))
                        if !breaks {
                            blocks[blocks.count - 1] = .paragraph(join(paragraphRuns, runs))
                            previous = line
                            continue
                        }
                    default:
                        break
                    }
                }

                // A sentence that runs across a page break continues the previous paragraph.
                if previous == nil, case .paragraph(let paragraphRuns)? = blocks.last,
                   let lastChar = paragraphRuns.map(\.text).joined().trimmingCharacters(in: .whitespaces).last,
                   !".!?:".contains(lastChar),
                   let firstChar = text.trimmingCharacters(in: .whitespaces).first, firstChar.isLowercase {
                    blocks[blocks.count - 1] = .paragraph(join(paragraphRuns, runs))
                    previous = line
                    continue
                }

                blocks.append(.paragraph(runs))
                listBaseX = nil; lastListLevel = -1
                previous = line
            }
        }
        return blocks
    }

    /// Splits runs so that each link annotation's text becomes its own run carrying the URL.
    static func withLinks(_ line: Line) -> [Run] {
        var runs = line.runs
        for (linkText, url) in line.links {
            guard let index = runs.firstIndex(where: { $0.link == nil && $0.text.contains(linkText) }),
                  let range = runs[index].text.range(of: linkText) else { continue }
            let run = runs[index]
            var pieces: [Run] = []
            let before = String(run.text[..<range.lowerBound])
            let after = String(run.text[range.upperBound...])
            if !before.isEmpty { pieces.append(Run(text: before, style: run.style, size: run.size)) }
            pieces.append(Run(text: linkText, style: run.style, size: run.size, link: url))
            if !after.isEmpty { pieces.append(Run(text: after, style: run.style, size: run.size)) }
            runs.replaceSubrange(index...index, with: pieces)
        }
        return runs
    }

    static func join(_ lhs: [Run], _ rhs: [Run]) -> [Run] {
        guard var last = lhs.last, let first = rhs.first else { return lhs + rhs }
        var left = lhs
        let trimmedLast = last.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let trimmedFirst = first.text.drop { $0 == " " }
        // Rejoin a word hyphenated across lines ("conver-" + "sion").
        if trimmedLast.count > 1, trimmedLast.hasSuffix("-"),
           trimmedLast.dropLast().last?.isLetter == true, trimmedFirst.first?.isLowercase == true,
           last.link == nil, first.link == nil {
            last.text = String(trimmedLast.dropLast())
            left[left.count - 1] = last
            var right = rhs
            right[0].text = String(trimmedFirst)
            return left + right
        }
        last.text = trimmedLast
        left[left.count - 1] = last
        return left + [Run(text: " ", style: last.style, size: last.size)] + rhs.enumerated().map { index, run in
            var run = run
            if index == 0 { run.text = String(run.text.drop { $0 == " " }) }
            return run
        }
    }

    static func dropPrefix(_ runs: [Run], count: Int) -> [Run] {
        var remaining = count
        var result: [Run] = []
        for var run in runs {
            if remaining > 0 {
                let length = run.text.count
                if length <= remaining { remaining -= length; continue }
                run.text = String(run.text.dropFirst(remaining))
                remaining = 0
            }
            result.append(run)
        }
        return result
    }

    // MARK: - Rendering

    static func render(pages: [[Line]]) -> String {
        render(blocks: blocks(pages: pages))
    }

    static func render(blocks: [Block]) -> String {
        var output = ""
        var previous: Block?
        for block in blocks {
            let rendered: String
            switch block {
            case .heading(let level, let runs):
                rendered = String(repeating: "#", count: level) + " " + escapeLineStart(inline(runs, styled: false))
            case .paragraph(let runs):
                rendered = escapeLineStart(inline(runs, styled: true))
            case .listItem(let ordered, let level, let runs):
                let indent = String(repeating: "    ", count: level)
                rendered = indent + (ordered ?? "-") + " " + escapeLineStart(inline(runs, styled: true))
            case .note(let text):
                rendered = text
            case .code(let lines):
                let longestTicks = lines.map { line in
                    line.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                }.max() ?? 0
                let fence = String(repeating: "`", count: max(3, longestTicks + 1))
                rendered = fence + "\n" + lines.joined(separator: "\n") + "\n" + fence
            }
            if let previous {
                if case .listItem = previous, case .listItem = block { output += "\n" } else { output += "\n\n" }
            }
            output += rendered
            previous = block
        }
        return output.isEmpty ? "" : output + "\n"
    }

    static func inline(_ runs: [Run], styled: Bool) -> String {
        // Group consecutive runs with the same style and link so markers wrap whole phrases.
        var groups: [(style: Style, link: URL?, text: String)] = []
        for run in runs {
            let style = styled ? run.style : Style()
            if let last = groups.last, last.style == style, last.link == run.link {
                groups[groups.count - 1].text += run.text
            } else {
                groups.append((style, run.link, run.text))
            }
        }
        var result = ""
        for group in groups {
            if let url = group.link {
                let address = url.absoluteString
                let label = group.text.trimmingCharacters(in: .whitespaces)
                let bare = address.replacingOccurrences(of: #"^(https?://|mailto:)"#, with: "", options: .regularExpression)
                let link: String
                if label == address || label == bare || label + "/" == bare {
                    link = "<" + address.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ">", with: "%3E") + ">"
                } else {
                    link = "[" + escape(label) + "](" + escapeURL(address) + ")"
                }
                result += wrap(link, style: group.style)
            } else if group.style.mono {
                result += code(group.text)
            } else {
                result += wrap(escape(group.text), style: group.style)
            }
        }
        return result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func wrap(_ text: String, style: Style) -> String {
        guard style.bold || style.italic else { return text }
        let leading = String(text.prefix { $0.isWhitespace })
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let marker = style.bold && style.italic ? "***" : style.bold ? "**" : "*"
        return leading + marker + core + marker + trailing
    }

    static func code(_ text: String) -> String {
        let leading = String(text.prefix { $0.isWhitespace })
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let longestTicks = core.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: longestTicks + 1)
        let padded = core.hasPrefix("`") || core.hasSuffix("`") ? " " + core + " " : core
        return leading + fence + padded + fence + trailing
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Prevents paragraph text from being read as a heading, quote, list or rule.
    static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#>+-=|".contains(first) { return "\\" + text }
        if let match = text.range(of: #"^\d+(?=[.)])"#, options: .regularExpression) {
            return text[match] + "\\" + text[match.upperBound...]
        }
        return text
    }
}
