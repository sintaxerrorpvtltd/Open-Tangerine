import AppKit
import SwiftUI

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
    case fileAction(FileAction)
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let symbol: String

    var id: RadialAction { action }

    init(fileAction: FileAction) {
        action = .fileAction(fileAction)
        label = fileAction.rawValue
        detail = fileAction.rawValue
        symbol = fileAction.symbol
    }

    init(format: FileFormat) {
        action = .convert(format)
        label = format.displayName
        detail = "Convert to \(format.displayName)"
        symbol = format.category.symbol
    }

    init(tool: ToolID) {
        action = .tool(tool)
        label = tool.radialLabel
        detail = tool.title
        symbol = tool.symbol
    }
}

struct RadialGeometry {
    var innerRadius: CGFloat = 64
    var outerRadius: CGFloat = 150
    var gap: CGFloat = 4
    var count: Int

    var slice: CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    var corner: CGFloat {
        let wanted: CGFloat = count > 8 ? 10 : 14
        let limit = (innerRadius * sin(slice * 0.34) - gap / 2) / (1 - sin(slice * 0.34))
        return max(4, min(wanted, limit))
    }

    var labelRadius: CGFloat { innerRadius + (outerRadius - innerRadius) * 0.56 }

    var labelWidth: CGFloat {
        let chord = 2 * labelRadius * sin(slice / 2)
        return max(24, chord - 6)
    }

    func angles(for index: Int) -> (start: CGFloat, end: CGFloat) {
        let end = CGFloat.pi / 2 - slice * CGFloat(index) + slice / 2
        return (end - slice, end)
    }

    func midpoint(for index: Int, in rect: CGRect) -> CGPoint {
        let (start, end) = angles(for: index)
        let mid = (start + end) / 2
        return CGPoint(x: rect.midX + cos(mid) * labelRadius, y: rect.midY - sin(mid) * labelRadius)
    }

    func index(at offset: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let distance = sqrt(offset.x * offset.x + offset.y * offset.y)
        guard distance >= innerRadius, distance <= outerRadius + 24 else { return nil }
        var angle = atan2(offset.y, offset.x)
        if angle < 0 { angle += 2 * .pi }
        var relative = CGFloat.pi / 2 + slice / 2 - angle
        while relative < 0 { relative += 2 * .pi }
        while relative >= 2 * .pi { relative -= 2 * .pi }
        return min(count - 1, Int(relative / slice))
    }
}

struct WedgeShape: Shape {
    var geometry: RadialGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (a0, a1) = geometry.angles(for: index)
        let r0 = geometry.innerRadius
        let r1 = geometry.outerRadius
        let k = geometry.corner
        let half = geometry.gap / 2
        let phiOuter = asin((k + half) / (r1 - k))
        let phiInner = asin((k + half) / (r0 + k))

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(angle) * radius, y: c.y - sin(angle) * radius)
        }
        func normal(_ angle: CGFloat, inward: Bool) -> CGVector {
            inward ? CGVector(dx: sin(angle), dy: -cos(angle)) : CGVector(dx: -sin(angle), dy: cos(angle))
        }
        func offset(_ p: CGPoint, _ v: CGVector, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: p.x + v.dx * distance, y: p.y - v.dy * distance)
        }
        func arc(_ path: inout Path, center: CGPoint, radius: CGFloat, from: CGPoint, to: CGPoint) {
            let s = atan2(from.y - center.y, from.x - center.x)
            let e = atan2(to.y - center.y, to.x - center.x)
            path.addArc(center: center, radius: radius, startAngle: .radians(s), endAngle: .radians(e), clockwise: true)
        }

        let outerEndCenter = point(r1 - k, a1 - phiOuter)
        let outerEndTangent = offset(outerEndCenter, normal(a1, inward: true), -k)
        let innerEndCenter = point(r0 + k, a1 - phiInner)
        let innerEndTangent = offset(innerEndCenter, normal(a1, inward: true), -k)
        let innerStartCenter = point(r0 + k, a0 + phiInner)
        let innerStartTangent = offset(innerStartCenter, normal(a0, inward: false), -k)
        let outerStartCenter = point(r1 - k, a0 + phiOuter)
        let outerStartTangent = offset(outerStartCenter, normal(a0, inward: false), -k)

        var path = Path()
        path.move(to: point(r1, a0 + phiOuter))
        path.addArc(center: c, radius: r1, startAngle: .radians(-(a0 + phiOuter)), endAngle: .radians(-(a1 - phiOuter)), clockwise: true)
        arc(&path, center: outerEndCenter, radius: k, from: point(r1, a1 - phiOuter), to: outerEndTangent)
        path.addLine(to: innerEndTangent)
        arc(&path, center: innerEndCenter, radius: k, from: innerEndTangent, to: point(r0, a1 - phiInner))
        path.addArc(center: c, radius: r0, startAngle: .radians(-(a1 - phiInner)), endAngle: .radians(-(a0 + phiInner)), clockwise: false)
        arc(&path, center: innerStartCenter, radius: k, from: point(r0, a0 + phiInner), to: innerStartTangent)
        path.addLine(to: outerStartTangent)
        arc(&path, center: outerStartCenter, radius: k, from: outerStartTangent, to: point(r1, a0 + phiOuter))
        path.closeSubpath()
        return path
    }
}

struct RadialWheelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var presentationID: UUID = UUID()
    var items: [RadialItem]
    var highlighted: Int?
    var title: String
    var emptyMessage: String
    var emptyDetail: String
    var geometry: RadialGeometry

    var body: some View {
        ZStack {
            if items.isEmpty {
                empty
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    wedge(item, index: index)
                }
                pill
            }
        }
        .frame(width: geometry.outerRadius * 2 + 40, height: geometry.outerRadius * 2 + 40)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.84)
        .onAppear { animateIn() }
        .onChange(of: presentationID) { animateIn() }
    }

    private func animateIn() {
        appeared = false
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }

    private func wedge(_ item: RadialItem, index: Int) -> some View {
        let shape = WedgeShape(geometry: geometry, index: index)
        let selected = highlighted == index
        return GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let mid = geometry.midpoint(for: index, in: rect)
            ZStack {
                label(item, selected: selected)
                    .frame(width: geometry.labelWidth)
                    .position(mid)
            }
            .frame(width: rect.width, height: rect.height)
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        if selected {
                            shape.fill(Theme.accent.opacity(0.78))
                        }
                    }
                    .overlay {
                        shape.stroke(Color.white.opacity(selected ? 0.35 : 0.12), lineWidth: 1)
                    }
            }
            .scaleEffect(selected && !reduceMotion ? 1.025 : 1)
            .offset(x: selected && !reduceMotion ? (mid.x - rect.midX) / geometry.labelRadius * 4 : 0,
                    y: selected && !reduceMotion ? (mid.y - rect.midY) / geometry.labelRadius * 4 : 0)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8), value: highlighted)
    }

    private func label(_ item: RadialItem, selected: Bool) -> some View {
        let dense = items.count > 8
        return VStack(spacing: dense ? 3 : 5) {
            Image(systemName: item.symbol)
                .font(.system(size: dense ? 16 : 20, weight: .medium))
                .symbolRenderingMode(.monochrome)
            Text(item.label)
                .font(.system(size: dense ? 10 : 11.5, weight: .bold, design: .rounded))
                .kerning(dense ? 0.3 : 0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentTransition(.identity)
    }

    private var pill: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: geometry.innerRadius * 2 - 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }

    private var empty: some View {
        VStack(spacing: 3) {
            Text(emptyMessage)
                .font(.system(size: 14, weight: .semibold))
            if !emptyDetail.isEmpty {
                Text(emptyDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: geometry.outerRadius * 2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RadialView: NSView {
    var items: [RadialItem] = [] { didSet { refresh() } }
    var emptyMessage = "No conversions available" { didSet { refresh() } }
    var subtitle = "" { didSet { refresh() } }
    var center: NSPoint = .zero { didSet { needsLayout = true } }
    var onSelect: ((RadialItem) -> Void)?
    var onCancel: (() -> Void)?
    var onDragEntered: ((NSDraggingInfo) -> Void)?
    var onDragSessionEnded: (() -> Void)?
    var interactive = false
    var advancedMode = false { didSet { refresh() } }

    private(set) var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            let label = highlighted.flatMap { items.indices.contains($0) ? items[$0].label : nil }
            let direction: CGFloat = highlighted.map { cos(CGFloat($0) * 2 * .pi / CGFloat(max(items.count, 1)) - .pi / 2) } ?? 0
            Task { @MainActor in JobRunner.shared.watchWheel(label: label, direction: direction) }
            if highlighted != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            }
            refresh()
        }
    }
    private var presentationID = UUID()
    func animatePresentation() { presentationID = UUID(); refresh() }
    private var trackingArea: NSTrackingArea?
    private let host: PassthroughHostingView<RadialWheelView>

    let discRadius: CGFloat = 170

    private var geometry: RadialGeometry { RadialGeometry(count: items.count) }

    override init(frame frameRect: NSRect) {
        host = PassthroughHostingView(rootView: RadialWheelView(items: [], highlighted: nil, title: "", emptyMessage: "", emptyDetail: "", geometry: RadialGeometry(count: 0)))
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.apple.finder.node")] + promiseTypes)
        wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        host.frame = NSRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func refresh() {
        let title: String
        if let highlighted, highlighted < items.count {
            title = items[highlighted].label
        } else {
            title = items.count == 1 ? items[0].label : (advancedMode ? "TOOLS" : "CONVERT")
        }
        host.rootView = RadialWheelView(
            presentationID: presentationID,
            items: items,
            highlighted: highlighted,
            title: title,
            emptyMessage: emptyMessage,
            emptyDetail: subtitle,
            geometry: geometry
        )
    }

    func index(at point: NSPoint) -> Int? {
        geometry.index(at: CGPoint(x: point.x - center.x, y: point.y - center.y))
    }

    func updateHighlight(forWindowPoint point: NSPoint) {
        layoutSubtreeIfNeeded()
        highlighted = index(at: convert(point, from: nil))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender)
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DragDebug.log("prepareForDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        return highlighted != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        guard let window, sender != nil, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        if window.frame.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) {
            onDragSessionEnded?()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlighted = nil
        onDragSessionEnded?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        DragDebug.log("performDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        guard let highlighted, highlighted < items.count else {
            onCancel?()
            return false
        }
        let item = items[highlighted]
        DispatchQueue.main.async { [weak self] in self?.onSelect?(item) }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
        if let highlighted, highlighted < items.count {
            onSelect?(items[highlighted])
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            if let highlighted, highlighted < items.count { onSelect?(items[highlighted]) }
        case 123, 126:
            step(-1)
        case 124, 125:
            step(1)
        default:
            super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = highlighted ?? -1
        var next = (current + delta) % items.count
        if next < 0 { next += items.count }
        highlighted = next
    }

    func clearHighlight() { highlighted = nil }

    func highlight(_ index: Int) {
        highlighted = items.indices.contains(index) ? index : nil
    }
}

