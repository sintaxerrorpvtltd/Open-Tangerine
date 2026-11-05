import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MergePDFToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @State private var thumbs: [URL: NSImage] = [:]
    @State private var pageCounts: [URL: Int] = [:]

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Merge", saveEnabled: files.count >= 2, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs, allowedTypes: [.pdf], addTitle: "Add PDFs…")
        } sidebar: {
            SidebarSection(title: "Summary") {
                Text("\(files.count) document\(files.count == 1 ? "" : "s") · \(files.reduce(0) { $0 + (pageCounts[$1] ?? 0) }) pages").font(.callout.monospacedDigit())
                Text("Documents are merged in list order, starting with the Finder selection order. Add another PDF to combine. A locked PDF stops the merge.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: files) {
            for url in files where thumbs[url] == nil {
                guard let doc = PDFDocument(url: url) else { continue }
                pageCounts[url] = doc.pageCount
                if let page = doc.page(at: 0) {
                    thumbs[url] = page.thumbnail(of: NSSize(width: 88, height: 88), for: .mediaBox)
                }
            }
        }
    }

    private func save() {
        let files = files
        let destination = session.outputURL(suffix: "merged", ext: "pdf")
        session.run(title: "Merging", detail: "\(files.count) PDFs") { _ in
            try PDFOps.merge(files, to: destination)
            return [destination]
        }
    }
}

@MainActor
struct SplitPDFToolView: View {
    let session: ToolSession
    @State private var mode: PDFOps.SplitMode = .everyPage
    @State private var every = 2
    @State private var ranges = ""
    @State private var pageCount = 0
    @State private var thumbnails: [NSImage] = []

    private var outputCount: Int {
        switch mode {
        case .everyPage: return pageCount
        case .everyN: return every > 0 ? Int(ceil(Double(pageCount) / Double(every))) : 0
        case .ranges: return PDFOps.parseRanges(ranges, pageCount: pageCount).count
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: "Split into \(outputCount) files", saveEnabled: outputCount > 0, onSave: save) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                        VStack(spacing: 4) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(height: 130)
                                .background(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(groupColor(for: index + 1), lineWidth: 2))
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        } sidebar: {
            SidebarSection(title: "Split") {
                Picker("", selection: $mode) {
                    ForEach(PDFOps.SplitMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                switch mode {
                case .everyPage:
                    EmptyView()
                case .everyN:
                    Stepper("Pages per file: \(every)", value: $every, in: 1...max(1, pageCount))
                case .ranges:
                    TextField("e.g. 1-3, 4, 5-8", text: $ranges).textFieldStyle(.roundedBorder)
                    Text("Comma-separated pages or ranges. Each entry becomes one file.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Summary") {
                Text("\(pageCount) pages → \(outputCount) file\(outputCount == 1 ? "" : "s")").font(.callout.monospacedDigit())
                Text("Output files are placed in one folder next to the original.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            guard let doc = PDFDocument(url: session.primary) else { return }
            pageCount = doc.pageCount
            ranges = "1-\(doc.pageCount)"
            thumbnails = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.thumbnail(of: NSSize(width: 220, height: 220), for: .mediaBox) }
        }
    }

    private func groupColor(for page: Int) -> Color {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal]
        let group: Int
        switch mode {
        case .everyPage: group = page - 1
        case .everyN: group = (page - 1) / max(1, every)
        case .ranges:
            guard let index = PDFOps.parseRanges(ranges, pageCount: pageCount).firstIndex(where: { $0.contains(page) }) else { return .clear }
            group = index
        }
        return palette[group % palette.count]
    }

    private func save() {
        let url = session.primary, mode = mode, every = every, ranges = ranges
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) pages")
        session.run(title: "Splitting", detail: "\(url.lastPathComponent)") { _ in
            try PDFOps.split(url, mode: mode, every: every, ranges: ranges, into: folder)
        }
    }
}

@MainActor
struct OrganizePDFToolView: View {
    let session: ToolSession
    @State private var pages: [PDFPageRef] = []
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var selected: Set<UUID> = []
    @State private var error: String?

    private var sources: [URL] { session.files }

    var body: some View {
        ToolShell(session: session, saveTitle: "Save copy", saveEnabled: !pages.isEmpty, onSave: save) {
            if let error {
                LoadingOrError(error: error)
            } else if pages.isEmpty {
                ProgressView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(index: index, page: page, image: thumbnails[key(page)], selected: selected.contains(page.id), sourceLabel: sources.count > 1 ? page.sourceURL.lastPathComponent : nil)
                                .onTapGesture { toggle(page.id) }
                                .contextMenu {
                                    Button("Rotate left") { rotate([page.id], by: -90) }
                                    Button("Rotate right") { rotate([page.id], by: 90) }
                                    Button("Duplicate") { duplicate([page.id]) }
                                    Divider()
                                    Button("Move to start") { move(page.id, to: 0) }
                                    Button("Move to end") { move(page.id, to: pages.count) }
                                    Divider()
                                    Button("Remove", role: .destructive) { remove([page.id]) }
                                }
                                .onDrag { NSItemProvider(object: page.id.uuidString as NSString) }
                                .onDrop(of: [.plainText], delegate: PageDropDelegate(target: page.id, pages: $pages))
                        }
                    }
                    .padding(16)
                }
            }
        } sidebar: {
            SidebarSection(title: "Selection") {
                Text(selected.isEmpty ? "Click pages to select. Drag to reorder." : "\(selected.count) selected").font(.callout)
                HStack {
                    Button("All") { selected = Set(pages.map(\.id)) }
                    Button("None") { selected.removeAll() }
                }
                .controlSize(.small)
            }
            SidebarSection(title: "Pages") {
                let targets = selected.isEmpty ? pages.map(\.id) : Array(selected)
                HStack {
                    Button { rotate(targets, by: -90) } label: { Label("Left", systemImage: "rotate.left") }
                    Button { rotate(targets, by: 90) } label: { Label("Right", systemImage: "rotate.right") }
                }
                Button("Duplicate") { duplicate(targets) }.disabled(selected.isEmpty)
                Button("Remove", role: .destructive) { remove(targets) }.disabled(selected.isEmpty || selected.count == pages.count)
                Button("Reverse order") { pages.reverse() }
            }
            SidebarSection(title: "Summary") {
                Text("\(pages.count) page\(pages.count == 1 ? "" : "s")").font(.callout.monospacedDigit())
                if sources.count > 1 {
                    Text("Pages from \(sources.count) documents are combined into one.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .task { load() }
        .onDeleteCommand { if !selected.isEmpty { remove(Array(selected)) } }
    }

    private func key(_ page: PDFPageRef) -> String { "\(page.sourceURL.path)#\(page.sourceIndex)" }

    private func load() {
        var refs: [PDFPageRef] = []
        for url in sources {
            guard let doc = PDFDocument(url: url) else { error = "Could not open \(url.lastPathComponent)."; return }
            if doc.isLocked { error = "\(url.lastPathComponent) is password protected."; return }
            for index in 0..<doc.pageCount {
                let ref = PDFPageRef(sourceIndex: index, rotation: doc.page(at: index)?.rotation ?? 0, sourceURL: url)
                refs.append(ref)
                if let page = doc.page(at: index) {
                    thumbnails[key(ref)] = page.thumbnail(of: NSSize(width: 260, height: 260), for: .mediaBox)
                }
            }
        }
        pages = refs
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = selected == [id] ? [] : [id]
        }
    }

    private func rotate(_ ids: [UUID], by degrees: Int) {
        for index in pages.indices where ids.contains(pages[index].id) {
            pages[index].rotation = ((pages[index].rotation + degrees) % 360 + 360) % 360
        }
    }

    private func duplicate(_ ids: [UUID]) {
        var result: [PDFPageRef] = []
        for page in pages {
            result.append(page)
            if ids.contains(page.id) {
                result.append(PDFPageRef(sourceIndex: page.sourceIndex, rotation: page.rotation, sourceURL: page.sourceURL))
            }
        }
        pages = result
    }

    private func remove(_ ids: [UUID]) {
        guard pages.count > ids.count else { return }
        pages.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
    }

    private func move(_ id: UUID, to index: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: min(index > from ? index - 1 : index, pages.count))
    }

    private func save() {
        let pages = pages
        let destination = session.outputURL(suffix: "organized", ext: "pdf")
        session.run(title: "Organizing", detail: "\(session.primary.lastPathComponent)") { _ in
            try PDFOps.assemble(pages: pages, to: destination)
            return [destination]
        }
    }
}

private struct PageCell: View {
    let index: Int
    let page: PDFPageRef
    let image: NSImage?
    let selected: Bool
    let sourceLabel: String?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(page.rotation)))
                        .padding(6)
                }
            }
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let sourceLabel {
                Text(sourceLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: UUID
    @Binding var pages: [PDFPageRef]

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard let from = pages.firstIndex(where: { $0.id == id }), let to = pages.firstIndex(where: { $0.id == target }), from != to else { return }
                let page = pages.remove(at: from)
                pages.insert(page, at: to)
            }
        }
        return true
    }
}

