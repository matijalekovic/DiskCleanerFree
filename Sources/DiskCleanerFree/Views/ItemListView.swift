import SwiftUI

/// Contents of the focused folder, largest first: a colored dot, the name and the size.
/// Selection works like Finder: click, Command-click, Shift-click, or drag a box from empty space.
struct ItemListView: View {
    let session: ScanSession
    let layout: SunburstLayout
    var onQuickLook: (FileNode) -> Void

    @State private var expandedFocus: ObjectIdentifier?
    @State private var rowFrames: [ObjectIdentifier: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase: [ObjectIdentifier: FileNode] = [:]
    private let visibleLimit = 120
    private static let space = "itemList"

    var body: some View {
        if let focus = session.focus {
            let children = focus.children
            let expanded = expandedFocus == focus.id
            let smallCutoff = Double(focus.size) * 0.001
            let visibleCount = expanded ? children.count
                : min(visibleLimit, children.prefix { Double($0.size) >= smallCutoff }.count)
            let rows = Array(children.prefix(visibleCount))
            let hidden = children.dropFirst(visibleCount)
            let pending = session.collectedBytes(in: focus)
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(focus.name)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .truncationMode(.tail)
                                Spacer(minLength: 12)
                                Text(Format.bytes(focus.size - pending))
                                    .monospacedDigit()
                                    .fixedSize()
                                    .contentTransition(.numericText())
                            }
                            .font(.system(size: 22, weight: .light))
                            if pending > 0 {
                                Text("\(Format.bytes(pending)) collected for deletion")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { child in
                                ItemRow(node: child, color: layout.colors[child.id], session: session,
                                        onClick: { click(child, in: rows) }, onQuickLook: onQuickLook)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                                        rowFrames[child.id] = $0
                                    }
                            }
                        }
                        if !hidden.isEmpty {
                            PlainRow(name: "smaller objects…", size: hidden.reduce(0) { $0 + session.remainingSize(of: $1) },
                                     dot: .secondary.opacity(0.35), dimmed: true) {
                                expandedFocus = focus.id
                            }
                            .help("Show \(Format.count(hidden.count)) more items")
                        }
                        if children.isEmpty {
                            Text("This folder is empty")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }

                        if focus === session.root, session.source.isVolume {
                            Divider().padding(.vertical, 10).padding(.horizontal, 10)
                            PlainRow(name: "free space", size: session.freeSpace,
                                     dot: .secondary.opacity(0.35), dimmed: true)
                            if session.freeAndPurgeable > session.freeSpace {
                                PlainRow(name: "free + purgeable", size: session.freeAndPurgeable,
                                         marker: "~", dimmed: true)
                            }
                        }
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 16)
                    // Fill the viewport so there is always empty space to start a selection box from.
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { session.clearSelection() }
                    .gesture(bandGesture(rows))
                    .overlay(alignment: .topLeading) { bandOverlay }
                    .coordinateSpace(.named(Self.space))
                }
                .scrollContentBackground(.hidden)
            }
            .animation(.snappy(duration: 0.2), value: pending)
        }
    }

    /// Finder-style click handling for one row.
    private func click(_ node: FileNode, in rows: [FileNode]) {
        let flags = NSEvent.modifierFlags
        let isDoubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
        if flags.contains(.command) {
            session.toggleSelection(node)
        } else if flags.contains(.shift) {
            session.selectRange(to: node, in: rows)
        } else if isDoubleClick {
            if node.canNavigate { session.navigate(to: node) } else if node.isRealItem { onQuickLook(node) }
        } else {
            session.select(node)
        }
    }

    /// Dragging from empty space draws a box and selects every row it touches.
    private func bandGesture(_ rows: [FileNode]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if band == nil {
                    let flags = NSEvent.modifierFlags
                    bandBase = flags.contains(.command) || flags.contains(.shift) ? session.selection : [:]
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                band = rect
                let hits = rows.filter { rowFrames[$0.id]?.intersects(rect) == true }
                session.setSelection(hits, adding: bandBase)
            }
            .onEnded { _ in band = nil }
    }

    @ViewBuilder private var bandOverlay: some View {
        if let band {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1))
                .frame(width: band.width, height: band.height)
                .offset(x: band.minX, y: band.minY)
                .allowsHitTesting(false)
        }
    }
}

private struct ItemRow: View {
    let node: FileNode
    let color: Color?
    let session: ScanSession
    var onClick: () -> Void
    var onQuickLook: (FileNode) -> Void

    @State private var showInfo = false

    var body: some View {
        let isHovered = session.hovered === node
        let isSelected = session.isSelected(node)
        let isCollected = session.isCollected(node)
        let dot = color ?? Color.secondary.opacity(0.35)
        // A collected item shows what it will free; a folder shows what's left once its collected contents go.
        let size = isCollected ? node.size : session.remainingSize(of: node)
        HStack(spacing: 10) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(node.explanation != nil && !node.isRealItem ? node.name.lowercased() + "…" : node.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(isCollected)
                .foregroundStyle(node.isSpecial ? AnyShapeStyle(dot) : AnyShapeStyle(.primary))
            Spacer(minLength: 12)
            Text(Format.bytes(size))
                .monospacedDigit()
                .fixedSize()
                .strikethrough(isCollected)
                .foregroundStyle(isHovered || isSelected ? .primary : .secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28)
                      : isHovered ? Color.primary.opacity(0.07)
                      : .clear)
        }
        .opacity(isCollected ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { session.hovered = node } else if session.hovered === node { session.hovered = nil }
        }
        .onTapGesture {
            if node.isSpecial, node.explanation != nil {
                showInfo = true
            } else {
                onClick()
            }
        }
        .popover(isPresented: $showInfo, arrowEdge: .leading) {
            Text(node.explanation ?? "")
                .frame(width: 280)
                .padding()
        }
        .if(node.isRealItem) { $0.draggable(node.url) }
        .contextMenu { NodeMenu(node: node, session: session, onQuickLook: onQuickLook) }
        .help(node.isRealItem ? node.path : node.kindDescription)
    }
}

/// A non-file row such as "smaller objects…" or "free space".
private struct PlainRow: View {
    let name: String
    let size: Int64
    var dot: Color? = nil
    var marker: String? = nil
    var dimmed = false
    var action: (() -> Void)? = nil

    var body: some View {
        let row = HStack(spacing: 10) {
            if let marker {
                Text(marker).frame(width: 7)
            } else {
                Circle().fill(dot ?? .clear).frame(width: 7, height: 7)
            }
            Text(name).lineLimit(1)
            Spacer(minLength: 12)
            Text(Format.bytes(size)).monospacedDigit().fixedSize()
        }
        .foregroundStyle(dimmed ? .secondary : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}
