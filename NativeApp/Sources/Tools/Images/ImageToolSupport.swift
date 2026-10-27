import AppKit
import CoreImage
import SwiftUI

enum ImageToolSupport {
    static func outputFormat(for source: URL) -> FileFormat {
        let format = FileFormat.detect(source) ?? .png
        switch format {
        case .svg, .bmp: return .png
        case .avif: return ImageIOBridge.canEncodeNatively(format) ? format : .png
        default: return format
        }
    }

    @MainActor
    static func save(_ session: ToolSession, suffix: String, format: FileFormat? = nil, title: String? = nil, render: @escaping () async throws -> CGImage) {
        let output = format ?? outputFormat(for: session.primary)
        let destination = session.outputURL(suffix: suffix, ext: output.fileExtension)
        let quality = AppSettings.shared.jpegQuality
        let metadata = ImageIOBridge.properties(session.primary)
        session.run(title: title ?? session.tool.progressTitle, detail: session.primary.lastPathComponent) { progress in
            let image = try await render()
            progress(0.7)
            if ImageIOBridge.canEncodeNatively(output) {
                var keep: [CFString: Any] = [:]
                if let exif = metadata[kCGImagePropertyExifDictionary] { keep[kCGImagePropertyExifDictionary] = exif }
                if let tiff = metadata[kCGImagePropertyTIFFDictionary] { keep[kCGImagePropertyTIFFDictionary] = tiff }
                try ImageIOBridge.write(image, to: destination, format: output, quality: quality, metadata: keep.isEmpty ? nil : keep)
            } else {
                try await ImageIOBridge.writeAnyFormat(image, to: destination, format: output, quality: quality)
            }
            return [destination]
        }
    }

    @MainActor
    static func saveEach(_ session: ToolSession, suffix: String, title: String, detail: String, render: @escaping (URL, CGImage) throws -> CGImage) {
        let files = session.files
        let quality = AppSettings.shared.jpegQuality
        let destinations = files.map { url -> (URL, FileFormat) in
            let output = outputFormat(for: url)
            return (ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: suffix, ext: output.fileExtension), output)
        }
        session.run(title: title, detail: detail) { progress in
            var outputs: [URL] = []
            for (index, url) in files.enumerated() {
                let (destination, output) = destinations[index]
                let source = try ImageIOBridge.load(url)
                let result = try render(url, source)
                try await ImageIOBridge.writeAnyFormat(result, to: destination, format: output, quality: quality)
                outputs.append(destination)
                progress(Double(index + 1) / Double(files.count))
            }
            return outputs
        }
    }

    static func cgImage(_ ci: CIImage, context: CIContext = sharedContext) -> CGImage? {
        context.createCGImage(ci, from: ci.extent)
    }

    static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
}

struct AspectPreset: Identifiable, Hashable {
    let title: String
    let ratio: CGFloat?
    var id: String { title }

    static let all: [AspectPreset] = [
        AspectPreset(title: "Free", ratio: nil),
        AspectPreset(title: "Original", ratio: -1),
        AspectPreset(title: "Square", ratio: 1),
        AspectPreset(title: "4:3", ratio: 4 / 3),
        AspectPreset(title: "3:2", ratio: 3 / 2),
        AspectPreset(title: "16:9", ratio: 16 / 9),
        AspectPreset(title: "9:16", ratio: 9 / 16),
        AspectPreset(title: "3:4", ratio: 3 / 4),
        AspectPreset(title: "2:3", ratio: 2 / 3),
        AspectPreset(title: "5:4", ratio: 5 / 4),
    ]
}

struct ColorSwatchPicker: View {
    let title: String
    @Binding var color: Color

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
        }
    }
}

