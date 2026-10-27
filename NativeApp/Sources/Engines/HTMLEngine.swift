import AppKit
import Foundation
import WebKit

struct HTMLOptions {
    var pageSize: HTMLPageSize = .regional
    var landscape = false
    var margins: HTMLMargins = .normal
    var printBackgrounds = true
    var viewportWidth = 1280
    var viewportHeight = 800
    var scale = 1
    var capture: HTMLCapture = .fullPage
    var allowsJavaScript = false
    var allowsRemoteContent = false
    var timeout: TimeInterval = 30
    var quality = 0.9

    /// Lossy WebP (VP8) stores dimensions in 14 bits, one pixel short of the other formats.
    static let maxScreenshotHeight = 16_383
    static let maxPDFPages = 500

    init() {}

    init(settings: AppSettings) {
        pageSize = settings.htmlPageSize
        landscape = settings.htmlLandscape
        margins = settings.htmlMargins
        printBackgrounds = settings.htmlPrintBackgrounds
        viewportWidth = settings.htmlViewportWidth
        scale = settings.htmlScale
        capture = settings.htmlCapture
        allowsJavaScript = settings.htmlAllowsJavaScript
        allowsRemoteContent = settings.htmlAllowsRemoteContent
        timeout = TimeInterval(settings.htmlTimeout)
        quality = settings.jpegQuality
    }

    /// Settings are free-form numbers; keep them inside ranges WebKit and the image limits can honor.
    var normalized: HTMLOptions {
        var copy = self
        copy.viewportWidth = min(max(viewportWidth, 320), 3840)
        copy.viewportHeight = min(max(viewportHeight, 240), 2160)
        copy.scale = min(max(scale, 1), 3)
        copy.timeout = min(max(timeout, 1), 300)
        copy.quality = min(max(quality, 0.1), 1)
        return copy
    }
}

enum HTMLSource {
    struct Document {
        let url: URL
        let data: Data
        let encoding: String
        var name: String { url.lastPathComponent }
        var directory: URL { url.deletingLastPathComponent() }
    }

    static func read(_ url: URL) throws -> Document {
        guard url.isFileURL else { throw OpenTangerineError.invalidInput("Only local files are accepted.") }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard let values, values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 100_000_000 else {
            throw OpenTangerineError.invalidInput("Use a regular HTML file smaller than 100 MB.")
        }
        guard let data = try? Data(contentsOf: url) else { throw OpenTangerineError.unreadable(url) }
        let content = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard content.contains(where: { ![0x09, 0x0A, 0x0C, 0x0D, 0x20].contains($0) }) else {
            throw OpenTangerineError.invalidInput("\(url.lastPathComponent) is empty. Add some HTML and retry.")
        }
        return Document(url: url, data: data, encoding: encodingName(data))
    }

    /// WebKit assumes Windows-1252 for local files without a declared charset, which garbles UTF-8 text.
    /// Honor a byte-order mark or <meta charset>, otherwise prefer UTF-8 when the bytes are valid UTF-8.
    static func encodingName(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return "UTF-8" }
        if data.starts(with: [0xFF, 0xFE]) { return "UTF-16LE" }
        if data.starts(with: [0xFE, 0xFF]) { return "UTF-16BE" }
        let head = String(decoding: data.prefix(4096).map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        let pattern = #"<meta[^>]*charset\s*=\s*["']?\s*([A-Za-z0-9._:-]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
           let range = Range(match.range(at: 1), in: head) {
            let declared = String(head[range])
            // The HTML standard treats a UTF-16 meta declaration in an ASCII-compatible file as UTF-8.
            return declared.lowercased().hasPrefix("utf-16") ? "UTF-8" : declared
        }
        return String(data: data, encoding: .utf8) != nil ? "UTF-8" : "windows-1252"
    }
}

/// Resumes a callback-based WebKit call exactly once: on its callback, at the render deadline, or on cancellation.
@MainActor
private final class Pending<T> {
    private var continuation: CheckedContinuation<T, Error>?

    var isWaiting: Bool { continuation != nil }

    func finish(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    static func run(until deadline: Date, timeout: Error, onTimeout: @escaping () -> Void = {}, _ start: (Pending<T>) -> Void) async throws -> T {
        let pending = Pending<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                start(pending)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0)) {
                    MainActor.assumeIsolated {
                        guard pending.isWaiting else { return }
                        onTimeout()
                        pending.finish(.failure(timeout))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }
}

/// NSPrintOperation does not retain its delegate, and after a timeout the page is torn down while the job may
/// still be running, so the delegate keeps itself and everything the job uses alive until WebKit calls back.
private final class PrintCompletion: NSObject {
    var completion: ((Bool) -> Void)?
    private var retained: [AnyObject] = []

    func hold(_ objects: AnyObject...) {
        retained = [self] + objects
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion?(success)
        completion = nil
        retained = []
    }
}

/// One off-screen WebKit page per conversion: dropped HTML is untrusted, so no cookies, caches or scripts carry over between files.
@MainActor
final class HTMLPage: NSObject, WKNavigationDelegate {
    private let document: HTMLSource.Document
    private let options: HTMLOptions
    private let deadline: Date
    private let window: NSWindow
    private let webView: WKWebView
    private var navigation: Pending<Void>?
    private var expectedURL: URL?

    private var timeoutError: OpenTangerineError {
        .invalidInput("\(document.name) took longer than \(Int(options.timeout)) seconds to render. Simplify the page or raise the HTML timeout in Settings → Formats.")
    }

    static func withPage<T>(_ document: HTMLSource.Document, options: HTMLOptions, _ body: (HTMLPage) async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(options.timeout)
        let rules = try await ruleList(for: document.directory, allowsRemoteContent: options.allowsRemoteContent)
        let page = HTMLPage(document: document, options: options, rules: rules, deadline: deadline)
        defer { page.close() }
        try await page.load()
        return try await body(page)
    }

    private init(document: HTMLSource.Document, options: HTMLOptions, rules: WKContentRuleList, deadline: Date) {
        self.document = document
        self.options = options
        self.deadline = deadline
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = options.allowsJavaScript
        configuration.preferences.shouldPrintBackgrounds = options.printBackgrounds
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        let frame = CGRect(x: 0, y: 0, width: options.viewportWidth, height: options.viewportHeight)
        window = NSWindow(contentRect: frame.offsetBy(dx: -30_000, dy: -30_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
    }

    private func close() {
        navigation?.finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }

    // MARK: Loading

    private func load() async throws {
        DiagnosticLog.log("html load \(document.name) encoding=\(document.encoding) js=\(options.allowsJavaScript) remote=\(options.allowsRemoteContent)")
        // Loading raw bytes (needed to choose the encoding) gives WebKit no file access. Navigating to the folder
        // itself first grants read access to that folder only; it renders a blank page and runs no page code.
        try? await navigate(to: document.directory) { [document] in $0.loadFileURL(document.directory, allowingReadAccessTo: document.directory) }
        try await navigate(to: document.url) { [document] in
            $0.load(document.data, mimeType: "text/html", characterEncodingName: document.encoding, baseURL: document.url)
        }
        try await settle()
    }

    private func navigate(to url: URL, _ start: (WKWebView) -> WKNavigation?) async throws {
        defer {
            navigation = nil
            expectedURL = nil
        }
        try await Pending<Void>.run(until: deadline, timeout: timeoutError, onTimeout: { [webView] in webView.stopLoading() }) { pending in
            navigation = pending
            expectedURL = url
            _ = start(webView)
        }
    }

    /// Waits for web fonts and for lazy images that a full-page resize just brought into view.
    /// The load event already covered ordinary images; images and fonts still pending were usually blocked by the
    /// content rules, which never report back, so they get a short grace period instead of the whole timeout.
    private func settle() async throws {
        _ = try await evaluate("""
            for (const image of document.querySelectorAll('img[loading="lazy"]')) image.loading = 'eager';
            const images = Array.from(document.images).filter(image => !image.complete).map(image => new Promise(resolve => {
                image.addEventListener('load', resolve, { once: true });
                image.addEventListener('error', resolve, { once: true });
            }));
            // document.fonts.ready never settles after a cancelled navigation (such as a blocked script redirect), so poll the status.
            const fonts = (async () => { while (document.fonts.status === 'loading') await new Promise(resolve => setTimeout(resolve, 50)); })();
            await Promise.race([Promise.all([fonts, ...images]), new Promise(resolve => setTimeout(resolve, 3000))]);
            return true;
            """)
    }

    /// Runs in Open Tangerine's own script world, so it works even when the page's JavaScript is disabled.
    private func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await Pending<Any>.run(until: deadline, timeout: timeoutError) { pending in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [document] result in
                pending.finish(result.mapError { OpenTangerineError.invalidInput("Could not render \(document.name): \($0.localizedDescription)") })
            }
        }
    }

    private func contentHeight() async throws -> Int {
        let value = try await evaluate("return Math.ceil(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0));")
        return max((value as? NSNumber)?.intValue ?? options.viewportHeight, 1)
    }

    private func resize(width: Int, height: Int) {
        window.setContentSize(CGSize(width: width, height: height))
        webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.finish(.failure(OpenTangerineError.invalidInput("Could not load \(document.name): \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.finish(.failure(OpenTangerineError.invalidInput("Could not load \(document.name): \(error.localizedDescription)")))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagnosticLog.log("html web content process terminated for \(document.name)")
        navigation?.finish(.failure(OpenTangerineError.invalidInput("\(document.name) stopped rendering, usually because the page is too large. Simplify it and retry.")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the loads Open Tangerine starts may replace the main frame; script redirects, refreshes and pop-ups
        // are ignored. Frames are allowed through so the content rules decide what they may load.
        guard let frame = navigationAction.targetFrame else { return decisionHandler(.cancel) }
        guard frame.isMainFrame else { return decisionHandler(.allow) }
        let requested = navigationAction.request.url?.standardizedFileURL.absoluteString
        if requested != nil, requested == expectedURL?.standardizedFileURL.absoluteString { return decisionHandler(.allow) }
        DiagnosticLog.log("html blocked navigation to \(navigationAction.request.url?.absoluteString ?? "unknown URL")")
        decisionHandler(.cancel)
    }

    // MARK: Network rules

    /// Content-rule regexes have no alternation, so each pattern is its own rule. Hosts may end in a dot (`localhost.`),
    /// and a name without any dot (`router`, a decimal IP) can only resolve through the local network.
    private static let privateHosts = [
        "[^/:.]+\\.?[:/]", "[^/:]*\\.localhost\\.?[:/]", "[^/:]*\\.local\\.?[:/]", "[^/:]*\\.internal\\.?[:/]",
        "[^/:]*\\.lan\\.?[:/]", "[^/:]*\\.home\\.arpa\\.?[:/]", "[^/]*@",
        "127\\.", "10\\.", "0\\.", "192\\.168\\.", "169\\.254\\.", "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[0-1]\\.",
        "100\\.6[4-9]\\.", "100\\.[7-9][0-9]\\.", "100\\.1[01][0-9]\\.", "100\\.12[0-7]\\.", "\\[",
    ]

    /// Local files may load only from the HTML file's own folder. Remote content loads unless turned off,
    /// but loopback, link-local and private-network addresses written in the URL stay blocked.
    private static func ruleList(for directory: URL, allowsRemoteContent: Bool) async throws -> WKContentRuleList {
        func escaped(_ text: String) -> String {
            text.map { ".*+?^$()[]{}|\\".contains($0) ? "\\\($0)" : String($0) }.joined()
        }
        var rules: [[String: Any]] = []
        func add(_ filter: String, _ action: String) {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": action]])
        }
        add(allowsRemoteContent ? "^file:" : ".*", "block")
        add("^" + escaped(directory.standardizedFileURL.absoluteString), "ignore-previous-rules")
        for scheme in ["^data:", "^blob:", "^about:"] { add(scheme, "ignore-previous-rules") }
        if allowsRemoteContent {
            for host in privateHosts { add("^[a-z][a-z0-9+.-]*://" + host, "block") }
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        do {
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "OpenTangerineHTML", encodedContentRuleList: encoded) else {
                throw OpenTangerineError.invalidInput("Could not prepare safe HTML rendering.")
            }
            return list
        } catch let error as OpenTangerineError {
            throw error
        } catch {
            throw OpenTangerineError.invalidInput("Could not prepare safe HTML rendering: \(error.localizedDescription)")
        }
    }

    // MARK: Output

    func snapshot() async throws -> CGImage {
        let width = options.viewportWidth
        var height = options.viewportHeight
        for _ in 0..<2 {
            if options.capture == .fullPage { height = try await contentHeight() }
            try checkScreenshotSize(width: width, height: height)
            resize(width: width, height: options.capture == .fullPage ? height : options.viewportHeight)
            try await settle()
            // A taller viewport can change layout (vh units, lazy content); measure again once.
            if options.capture == .viewport { break }
            let measured = try await contentHeight()
            if measured == height { break }
        }
        let pixelWidth = width * options.scale
        let pixelHeight = height * options.scale
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.snapshotWidth = NSNumber(value: Double(pixelWidth) / Double(max(window.backingScaleFactor, 1)))
        configuration.afterScreenUpdates = true
        let image = try await Pending<NSImage>.run(until: deadline, timeout: timeoutError) { pending in
            webView.takeSnapshot(with: configuration) { [document] image, error in
                if let image { pending.finish(.success(image)) }
                else {
                    let reason = error?.localizedDescription ?? "no image was produced"
                    pending.finish(.failure(OpenTangerineError.invalidInput("Could not capture \(document.name): \(reason).")))
                }
            }
        }
        guard let rendered = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OpenTangerineError.encodeFailed("the page image")
        }
        DiagnosticLog.log("html snapshot \(rendered.width)x\(rendered.height), wanted \(pixelWidth)x\(pixelHeight)")
        if rendered.width == pixelWidth, rendered.height == pixelHeight { return rendered }
        return ImageIOBridge.scaled(rendered, to: CGSize(width: pixelWidth, height: pixelHeight))
    }

    private func checkScreenshotSize(width: Int, height: Int) throws {
        let pixelWidth = width * options.scale
        let pixelHeight = height * options.scale
        guard pixelHeight <= HTMLOptions.maxScreenshotHeight, Double(pixelWidth) * Double(pixelHeight) <= 40_000_000 else {
            throw OpenTangerineError.invalidInput("\(document.name) renders to \(pixelWidth) × \(pixelHeight) pixels; page images are limited to \(HTMLOptions.maxScreenshotHeight.formatted()) pixels tall and 40 megapixels. Lower the HTML scale, capture the visible area only, or convert to PDF.")
        }
    }

    func writePDF(to destination: URL) async throws {
        // The print operation keeps the view's current media type, so switch to print styles explicitly.
        webView.mediaType = "print"
        let paper = options.pageSize.points
        let page = try await cssPageRule()
        var size = page.size ?? (options.landscape ? CGSize(width: paper.height, height: paper.width) : paper)
        if page.size == nil, let orientation = page.orientation {
            let long = max(size.width, size.height), short = min(size.width, size.height)
            size = orientation == .landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        }
        let margin = options.margins.points
        let margins = (top: page.margins[0] ?? margin, right: page.margins[1] ?? margin, bottom: page.margins[2] ?? margin, left: page.margins[3] ?? margin)
        guard size.width - margins.left - margins.right >= 72, size.height - margins.top - margins.bottom >= 72 else {
            throw OpenTangerineError.invalidInput("The page size and margins in \(document.name) leave less than an inch to print on. Adjust its @page rule or the HTML margins in Settings → Formats.")
        }
        DiagnosticLog.log("html pdf paper \(size) margins \(margins) css=\(page)")
        // WebKit prints 96 CSS pixels per 72 points; lay out at the printable width to estimate the page count.
        let cssWidth = Int(((size.width - margins.left - margins.right) * 96 / 72).rounded())
        let cssPageHeight = Double(size.height - margins.top - margins.bottom) * 96 / 72
        resize(width: cssWidth, height: options.viewportHeight)
        try await settle()
        let estimatedPages = Int((Double(try await contentHeight()) / cssPageHeight).rounded(.up))
        guard estimatedPages <= HTMLOptions.maxPDFPages else {
            throw OpenTangerineError.invalidInput("\(document.name) would print to about \(estimatedPages) pages; the limit is \(HTMLOptions.maxPDFPages). Split the page into smaller files and retry.")
        }
        let info = NSPrintInfo(dictionary: [:])
        // NSPrintInfo swaps paperSize to match orientation, so derive it from the final paper.
        info.orientation = size.width > size.height ? .landscape : .portrait
        info.paperSize = size
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // Print into a private folder: after a timeout WebKit may still finish writing, and that late file must not land beside the user's output.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-htmlpdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let printed = staging.appendingPathComponent("page.pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = printed
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let completion = PrintCompletion()
        completion.hold(operation, webView, window)
        // Synchronous NSPrintOperation.run() never finishes for WKWebView; the modal variant completes asynchronously.
        let succeeded = try await Pending<Bool>.run(until: deadline, timeout: timeoutError) { pending in
            completion.completion = { pending.finish(.success($0)) }
            operation.runModal(for: window, delegate: completion, didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard succeeded, FileManager.default.fileExists(atPath: printed.path) else {
            throw OpenTangerineError.encodeFailed(destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: printed, to: destination)
    }

    struct PageRule: CustomStringConvertible {
        var size: CGSize?
        var orientation: NSPrintInfo.PaperOrientation?
        var margins: [CGFloat?] = [nil, nil, nil, nil]
        var description: String { "size=\(size.map { "\($0)" } ?? "-") orientation=\(orientation.map { "\($0.rawValue)" } ?? "-") margins=\(margins)" }
    }

    /// WebKit's print operation ignores CSS @page size and margins, so read the page's own @page rules
    /// (the last declaration wins, as in browsers) and apply them to the print settings.
    /// Linked stylesheets count as cross-origin for file pages; sheets inside the HTML file's folder are read here and parsed in place.
    private func cssPageRule() async throws -> PageRule {
        let blocked = try await evaluate("""
            return Array.from(document.styleSheets).filter(sheet => { try { sheet.cssRules; return false; } catch (error) { return Boolean(sheet.href); } }).map(sheet => sheet.href);
            """) as? [String] ?? []
        let folder = document.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var texts: [String: String] = [:]
        for href in blocked.prefix(50) {
            guard let url = URL(string: href), url.isFileURL else { continue }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(folder), ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) <= 2_000_000,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            texts[href] = text
        }
        let found = try await evaluate("""
            const result = {};
            const visit = rules => {
                for (const rule of rules) {
                    if (rule.type === CSSRule.PAGE_RULE) {
                        if (rule.selectorText) continue;
                        const size = rule.style.getPropertyValue('size');
                        if (size) result.size = size;
                        for (const side of ['top', 'right', 'bottom', 'left']) {
                            const value = rule.style.getPropertyValue('margin-' + side);
                            if (value) result[side] = value;
                        }
                    } else if (rule.type === CSSRule.MEDIA_RULE) {
                        if (matchMedia(rule.media.mediaText).matches) visit(rule.cssRules);
                    } else if (rule.type === CSSRule.IMPORT_RULE) {
                        try { visit(rule.styleSheet.cssRules); } catch (error) {}
                    } else if (rule.cssRules) {
                        visit(rule.cssRules);
                    }
                }
            };
            for (const sheet of document.styleSheets) {
                if (sheet.media.mediaText && !matchMedia(sheet.media.mediaText).matches) continue;
                try {
                    visit(sheet.cssRules);
                } catch (error) {
                    const text = texts[sheet.href];
                    if (!text) continue;
                    const parsed = new CSSStyleSheet();
                    parsed.replaceSync(text);
                    visit(parsed.cssRules);
                }
            }
            return JSON.stringify(result);
            """, arguments: ["texts": texts]) as? String
        let values = (found.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: String]) ?? [:]
        var rule = PageRule()
        if let size = values["size"] { (rule.size, rule.orientation) = Self.pageSize(size) }
        for (index, side) in ["top", "right", "bottom", "left"].enumerated() {
            rule.margins[index] = values[side].flatMap(Self.points)
        }
        return rule
    }

    static func pageSize(_ value: String) -> (CGSize?, NSPrintInfo.PaperOrientation?) {
        let named: [String: CGSize] = [
            "a3": CGSize(width: 841.89, height: 1190.55), "a4": CGSize(width: 595.28, height: 841.89), "a5": CGSize(width: 419.53, height: 595.28),
            "b4": CGSize(width: 708.66, height: 1000.63), "b5": CGSize(width: 498.9, height: 708.66),
            "letter": CGSize(width: 612, height: 792), "legal": CGSize(width: 612, height: 1008), "ledger": CGSize(width: 792, height: 1224),
        ]
        var size: CGSize?
        var orientation: NSPrintInfo.PaperOrientation?
        var lengths: [CGFloat] = []
        for token in value.lowercased().split(separator: " ").map(String.init) {
            if token == "landscape" { orientation = .landscape }
            else if token == "portrait" { orientation = .portrait }
            else if let paper = named[token] { size = paper }
            else if let length = points(token), length > 0 { lengths.append(length) }
        }
        if lengths.count == 1 { size = CGSize(width: lengths[0], height: lengths[0]) }
        if lengths.count >= 2 { size = CGSize(width: lengths[0], height: lengths[1]) }
        guard var resolved = size else { return (nil, orientation) }
        if let orientation {
            let long = max(resolved.width, resolved.height), short = min(resolved.width, resolved.height)
            resolved = orientation == .landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        }
        // Ignore sizes no printer or PDF viewer handles sensibly (under an inch or over 200 inches).
        guard (72...14_400).contains(resolved.width), (72...14_400).contains(resolved.height) else { return (nil, orientation) }
        return (resolved, orientation)
    }

    static func points(_ value: String) -> CGFloat? {
        let units: [(String, CGFloat)] = [("px", 0.75), ("pt", 1), ("pc", 12), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("q", 72 / 101.6)]
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let number = Double(text), number == 0 { return 0 }
        for (unit, scale) in units where text.hasSuffix(unit) {
            guard let number = Double(text.dropLast(unit.count)), number >= 0, number < 100_000 else { return nil }
            return CGFloat(number) * scale
        }
        return nil
    }

    /// Reads the rendered DOM into Word blocks. Only structure carries over; CSS layout does not.
    func documentBlocks(imagesIn directory: URL) async throws -> [DocxWriter.Block] {
        guard let json = try await evaluate(Self.extractionScript) as? String,
              let extracted = try? JSONDecoder().decode(Extracted.self, from: Data(json.utf8)) else {
            throw OpenTangerineError.invalidInput("Could not read the structure of \(document.name).")
        }
        if extracted.truncated { DiagnosticLog.log("html docx extraction truncated at \(extracted.blocks.count) blocks") }
        var blocks: [DocxWriter.Block] = []
        var imageCount = 0
        for item in extracted.blocks {
            switch item.type {
            case "text":
                let runs = (item.runs ?? []).map(Self.run)
                guard !runs.isEmpty else { continue }
                blocks.append(.text(runs, style(item)))
            case "image":
                imageCount += 1
                if let source = item.src, let file = localImage(source, index: imageCount, in: directory) {
                    if let width = item.width, let height = item.height, width > 0, height > 0 {
                        blocks.append(.sizedImage(file, CGSize(width: width, height: height)))
                    } else {
                        blocks.append(.image(file))
                    }
                } else if let alt = item.alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
                    blocks.append(.text([DocxWriter.Run(text: alt, italic: true)], .body))
                }
            case "table":
                let rows = (item.rows ?? []).map { row in
                    row.map { DocxWriter.Cell(runs: $0.runs.map(Self.run), header: $0.header, span: $0.span) }
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
            case "pageBreak":
                if !blocks.isEmpty { blocks.append(.pageBreak) }
            default:
                continue
            }
        }
        guard !blocks.isEmpty else {
            throw OpenTangerineError.invalidInput("\(document.name) has no text or images to put in a Word document. If the page builds its content with JavaScript, allow JavaScript for HTML in Settings → Formats.")
        }
        return blocks
    }

    private func style(_ item: Extracted.Item) -> DocxWriter.Style {
        switch item.style {
        case "heading": return .heading(item.level ?? 1)
        case "quote": return .quote
        case "code": return .code
        case "listItem": return .listItem(ordered: item.ordered ?? false, level: item.level ?? 0, list: item.list ?? 0)
        default: return .body
        }
    }

    private static func run(_ item: Extracted.Run) -> DocxWriter.Run {
        var link: URL?
        if let href = item.href, let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { link = url }
        return DocxWriter.Run(text: item.t, bold: item.b ?? false, italic: item.i ?? false, underline: item.u ?? false,
                              strike: item.s ?? false, monospace: item.m ?? false, link: link)
    }

    /// Embeds images from the HTML file's folder or data: URLs. Remote images are left out (their alt text is kept).
    private func localImage(_ source: String, index: Int, in directory: URL) -> URL? {
        guard let url = URL(string: source) else { return nil }
        let fm = FileManager.default
        var file: URL
        if url.isFileURL {
            let folder = document.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            file = url.standardizedFileURL.resolvingSymlinksInPath()
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            guard file.path.hasPrefix(folder), size <= 100_000_000 else { return nil }
        } else if url.scheme?.lowercased() == "data", let comma = source.firstIndex(of: ",") {
            let header = source[..<comma].lowercased()
            let payload = String(source[source.index(after: comma)...])
            guard header.hasSuffix(";base64"), payload.count <= 30_000_000,
                  let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
            let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/svg+xml": "svg", "image/webp": "webp"]
            let type = types.first { header.hasPrefix("data:" + $0.key) }?.value ?? "bin"
            file = directory.appendingPathComponent("embedded\(index).\(type)")
            guard (try? data.write(to: file)) != nil else { return nil }
        } else {
            return nil
        }
        // Word reliably shows PNG, JPEG and GIF; everything else (SVG, WebP, AVIF…) is re-encoded as PNG.
        if ["png", "jpg", "jpeg", "gif"].contains(file.pathExtension.lowercased()) {
            let copy = directory.appendingPathComponent("image\(index).\(file.pathExtension.lowercased())")
            return (try? fm.copyItem(at: file, to: copy)) != nil ? copy : nil
        }
        guard let image = try? ImageIOBridge.load(file, maxPixelSize: 4096) else { return nil }
        let png = directory.appendingPathComponent("image\(index).png")
        return (try? ImageIOBridge.write(image, to: png, format: .png)) != nil ? png : nil
    }

    private struct Extracted: Decodable {
        struct Run: Decodable { let t: String; let b, i, u, s, m: Bool?; let href: String? }
        struct Cell: Decodable { let runs: [Run]; let header: Bool; let span: Int }
        struct Item: Decodable {
            let type: String
            let style: String?
            let level: Int?
            let ordered: Bool?
            let list: Int?
            let runs: [Run]?
            let src: String?
            let alt: String?
            let width: Double?
            let height: Double?
            let rows: [[Cell]]?
        }
        let blocks: [Item]
        let truncated: Bool
    }

    private static let extractionScript = #"""
        const BLOCK_TAGS = new Set(['ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'BODY', 'CAPTION', 'CENTER', 'DD', 'DETAILS', 'DIALOG', 'DIV', 'DL', 'DT', 'FIELDSET', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'HGROUP', 'LEGEND', 'MAIN', 'NAV', 'P', 'PRE', 'SECTION', 'SUMMARY']);
        const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'TEMPLATE', 'HEAD', 'TITLE', 'META', 'LINK', 'svg', 'SVG', 'CANVAS', 'IFRAME', 'OBJECT', 'EMBED', 'AUDIO', 'VIDEO', 'BUTTON', 'SELECT', 'TEXTAREA', 'INPUT', 'MAP']);
        const MONO_TAGS = new Set(['CODE', 'KBD', 'SAMP', 'TT', 'PRE']);
        const LIMIT = 20000;
        const blocks = [];
        let runs = [];
        let style = { style: 'body' };
        let sink = null;
        let listCount = 0;
        let listDepth = 0;
        let truncated = false;

        const hidden = element => {
            const computed = getComputedStyle(element);
            return computed.display === 'none' || computed.visibility === 'hidden' || computed.visibility === 'collapse';
        };
        const format = (element, inherited) => {
            const computed = getComputedStyle(element);
            const decoration = computed.textDecorationLine || '';
            const tag = element.tagName.toUpperCase();
            const link = tag === 'A' && element.href ? element.href : inherited.href;
            return {
                b: parseInt(computed.fontWeight, 10) >= 600,
                i: computed.fontStyle === 'italic' || computed.fontStyle.startsWith('oblique'),
                u: !link && (inherited.u || decoration.includes('underline')),
                s: inherited.s || decoration.includes('line-through'),
                m: inherited.m || MONO_TAGS.has(tag) || /mono|courier|menlo|consolas/i.test(computed.fontFamily),
                pre: computed.whiteSpace.startsWith('pre') || computed.whiteSpace === 'break-spaces',
                href: link,
            };
        };
        const push = (text, f) => {
            const run = { t: text };
            for (const key of ['b', 'i', 'u', 's', 'm']) if (f[key]) run[key] = true;
            if (f.href) run.href = f.href;
            const last = runs[runs.length - 1];
            if (last && ['b', 'i', 'u', 's', 'm', 'href'].every(key => last[key] === run[key])) last.t += text;
            else runs.push(run);
        };
        const flush = () => {
            const collected = runs;
            runs = [];
            if (!collected.some(run => run.t.trim())) return;
            if (style.style !== 'code') {
                collected[0].t = collected[0].t.replace(/^[ \n]+/, '');
                const last = collected[collected.length - 1];
                last.t = last.t.replace(/[ \n]+$/, '');
            }
            const kept = collected.filter(run => run.t.length);
            if (sink) {
                if (sink.length) sink.push({ t: '\n' });
                sink.push(...kept);
            } else if (blocks.length < LIMIT) {
                blocks.push({ type: 'text', ...style, runs: kept });
            } else {
                truncated = true;
            }
        };
        const children = (element, f) => { for (const child of element.childNodes) walk(child, f); };
        const table = (element, f) => {
            const rows = [];
            for (const row of element.rows) {
                if (hidden(row)) continue;
                const cells = [];
                for (const cell of row.cells) {
                    if (hidden(cell)) continue;
                    const saved = sink;
                    sink = [];
                    children(cell, format(cell, f));
                    flush();
                    cells.push({ runs: sink, header: cell.tagName.toUpperCase() === 'TH', span: Math.max(1, Math.min(cell.colSpan || 1, 63)) });
                    sink = saved;
                }
                if (cells.length) rows.push(cells);
            }
            if (rows.length && blocks.length < LIMIT) blocks.push({ type: 'table', rows });
        };
        const list = (element, f) => {
            flush();
            const ordered = element.tagName.toUpperCase() === 'OL';
            const id = ++listCount;
            const saved = style;
            listDepth += 1;
            for (const child of element.childNodes) {
                if (child.nodeType === Node.ELEMENT_NODE && child.tagName.toUpperCase() === 'LI') {
                    if (hidden(child)) continue;
                    style = { style: 'listItem', ordered, level: Math.min(listDepth - 1, 8), list: id };
                    children(child, format(child, f));
                    flush();
                } else {
                    walk(child, f);
                }
            }
            listDepth -= 1;
            style = saved;
        };
        function walk(node, f) {
            if (truncated) return;
            if (node.nodeType === Node.TEXT_NODE) {
                let text = node.data;
                if (!f.pre) {
                    text = text.replace(/[\t\n\r\f ]+/g, ' ');
                    const previous = runs[runs.length - 1];
                    if (text.startsWith(' ') && (!previous || /[ \n]$/.test(previous.t))) text = text.slice(1);
                }
                if (text) push(text, f);
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            const element = node;
            const tag = element.tagName.toUpperCase();
            if (SKIP_TAGS.has(tag) || SKIP_TAGS.has(element.tagName) || hidden(element)) return;
            if (tag === 'BR') { push('\n', f); return; }
            if (tag === 'IMG') {
                if (sink) { if (element.alt) push(element.alt, f); return; }
                flush();
                if (blocks.length < LIMIT) blocks.push({ type: 'image', src: element.currentSrc || element.src, alt: element.alt || '', width: element.width, height: element.height });
                return;
            }
            if (tag === 'TABLE' && !sink) { flush(); table(element, f); return; }
            if ((tag === 'UL' || tag === 'OL') && !sink) { list(element, f); return; }
            const computed = getComputedStyle(element);
            const next = format(element, f);
            const isBlock = BLOCK_TAGS.has(tag) || ['block', 'flex', 'grid', 'list-item', 'table', 'table-row', 'flow-root'].includes(computed.display);
            if (!isBlock) { children(element, next); return; }
            flush();
            if (!sink && (computed.breakBefore === 'page' || computed.pageBreakBefore === 'always')) blocks.push({ type: 'pageBreak' });
            const saved = style;
            if (/^H[1-6]$/.test(tag)) style = { style: 'heading', level: Number(tag[1]) };
            else if (tag === 'BLOCKQUOTE') style = { style: 'quote' };
            else if (tag === 'PRE') style = { style: 'code' };
            children(element, next);
            flush();
            style = saved;
        }
        if (document.body) walk(document.body, { b: false, i: false, u: false, s: false, m: false, pre: false, href: null });
        flush();
        return JSON.stringify({ blocks, truncated });
        """#
}

struct HTMLEngine: ConversionEngine {
    /// Tests pass explicit options; the app uses Settings → Formats.
    var options: HTMLOptions?

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from == .html && [.pdf, .docx, .png, .jpg, .webp].contains(to)
    }

    func convert(_ request: ConversionRequest) async throws {
        let document = try HTMLSource.read(request.source)
        let options = (self.options ?? HTMLOptions(settings: AppSettings.shared)).normalized
        request.progress(0.1)
        switch request.target {
        case .pdf:
            try await HTMLPage.withPage(document, options: options) { try await $0.writePDF(to: request.destination) }
        case .png, .jpg, .webp:
            let image = try await HTMLPage.withPage(document, options: options) { try await $0.snapshot() }
            request.progress(0.7)
            try await ImageIOBridge.writeAnyFormat(image, to: request.destination, format: request.target, quality: options.quality)
        case .docx:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-htmldocx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let blocks = try await HTMLPage.withPage(document, options: options) { try await $0.documentBlocks(imagesIn: temp) }
            request.progress(0.7)
            try await DocxWriter.write(blocks: blocks, to: request.destination)
        default:
            throw OpenTangerineError.unsupportedConversion(.html, request.target)
        }
        request.progress(1)
    }
}
