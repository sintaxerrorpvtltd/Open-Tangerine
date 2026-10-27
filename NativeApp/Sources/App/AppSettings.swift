import AppKit
import Foundation
import Combine
import ServiceManagement

enum CompressionPreset: String, CaseIterable, Identifiable {
    case balanced
    case strong

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var imageQuality: Double { self == .balanced ? 0.72 : 0.5 }
    var videoScale: Double { self == .balanced ? 1.0 : 0.75 }
    var videoBitrateFactor: Double { self == .balanced ? 0.6 : 0.35 }
    var audioBitrate: Int { self == .balanced ? 128_000 : 64_000 }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal
    case downloads
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: return "Next to the original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        }
    }

    func directory(for source: URL) -> URL {
        switch self {
        case .besideOriginal: return source.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case card
    case pill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: return "Card"
        case .pill: return "Notch pill"
        }
    }
}

enum NotchSurface: String, CaseIterable, Identifiable {
    case black, glass
    var id: String { rawValue }
    var title: String { self == .black ? "Pure black" : "Glass" }
}

enum HTMLPageSize: String, CaseIterable, Identifiable {
    case a4
    case letter

    var id: String { rawValue }

    var title: String { self == .a4 ? "A4" : "Letter" }

    var points: CGSize { self == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792) }

    static var regional: HTMLPageSize { Locale.current.measurementSystem == .us ? .letter : .a4 }
}

enum HTMLMargins: String, CaseIterable, Identifiable {
    case none
    case narrow
    case normal

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .none: return 0
        case .narrow: return 18
        case .normal: return 36
        }
    }
}

enum HTMLCapture: String, CaseIterable, Identifiable {
    case fullPage
    case viewport

    var id: String { rawValue }

    var title: String { self == .fullPage ? "Full page" : "Visible area" }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var excludedApplications: [String: String] {
        didSet { defaults.set(excludedApplications, forKey: "excludedApplications") }
    }

    @Published var compressionPreset: CompressionPreset {
        didSet { defaults.set(compressionPreset.rawValue, forKey: "compressionPreset") }
    }

    @Published var compressionResizeLongEdge: Int {
        didSet { defaults.set(compressionResizeLongEdge, forKey: "compressionResizeLongEdge") }
    }

    @Published var outputLocation: OutputLocation {
        didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") }
    }

    @Published var revealInFinder: Bool {
        didSet { defaults.set(revealInFinder, forKey: "revealInFinder") }
    }

    @Published var notchSurface: NotchSurface {
        didSet { defaults.set(notchSurface.rawValue, forKey: "notchSurface") }
    }

    @Published var progressStyle: ProgressStyle {
        didSet { defaults.set(progressStyle.rawValue, forKey: "progressStyle") }
    }

    @Published var ffmpegPath: String {
        didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") }
    }

    @Published var launchAtLogin: Bool {
        didSet { if !refreshingLoginStatus { applyLaunchAtLogin() } }
    }

    @Published var loginMessage: String?
    private var refreshingLoginStatus = false

    @Published var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: "jpegQuality") }
    }

    @Published var htmlPageSize: HTMLPageSize {
        didSet { defaults.set(htmlPageSize.rawValue, forKey: "htmlPageSize") }
    }

    @Published var htmlLandscape: Bool {
        didSet { defaults.set(htmlLandscape, forKey: "htmlLandscape") }
    }

    @Published var htmlMargins: HTMLMargins {
        didSet { defaults.set(htmlMargins.rawValue, forKey: "htmlMargins") }
    }

    @Published var htmlPrintBackgrounds: Bool {
        didSet { defaults.set(htmlPrintBackgrounds, forKey: "htmlPrintBackgrounds") }
    }

    @Published var htmlViewportWidth: Int {
        didSet { defaults.set(htmlViewportWidth, forKey: "htmlViewportWidth") }
    }

    @Published var htmlScale: Int {
        didSet { defaults.set(htmlScale, forKey: "htmlScale") }
    }

    @Published var htmlCapture: HTMLCapture {
        didSet { defaults.set(htmlCapture.rawValue, forKey: "htmlCapture") }
    }

    @Published var htmlAllowsJavaScript: Bool {
        didSet { defaults.set(htmlAllowsJavaScript, forKey: "htmlAllowsJavaScript") }
    }

    @Published var htmlAllowsRemoteContent: Bool {
        didSet { defaults.set(htmlAllowsRemoteContent, forKey: "htmlAllowsRemoteContent") }
    }

    @Published var htmlTimeout: Int {
        didSet { defaults.set(htmlTimeout, forKey: "htmlTimeout") }
    }

    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    private init() {
        excludedApplications = defaults.dictionary(forKey: "excludedApplications") as? [String: String] ?? [:]
        compressionPreset = CompressionPreset(rawValue: defaults.string(forKey: "compressionPreset") ?? "") ?? .balanced
        compressionResizeLongEdge = defaults.integer(forKey: "compressionResizeLongEdge")
        outputLocation = OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .besideOriginal
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? true
        notchSurface = NotchSurface(rawValue: defaults.string(forKey: "notchSurface") ?? "") ?? .black
        progressStyle = ProgressStyle(rawValue: defaults.string(forKey: "progressStyle") ?? "") ?? .pill
        // One-time migration requested for existing trial installs; future user choices persist.
        if !defaults.bool(forKey: "notchDefaultV012") {
            progressStyle = .pill
            defaults.set("pill", forKey: "progressStyle")
            defaults.set(true, forKey: "notchDefaultV012")
        }
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        jpegQuality = defaults.object(forKey: "jpegQuality") as? Double ?? 0.9
        htmlPageSize = HTMLPageSize(rawValue: defaults.string(forKey: "htmlPageSize") ?? "") ?? .regional
        htmlLandscape = defaults.bool(forKey: "htmlLandscape")
        htmlMargins = HTMLMargins(rawValue: defaults.string(forKey: "htmlMargins") ?? "") ?? .normal
        htmlPrintBackgrounds = defaults.object(forKey: "htmlPrintBackgrounds") as? Bool ?? true
        htmlViewportWidth = defaults.object(forKey: "htmlViewportWidth") as? Int ?? 1280
        htmlScale = defaults.object(forKey: "htmlScale") as? Int ?? 1
        htmlCapture = HTMLCapture(rawValue: defaults.string(forKey: "htmlCapture") ?? "") ?? .fullPage
        // Dropped HTML is untrusted, so scripts stay off unless the user opts in. Remote images, styles and fonts are
        // also opt-in so conversion never contacts a server by default; private-network addresses stay blocked either way.
        htmlAllowsJavaScript = defaults.bool(forKey: "htmlAllowsJavaScript")
        htmlAllowsRemoteContent = defaults.bool(forKey: "htmlAllowsRemoteContent")
        htmlTimeout = defaults.object(forKey: "htmlTimeout") as? Int ?? 30
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
    }

    func refreshLoginStatus(preserveError: Bool = false) {
        refreshingLoginStatus = true
        defer { refreshingLoginStatus = false }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if !preserveError {
            loginMessage = status == .requiresApproval
                ? "Allow Open Tangerine in System Settings → General → Login Items."
                : nil
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            loginMessage = "Could not update automatic startup: \(error.localizedDescription)"
            refreshLoginStatus(preserveError: true)
        }
    }
}

