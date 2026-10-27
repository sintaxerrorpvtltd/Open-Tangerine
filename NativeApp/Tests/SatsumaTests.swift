import AppKit
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class TestRunner {
    private var failures: [String] = []
    private var count = 0

    func test(_ name: String, _ body: () throws -> Void) {
        count += 1
        do {
            try body()
            print("  ok   \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(count - failures.count)/\(count) passed")
        exit(failures.isEmpty ? 0 : 1)
    }
}

func expect(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) throws {
    if !condition { throw TestFailure(description: "\(message) (\(file):\(line))") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if a != b { throw TestFailure(description: "\(message) expected \(b), got \(a) (\(file):\(line))") }
}

@main
struct OpenTangerineTests {
    static func main() {
        let runner = TestRunner()

        runner.test("conversion matrix excludes disabled archives") {
            try expectEqual(ConversionMatrix.totalConversions, 181)
            try expectEqual(ConversionMatrix.targets(for: .zip).count, 0)
        }

        runner.test("25 advanced tools") {
            try expectEqual(ToolID.total, 25)
        }

        runner.test("no format converts to itself") {
            for format in FileFormat.allCases {
                try expect(!ConversionMatrix.targets(for: format).contains(format), "\(format) targets itself")
            }
        }

        runner.test("JPG and PNG export DOCX, other images do not") {
            try expect(ConversionMatrix.targets(for: .jpg).contains(.docx), "jpg → docx")
            try expect(ConversionMatrix.targets(for: .png).contains(.docx), "png → docx")
            try expect(!ConversionMatrix.targets(for: .webp).contains(.docx), "webp → docx")
            try expect(ConversionMatrix.targets(for: .svg).contains(.pdf), "svg → pdf")
        }

        runner.test("video exports GIF and MP3, GIF does not") {
            try expect(ConversionMatrix.targets(for: .mp4).contains(.gif), "mp4 → gif")
            try expect(ConversionMatrix.targets(for: .mp4).contains(.mp3), "mp4 → mp3")
            try expect(!ConversionMatrix.targets(for: .gif).contains(.mp3), "gif → mp3")
            try expectEqual(ConversionMatrix.targets(for: .gif), FileFormat.video)
        }

        runner.test("PDF, TXT, subtitle and archive targets") {
            try expectEqual(ConversionMatrix.targets(for: .pdf), [.docx, .jpg, .png, .txt])
            try expectEqual(ConversionMatrix.targets(for: .txt), [.pdf, .jpg, .png, .srt, .vtt])
            try expectEqual(ConversionMatrix.targets(for: .srt), [.vtt, .txt])
            try expectEqual(ConversionMatrix.targets(for: .zip), [])
            try expectEqual(ConversionMatrix.targets(for: .docx), [])
            try expectEqual(ConversionMatrix.targets(for: .html), [.pdf, .docx, .png, .jpg, .webp])
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/page.HTM")), .html)
        }

        runner.test("mixed selection intersects targets") {
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .webp]), [.png, .heic, .tiff, .avif, .bmp, .pdf])
            try expectEqual(ConversionMatrix.targets(for: [.jpg, .mp3]), [])
            try expectEqual(ConversionMatrix.targets(for: []), [])
        }

        runner.test("format detection from extension and aliases") {
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/Photo.JPEG")), .jpg)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.tif")), .tiff)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.tgz")), .gz)
            try expectEqual(FileFormat.detect(URL(fileURLWithPath: "/tmp/a.unknown")), nil)
        }

        runner.test("stripped base names") {
            try expectEqual(ConversionMatrix.strippedBaseName("archive.tar.gz"), "archive")
            try expectEqual(ConversionMatrix.strippedBaseName("archive.tgz"), "archive")
            try expectEqual(ConversionMatrix.strippedBaseName("my.photo.HEIC"), "my.photo")
            try expectEqual(ConversionMatrix.strippedBaseName(".hidden"), ".hidden")
            try expectEqual(ConversionMatrix.strippedBaseName("noext"), "noext")
        }

        runner.test("output naming avoids collisions") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = URL(fileURLWithPath: "/tmp/photo.heic")
            let first = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir)
            try expectEqual(first.lastPathComponent, "photo.jpg")
            try Data().write(to: first)
            let second = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir)
            try expectEqual(second.lastPathComponent, "photo 2.jpg")
            let third = ConversionMatrix.outputURL(for: source, target: .jpg, in: dir, existing: ["photo 2.jpg"])
            try expectEqual(third.lastPathComponent, "photo 3.jpg")
            let suffixed = ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "compressed", ext: "jpg")
            try expectEqual(suffixed.lastPathComponent, "photo compressed.jpg")
            try Data().write(to: suffixed)
            try expectEqual(ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "compressed", ext: "jpg").lastPathComponent, "photo compressed 2.jpg")
            try expectEqual(ConversionMatrix.uniqueURL(directory: dir, baseName: "photo", suffix: "", ext: "pdf").lastPathComponent, "photo.pdf")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("clip clips"), withIntermediateDirectories: true)
            try expectEqual(ConversionMatrix.uniqueDirectory(directory: dir, name: "clip clips").lastPathComponent, "clip clips 2")
        }

        runner.test("SRT parsing") {
            let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\nWorld\n\n2\n00:01:00,000 --> 00:01:03,250\n<i>Bye</i>\n"
            let cues = SubtitleParser.parse(srt, hint: .srt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 1)
            try expectEqual(cues[0].end, 2.5)
            try expectEqual(cues[0].text, "Hello\nWorld")
            try expectEqual(cues[1].start, 60)
            try expectEqual(cues[1].end, 63.25)
        }

        runner.test("VTT parsing with header, notes and cue settings") {
            let vtt = "WEBVTT\nKind: captions\n\nNOTE comment\n\n00:01.000 --> 00:02.000 align:start\nFirst\n\n01:00:00.000 --> 01:00:01.000\nSecond\n"
            let cues = SubtitleParser.parse(vtt, hint: .vtt)
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 1)
            try expectEqual(cues[0].end, 2)
            try expectEqual(cues[0].text, "First")
            try expectEqual(cues[1].start, 3600)
        }

        runner.test("subtitle serialization round trip") {
            let cues = [SubtitleCue(start: 0.5, end: 2, text: "A"), SubtitleCue(start: 3661.25, end: 3662, text: "B\nC")]
            let srt = SubtitleParser.serialize(cues, as: .srt)
            try expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:02,000\nA\n\n2\n01:01:01,250 --> 01:01:02,000\nB\nC\n"), "srt output: \(srt)")
            let vtt = SubtitleParser.serialize(cues, as: .vtt)
            try expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nA\n\n"), "vtt output: \(vtt)")
            let back = SubtitleParser.parse(vtt, hint: .vtt)
            try expectEqual(back.count, 2)
            try expectEqual(back[1].start, 3661.25)
            try expectEqual(SubtitleParser.serialize([SubtitleCue(start: 0, end: 1, text: "<b>x</b> {\\an8}y")], as: .txt), "x y\n")
        }

        runner.test("plain text becomes timed cues") {
            let cues = SubtitleParser.plainTextCues("One two three\n\nFour five")
            try expectEqual(cues.count, 2)
            try expectEqual(cues[0].start, 0)
            try expect(cues[1].start == cues[0].end, "cues are contiguous")
            try expect(cues[0].end - cues[0].start >= 1.5, "minimum duration")
        }

        runner.test("timestamp parsing") {
            try expectEqual(SubtitleParser.parseTimestamp("00:00:01,500"), 1.5)
            try expectEqual(SubtitleParser.parseTimestamp("01:02.250"), 62.25)
            try expectEqual(SubtitleParser.parseTimestamp("5"), 5)
            try expectEqual(SubtitleParser.parseTimestamp("a:b"), nil)
            try expectEqual(TimeFormatter.parseClock("1:02.5"), 62.5)
            try expectEqual(TimeFormatter.clock(62.5), "1:02.50")
        }

        runner.test("PDF page range parsing") {
            try expectEqual(PDFOps.parseRanges("1-3, 5, 7-6, 12", pageCount: 10), [1...3, 5...5, 6...7])
            try expectEqual(PDFOps.parseRanges("-2, 8-", pageCount: 10), [1...2, 8...10])
            try expectEqual(PDFOps.parseRanges("abc", pageCount: 10), [])
        }

        runner.test("tool applicability") {
            try expect(ToolID.cropImage.applies(to: [.jpg]), "crop single image")
            try expect(!ToolID.cropImage.applies(to: [.jpg, .png]), "crop needs one image")
            try expect(ToolID.createCollage.applies(to: [.jpg, .heic]), "collage multiple images")
            try expect(!ToolID.createCollage.applies(to: [.jpg]), "collage needs two")
            try expect(ToolID.compress.applies(to: [.pdf, .pdf]), "compress pdfs")
            try expect(!ToolID.compress.applies(to: [.jpg, .mp4]), "mixed categories")
            try expect(!ToolID.trimVideo.applies(to: [.gif]), "gif is not trimmable")
            try expect(ToolID.compress.applies(to: [.gif]), "gif compress")
            try expect(!ToolID.mergePDF.applies(to: [.docx, .docx]), "docx merge")
            try expectEqual(ToolID.available(for: [.mp3]).count, 7)
            try expectEqual(ToolID.available(for: [.pdf]).count, 4)
        }

        runner.test("compression presets") {
            try expect(CompressionPreset.strong.imageQuality < CompressionPreset.balanced.imageQuality, "strong is smaller")
            try expect(CompressionPreset.strong.videoBitrateFactor < CompressionPreset.balanced.videoBitrateFactor, "strong video")
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.svg")), .jpg)
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.jpg")), .jpg)
            try expectEqual(Compressor.outputFormat(for: URL(fileURLWithPath: "/tmp/a.wav")), .m4a)
        }

        runner.test("FFmpeg timecode formatting") {
            try expectEqual(FFmpeg.timecode(3661.5), "01:01:01.500")
            try expectEqual(FFmpeg.timecode(0), "00:00:00.000")
        }

        runner.test("sf symbols resolve") {
            for tool in ToolID.allCases {
                try expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "\(tool.rawValue) symbol \(tool.symbol)")
            }
            for category in FormatCategory.allCases {
                try expect(NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil) != nil, "\(category.rawValue) symbol")
            }
        }

        runner.finish()
    }
}

