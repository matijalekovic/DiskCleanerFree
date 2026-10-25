import SwiftUI

/// Staging area for deletion. Items are dropped here from the map or list, reviewed, then deleted together.
/// The drawer button rolls the bar up into a full list of everything that is about to be deleted.
struct CollectorBar: View {
    @Bindable var session: ScanSession
    /// Height of the review panel when the drawer is open.
    var expandedHeight: CGFloat
    var onQuickLook: (FileNode) -> Void

    @AppStorage(Prefs.moveToTrash) private var moveToTrash = true
    @AppStorage(Prefs.confirmDelete) private var confirmDelete = true
    @State private var isTargeted = false
    @State private var confirming = false
    @State private var isExpanded = false
    @State private var isHoveringHandle = false
    @State private var isHoveringClear = false

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                CollectedList(session: session, moveToTrash: moveToTrash, onQuickLook: onQuickLook)
                    .frame(height: max(160, expandedHeight - 56))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Divider().overlay(Color.red.opacity(0.3))
            }
            barRow
        }
        // A solid backdrop keeps the open list readable over the colorful map.
        .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(isExpanded ? 0.8 : 0)))
        .clipShape(shape)
        // Red at all times so the deletion area stands out; stronger while dragging over it or holding items.
        .glassEffect(.regular.tint(Color.red.opacity(isTargeted ? 0.4 : session.collected.isEmpty ? 0.14 : 0.24)),
                     in: shape)
        .overlay {
            shape
                .strokeBorder(Color.red.opacity(isTargeted ? 0.8 : 0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: session.collected.isEmpty ? [6, 4] : []))
                .allowsHitTesting(false)
        }
        .animation(.snappy, value: isTargeted)
        .animation(.snappy, value: session.collected.count)
        .dropDestination(for: URL.self) { urls, _ in
            session.collect(urls: urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(moveToTrash ? "Move to Trash" : "Delete Permanently", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(moveToTrash
                 ? "The items are moved to the Trash. Empty the Trash to actually free the space."
                 : "The items are removed immediately. This can't be undone.")
        }
    }

    private var barRow: some View {
        HStack(spacing: 10) {
            drawerHandle

            if session.collected.isEmpty {
                Text(isTargeted ? "Drop to collect" : "Drag files and folders here to collect them for deletion")
                    .foregroundStyle(Color.red.opacity(0.85))
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 8)
                if session.isDeleting {
                    ProgressView().controlSize(.small)
                    Text(moveToTrash ? "Moving to Trash…" : "Deleting…").foregroundStyle(.secondary)
                } else {
                    Button {
                        session.clearCollector()
                    } label: {
                        Label("Clear", systemImage: "xmark")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.primary.opacity(isHoveringClear ? 0.14 : 0.08)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringClear = $0 }
                    .fixedSize()
                    .help("Remove everything from the Collector without deleting it")

                    Button(role: .destructive) {
                        if confirmDelete { confirming = true } else { delete() }
                    } label: {
                        Label(moveToTrash ? "Move to Trash" : "Delete", systemImage: "trash")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .fixedSize()
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
    }

    /// Tray, total and arrow in one pill; clicking anywhere on it opens or closes the review list.
    private var drawerHandle: some View {
        let isEmpty = session.collected.isEmpty
        let count = session.collected.count
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isEmpty ? "tray" : "tray.full.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                if !isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Format.bytes(session.collectedSize))
                            .font(.headline)
                            .monospacedDigit()
                        Text("\(Format.count(count)) item\(count == 1 ? "" : "s") collected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.red)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(Color.red.opacity(isHoveringHandle ? 0.2 : isEmpty ? 0 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHoveringHandle = $0 }
        .help(isExpanded ? "Close the list of collected items" : "Review everything collected for deletion")
    }

    private var confirmTitle: String {
        let count = session.collected.count
        return "\(moveToTrash ? "Move" : "Delete") \(count) item\(count == 1 ? "" : "s") (\(Format.bytes(session.collectedSize)))\(moveToTrash ? " to the Trash" : "")?"
    }

    private func delete() {
        Task { await session.deleteCollected(moveToTrash: moveToTrash) }
    }
}

/// Everything in the Collector, largest first, with where it lives on disk.
private struct CollectedList: View {
    let session: ScanSession
    let moveToTrash: Bool
    var onQuickLook: (FileNode) -> Void

    var body: some View {
        let items = session.collected.sorted { $0.size > $1.size }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(moveToTrash ? "To be moved to the Trash" : "To be deleted")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(Format.count(items.count)) items · \(Format.bytes(session.collectedSize))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if items.isEmpty {
                ContentUnavailableView("Nothing collected yet",
                                       systemImage: "tray",
                                       description: Text("Drag files and folders from the map or the list onto this bar."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { node in
                            CollectedRow(node: node, session: session, onQuickLook: onQuickLook)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct CollectedRow: View {
    let node: FileNode
    let session: ScanSession
    var onQuickLook: (FileNode) -> Void

    var body: some View {
        let isHovered = session.hovered === node
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(for: node)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1).truncationMode(.tail)
                Text(node.parent?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(Format.bytes(node.size))
                .monospacedDigit()
                .fixedSize()
            Button("Show in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button("Remove from Collector", systemImage: "xmark.circle.fill") { session.uncollect(node) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Keep this item: remove it from the Collector")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { session.hovered = node } else if session.hovered === node { session.hovered = nil }
        }
        // Clicking a row shows the item in its folder on the map.
        .onTapGesture {
            if let parent = node.parent, parent.isAlive {
                session.navigate(to: parent)
                session.selected = node
            }
        }
        .contextMenu { NodeMenu(node: node, session: session, onQuickLook: onQuickLook) }
        .help(node.path)
    }
}
