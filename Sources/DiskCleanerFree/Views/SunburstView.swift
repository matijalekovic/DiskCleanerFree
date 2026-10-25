import SwiftUI

/// The interactive disk map: hover to inspect, click a folder to zoom in, click the center to go up,
/// drag a segment onto the Collector.
struct SunburstView: View {
    let session: ScanSession
    let layout: SunburstLayout
    var onQuickLook: (FileNode) -> Void

    @State private var appeared = true

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry(size: proxy.size, depth: layout.depth)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry)
                }
                CenterDisc(session: session, diameter: geometry.inner * 2 - 10)
                    .position(geometry.center)
                    .allowsHitTesting(false)
            }
            .scaleEffect(appeared ? 1 : 0.86)
            .opacity(appeared ? 1 : 0)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let node = hit(location, geometry: geometry)
                    if node !== session.hovered { session.hovered = node }
                case .ended:
                    session.hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                tap(at: value.location, geometry: geometry)
            })
            .onDrag {
                guard let node = session.hovered, node.isRealItem else { return NSItemProvider() }
                return NSItemProvider(object: node.url as NSURL)
            }
            .contextMenu {
                if let node = session.hovered {
                    NodeMenu(node: node, session: session, onQuickLook: onQuickLook)
                }
            }
        }
        .onChange(of: session.focus?.id) {
            appeared = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private func hit(_ location: CGPoint, geometry: RingGeometry) -> FileNode? {
        guard let (depth, angle) = geometry.ring(at: location), depth > 0 else { return nil }
        return layout.segment(depth: depth, angle: angle)?.node
    }

    private func tap(at location: CGPoint, geometry: RingGeometry) {
        guard let (depth, angle) = geometry.ring(at: location) else { return }
        if depth == 0 {
            session.goUp()
            return
        }
        guard let node = layout.segment(depth: depth, angle: angle)?.node else { return }
        if node.canNavigate {
            session.navigate(to: node)
        } else {
            session.select(node)
        }
    }

    private func draw(in context: inout GraphicsContext, geometry: RingGeometry) {
        let hovered = session.hovered
        let even = FillStyle(eoFill: true)
        for segment in layout.segments {
            let path = geometry.path(depth: segment.depth, start: segment.start, end: segment.end)
            context.fill(path, with: .color(segment.color), style: even)
            guard let node = segment.node else {
                context.stroke(path, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                continue
            }
            if let hovered, node === hovered || node.isDescendant(of: hovered) {
                context.fill(path, with: .color(.white.opacity(0.28)), style: even)
            }
            if session.isCollected(node) {
                context.fill(path, with: .color(.black.opacity(0.35)), style: even)
            }
            if node.kind == .purgeable || node.kind == .hidden {
                context.drawLayer { layer in
                    layer.clip(to: path, style: even)
                    var stripes = Path()
                    let r = geometry.outer
                    var x = -r
                    while x < r * 2 {
                        stripes.move(to: CGPoint(x: geometry.center.x + x, y: geometry.center.y - r))
                        stripes.addLine(to: CGPoint(x: geometry.center.x + x - r, y: geometry.center.y + r))
                        x += 7
                    }
                    layer.stroke(stripes, with: .color(.white.opacity(0.16)), lineWidth: 2)
                }
            }
            if session.isSelected(node) {
                context.stroke(path, with: .color(.white), lineWidth: 2)
            }
        }
        if let hovered, let segment = layout.segments.first(where: { $0.node === hovered }) {
            context.stroke(geometry.path(depth: segment.depth, start: segment.start, end: segment.end),
                           with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
    }
}

/// The disc in the middle of the map: the hovered item, or the focused folder.
/// Lines have fixed heights and fit the circle's inscribed square, so hovering never reflows it.
private struct CenterDisc: View {
    let session: ScanSession
    let diameter: CGFloat

    var body: some View {
        let _ = session.revision
        let node = session.hovered ?? session.focus
        let side = diameter * 0.70
        let shown = node.map { session.isCollected($0) ? $0.size : session.remainingSize(of: $0) } ?? 0
        let size = Format.steadyBytes(shown)
        VStack(spacing: 0) {
            Text(node?.name ?? "")
                .font(.system(size: max(9, side * 0.12), weight: .medium))
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .frame(width: side, height: side * 0.2)
            Text(size.number)
                .font(.system(size: max(12, side * 0.3), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: side, height: side * 0.36)
            Text(size.unit)
                .font(.system(size: max(9, side * 0.13), weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: side, height: side * 0.2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: diameter, height: diameter)
        .glassEffect(.regular, in: .circle)
        .transaction { $0.animation = nil }
    }
}

/// Context menu actions shared by the map, the list and the Collector.
struct NodeMenu: View {
    let node: FileNode
    let session: ScanSession
    var onQuickLook: (FileNode) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if node.isRealItem {
            if node.canNavigate {
                Button("Zoom In", systemImage: "plus.magnifyingglass") { session.navigate(to: node) }
            }
            Button("Quick Look", systemImage: "eye") { onQuickLook(node) }
            Button("Show in Finder", systemImage: "finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(node.url) }
            Button("Copy Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
            if node.isDirectory {
                Button(model.isFavorite(node.path) ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: model.isFavorite(node.path) ? "star.slash" : "star") {
                    model.toggleFavorite(node.path)
                }
            }
            Divider()
            if session.isSelected(node), session.selection.count > 1 {
                Button("Move \(session.selection.count) Items to Collector", systemImage: "tray.and.arrow.down") {
                    session.collectSelection()
                }
            } else if session.collected.contains(where: { $0 === node }) {
                Button("Remove from Collector", systemImage: "tray.and.arrow.up") { session.uncollect(node) }
            } else if !session.isCollected(node) {
                Button("Move to Collector", systemImage: "tray.and.arrow.down") { session.collect(node) }
            }
        } else if node.kind == .systemVolume {
            Button("Zoom In", systemImage: "plus.magnifyingglass") { session.navigate(to: node) }
        } else if let explanation = node.explanation {
            Text(explanation)
        }
    }
}
