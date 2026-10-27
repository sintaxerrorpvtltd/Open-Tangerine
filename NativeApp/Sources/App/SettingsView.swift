import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case conversion
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .conversion: return "Formats"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .conversion: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var model: SettingsTabModel
    @State private var ffmpegHealth: FFmpeg.Health = .missing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selection

    static let width: CGFloat = 820
    static let height: CGFloat = 620

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(nsImage: BrandArtwork.image(size: 40)).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open").font(.system(size: 15, weight: .medium))
                        Text("Tangerine").font(.system(size: 18, weight: .bold))
                    }
                }
                .padding(.top, 20)
                VStack(spacing: 6) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.85)) {
                                model.tab = tab
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tab.symbol).font(.system(size: 16, weight: .medium)).frame(width: 22)
                                Text(tab.title).font(.system(size: 14, weight: model.tab == tab ? .semibold : .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .foregroundStyle(model.tab == tab ? Color.white : Color.primary)
                            .background {
                                if model.tab == tab {
                                    RoundedRectangle(cornerRadius: 13)
                                        .fill(Theme.accent.gradient)
                                        .matchedGeometryEffect(id: "sidebar", in: selection)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(SettingsPressStyle())
                        .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label("On your Mac", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Your files. Your workflow.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("OPEN SOURCE  /  \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 12)
            }
            .padding(20).frame(width: 205)
            .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.65))
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MAKE ROOM FOR FLOW")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(2).foregroundStyle(Theme.accent)
                        Text(model.tab.title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text(tabDescription)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    FileOrbitGraphic(tab: model.tab)
                        .frame(width: 155, height: 145)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 4)
                ZStack {
                    Form {
                        switch model.tab {
                        case .general: general
                        case .appearance: appearance
                        case .conversion: conversion
                        case .about: about
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .id(model.tab)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 9)))
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28), value: model.tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LinearGradient(colors: [Theme.accent.opacity(0.06), Color(nsColor: .windowBackgroundColor), Color(nsColor: .windowBackgroundColor)], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .init("OpenTangerineShowAbout"))) { _ in model.tab = .about }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in settings.refreshLoginStatus() }
        .task(id: settings.ffmpegPath) { ffmpegHealth = await FFmpeg.checkHealth() }
    }

    private var tabDescription: String {
        switch model.tab {
        case .general: return "A few thoughtful defaults. A smoother day."
        case .appearance: return "Make your workspace feel like yours."
        case .conversion: return "Find the balance between detail and size."
        case .about: return "Small utility. Open possibilities."
        }
    }

    @ViewBuilder private var general: some View {
        Section("Output") {
            Picker("Save converted files", selection: $settings.outputLocation) {
                ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
        }
        Section("General") {
            Toggle("Start automatically at login", isOn: $settings.launchAtLogin)
            Text("Keep Open Tangerine ready in the menu bar after you restart and sign in. Move the app to Applications before enabling.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = settings.loginMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Open Login Items…") { settings.openLoginSettings() }
            }
        }
        Section {
            LabeledContent("Conversion wheel") {
                Label("Shift", systemImage: "shift").labelStyle(.titleAndIcon)
            }
            LabeledContent("Tools wheel") {
                Label("Command (or Option + Shift)", systemImage: "option").labelStyle(.titleAndIcon)
            }
            LabeledContent("File actions", value: "Control")
        } header: {
            Text("Drag Modifiers")
        } footer: {
            Text("Hold the modifier while dragging files in Finder.")
        }
        Section("Excluded applications") {
            Text("Drag shortcuts stay off when a drag starts in these apps. Add CorelDRAW or other design tools here. You can still use Convert Files from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(settings.excludedApplications.keys.sorted(), id: \.self) { identifier in
                HStack {
                    Text(settings.excludedApplications[identifier] ?? identifier)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        settings.excludedApplications.removeValue(forKey: identifier)
                    }.help("Enable drag shortcuts in this application")
                }
            }
            Button("Add Application…", systemImage: "plus.circle", action: addExcludedApplication)
        }
    }

    private func addExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = "Disable drag shortcuts in applications"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
                settings.excludedApplications[identifier] =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
            }
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Theme") {
            Picker("Theme", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Picker("Progress", selection: $settings.progressStyle) {
                ForEach(ProgressStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.progressStyle == .pill {
                Picker("Notch surface", selection: $settings.notchSurface) {
                    ForEach(NotchSurface.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
        } header: {
            Text("Progress")
        } footer: {
            Text(settings.progressStyle == .card
                 ? "A floating card in the top right corner with the file name and percentage."
                 : "An animated citrus companion below the notch, with file progress and results.")
        }
    }

    @ViewBuilder private var conversion: some View {
        Section("Images") {
            HStack {
                Text("JPEG / HEIC / WebP quality")
                Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                Text("\(Int(settings.jpegQuality * 100))%").contentTransition(.numericText()).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        Section {
            Picker("PDF page size", selection: $settings.htmlPageSize) {
                ForEach(HTMLPageSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Landscape", isOn: $settings.htmlLandscape)
            Picker("Margins", selection: $settings.htmlMargins) {
                ForEach(HTMLMargins.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Print background colors and images", isOn: $settings.htmlPrintBackgrounds)
            Picker("Page images", selection: $settings.htmlCapture) {
                ForEach(HTMLCapture.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Viewport width")
                TextField("1280", value: $settings.htmlViewportWidth, format: .number)
                    .labelsHidden()
                    .accessibilityLabel("Viewport width in pixels")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("px").foregroundStyle(.secondary)
            }
            Picker("Image scale", selection: $settings.htmlScale) {
                Text("1×").tag(1)
                Text("2×").tag(2)
                Text("3×").tag(3)
            }
            .pickerStyle(.segmented)
            Toggle("Run JavaScript", isOn: $settings.htmlAllowsJavaScript)
            Toggle("Load remote images, styles and fonts", isOn: $settings.htmlAllowsRemoteContent)
            HStack {
                Text("Give up after")
                TextField("30", value: $settings.htmlTimeout, format: .number)
                    .labelsHidden()
                    .accessibilityLabel("Give up after, in seconds")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("seconds").foregroundStyle(.secondary)
            }
        } header: {
            Text("HTML")
        } footer: {
            Text("PDF follows the page's own @page size and margins when it sets them. Page images use the quality above. Word documents keep headings, text styles, links, lists, tables and local images, not the page layout. Scripts stay off unless you turn them on, because HTML files can run code. Remote content is off by default, so conversion never contacts a server and remote images appear as empty boxes; turn it on to load them as Safari would.")
        }
        Section {
            Picker("Preset", selection: $settings.compressionPreset) {
                ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Resize long edge to")
                TextField("Off", value: $settings.compressionResizeLongEdge, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("px (0 = keep size)").foregroundStyle(.secondary)
            }
        } header: {
            Text("Compression")
        } footer: {
            Text(settings.compressionPreset == .balanced
                 ? "Balanced keeps detail while trimming size noticeably."
                 : "Strong prioritizes the smallest file, with visible quality loss.")
        }
        Section {
            HStack {
                TextField("Auto-detect (Homebrew, MacPorts, /usr/local/bin)", text: $settings.ffmpegPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseFFmpeg() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ffmpegHealthSymbol)
                    .foregroundStyle(ffmpegHealthColor)
                Text(ffmpegHealthText)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        } header: {
            Text("FFmpeg (optional)")
        } footer: {
            Text("Open Tangerine uses Apple frameworks for most work. FFmpeg fills the gaps: MP3, FLAC, OGG, Opus, WMA, MKV, WebM, AVI, WMV, GIF and AVIF/WebP encoding on older systems.")
        }
    }

    @ViewBuilder private var about: some View {
        Section {
            VStack(spacing: 16) {
                Image(nsImage: BrandArtwork.image(size: 100))
                    .resizable().frame(width: 84, height: 84)
                    .shadow(color: Theme.accent.opacity(0.18), radius: 12, y: 6)
                    .accessibilityLabel("Open Tangerine icon")
                VStack(spacing: 6) {
                    Text("Open Tangerine").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("A little less friction. A little more flow.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Text("VERSION \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")  ·  DEVELOPER TRIAL")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.1).foregroundStyle(.secondary)
                Divider().padding(.horizontal, 30)
                VStack(spacing: 7) {
                    Text("Sintax Error Private Limited").font(.system(size: 13, weight: .semibold))
                    Text("Free to use. Open to make better.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Text("Made with")
                    Image(systemName: "heart.fill").foregroundStyle(Theme.accent).accessibilityLabel("love")
                    Text("by")
                    Link("Hemaangg", destination: URL(string: "https://www.instagram.com/hemaangg/")!)
                        .fontWeight(.semibold)
                        .help("Visit Hemaangg on Instagram")
                }
                .font(.system(size: 13))
                .padding(.top, 2)
                Text("GPL-3.0-only · Based on Satsuma by plyght (MIT).\nIndependent of Tangerine. Some features remain experimental.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private var ffmpegHealthSymbol: String {
        switch ffmpegHealth {
        case .ready: return "checkmark.circle.fill"
        case .broken: return "xmark.octagon.fill"
        case .missing: return "exclamationmark.triangle.fill"
        }
    }

    private var ffmpegHealthColor: Color {
        switch ffmpegHealth {
        case .ready: return .green
        case .broken: return .red
        case .missing: return .orange
        }
    }

    private var ffmpegHealthText: String {
        switch ffmpegHealth {
        case let .ready(path, version): return "Using ffmpeg \(version) at \(path)"
        case let .broken(path, reason): return "ffmpeg at \(path) cannot run: \(reason)"
        case .missing: return "FFmpeg not found. Install with `brew install ffmpeg` or pick the binary."
        }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.ffmpegPath = url.path
        }
    }
}

struct SettingsTabBar: View {
    @ObservedObject var model: SettingsTabModel
    @Namespace private var namespace

    var body: some View {
        GlassGroup {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        model.tab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .labelStyle(.titleOnly)
                            .font(.system(size: 13, weight: model.tab == tab ? .semibold : .regular))
                            .foregroundStyle(model.tab == tab ? Color.white : Color.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if model.tab == tab {
                            Color.clear
                                .glassSurface(tint: Theme.accent, interactive: true, in: Capsule())
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                }
            }
            .padding(3)
            .glassSurface(in: Capsule())
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.tab)
    }
}

final class SettingsWindow: NSWindow {
    var toolbarDelegate: SettingsToolbarDelegate?
}

@MainActor
final class SettingsToolbarDelegate: NSObject, NSToolbarDelegate {
    static let tabsItem = NSToolbarItem.Identifier("opentangerine.settings.tabs")
    let model: SettingsTabModel

    init(model: SettingsTabModel) {
        self.model = model
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let hosting = NSHostingView(rootView: SettingsTabBar(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        item.view = hosting
        item.isBordered = false
        return item
    }
}

