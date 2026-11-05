import AppKit
import Foundation
import PDFKit
import WebKit

// Exercise the distribution we actually ship, its loopback transport, and PDF.js's
// saveDocument path. A rendered form field is edited and reopened with a different parser.
@main struct PDFEditorTests {
    @MainActor static func main() async throws {
        // WebKit startup or script evaluation can stall on a broken host.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            FileHandle.standardError.write(Data("PDF editor integration timed out after 60 seconds\n".utf8))
            exit(1)
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("form.pdf")
        // Keep input bytes identical across PDFKit versions. PDFKit verifies the result.
        let fixture = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("NativeApp/Tests/Fixtures/editable-form.pdf")
        try fm.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let assets = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/pdf-editor-test")
        let server = try PDFEditorSession(source: source, assets: assets)
        defer { server.stop() }
        let viewer: URL = try await withCheckedThrowingContinuation { continuation in
            server.start { result in continuation.resume(with: result) }
        }
        let origin = URL(string: "http://127.0.0.1:\(viewer.port!)")!
        let http = URLSession(configuration: .ephemeral)
        defer { http.invalidateAndCancel() }
        for path in ["/document.pdf", "/wrong/web/viewer.html", "/\(viewer.pathComponents[1])/unknown"] {
            let (_, response) = try await http.data(from: origin.appendingPathComponent(path))
            precondition((response as? HTTPURLResponse)?.statusCode == 404)
        }
        let (_, htmlResponse) = try await http.data(from: viewer)
        precondition((htmlResponse as? HTTPURLResponse)?.statusCode == 200)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        view.load(URLRequest(url: viewer))
        var ready = false
        for _ in 0..<120 {
            if (try? await view.evaluateJavaScript("!!window.PDFViewerApplication?.pdfDocument && !!document.querySelector('[name=SampleField]')")) as? Bool == true {
                ready = true; break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard ready else {
            let diagnostic = (try? await view.evaluateJavaScript("JSON.stringify({title:document.title,text:document.body?.innerText?.slice(0,500),pages:window.PDFViewerApplication?.pdfDocument?.numPages,visibility:document.visibilityState,layers:document.querySelectorAll('.annotationLayer').length,widgets:document.querySelectorAll('.textWidgetAnnotation').length})")) as? String
            throw OpenTangerineError.invalidInput("PDF editor did not render the fixture: \(diagnostic ?? "unavailable")")
        }
        let result = try await view.callAsyncJavaScript("""
            if (PDFViewerApplicationOptions.get('enableScripting') !== false) throw Error('PDF scripting enabled');
            for (const id of ['editorHighlightButton','editorFreeTextButton','editorInkButton']) {
              if (!document.getElementById(id)) throw Error('Missing tool ' + id);
            }
            const field = document.querySelector('[name=SampleField]');
            field.focus(); field.value='Edited locally'; field.dispatchEvent(new Event('input',{bubbles:true})); field.blur();
            const bytes=await PDFViewerApplication.pdfDocument.saveDocument();
            return btoa(Array.from(bytes, x=>String.fromCharCode(x)).join(''));
            """, arguments: [:], in: nil, contentWorld: .page)
        guard let encoded = result as? String, let data = Data(base64Encoded: encoded),
              let edited = PDFDocument(data: data), edited.pageCount == 1,
              edited.page(at: 0)?.annotations.contains(where: { $0.widgetStringValue == "Edited locally" }) == true,
              try Data(contentsOf: source) == original else {
            throw OpenTangerineError.invalidInput("Saved PDF field or original preservation failed.")
        }
        print("PASS bundled PDF.js: local transport isolation, form render, edit, saved copy and unchanged original")
    }
}
