import SwiftUI

/// Contents of the focused folder, largest first: a colored dot, the name and the size.
struct ItemListView: View {
    let session: ScanSession
    let layout: SunburstLayout
    var onQuickLook: (FileNode) -> Void

    @State private var expandedFocus: ObjectIdentifier?
    private let visibleLimit = 120

    var body: some View {
        if let focus = session.focus {
            let children = focus.children
            let expanded = expandedFocus == focus.id
            let smallCutoff = Double(focus.size) * 0.001
            let visibleCount = expanded ? children.count
                : min(visibleLimit, children.prefix { Double($0.size) >= smallCutoff }.count)
            let hidden = children.dropFirst(visibleCount)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(focus.name)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .truncationMode(.tail)
                        Spacer(minLength: 12)
                        Text(Format.bytes(focus.size))
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(.system(size: 22, weight: .light))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(children.prefix(visibleCount)) { child in
                            ItemRow(node: child, color: layout.colors[child.id],
                                    session: session, onQuickLook: onQuickLook)
                        }
                    }
                    if !hidden.isEmpty {
                        PlainRow(name: "smaller objects…", size: hidden.reduce(0) { $0 + $1.size },
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
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ItemRow: View {
    let node: FileNode
    let color: Color?
    let session: ScanSession
    var onQuickLook: (FileNode) -> Void

    @State private var showInfo = false

    var body: some View {
        let isHovered = session.hovered === node
        let isSelected = session.selected === node
        let isCollected = session.isCollected(node)
        let dot = color ?? Color.secondary.opacity(0.35)
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
            Text(Format.bytes(node.size))
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(isHovered || isSelected ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25)
                      : isHovered ? Color.primary.opacity(0.07)
                      : .clear)
        }
        .opacity(isCollected ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { session.hovered = node } else if session.hovered === node { session.hovered = nil }
        }
        .onTapGesture {
            if node.canNavigate {
                session.navigate(to: node)
            } else if !node.isRealItem, node.explanation != nil {
                showInfo = true
            } else {
                session.selected = node
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
