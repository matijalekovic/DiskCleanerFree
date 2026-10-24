import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Result of a finished scan: map on the left, contents list on the right, Collector at the bottom.
/// The two panes are laid out by hand rather than with `.inspector`, whose split view enforces a
/// minimum map width and spills past the window edges when the window gets narrow.
struct ReportView: View {
    @Bindable var session: ScanSession
    @Environment(AppModel.self) private var model
    @Environment(\.detailWidth) private var detailWidth

    @AppStorage(Prefs.chartDepth) private var chartDepth = 6
    @AppStorage(Prefs.showFreeSpace) private var showFreeSpace = false
    @AppStorage(Prefs.colorfulFiles) private var colorfulFiles = false
    @State private var showList = true
    @State private var quickLookURL: URL?
    @State private var cache = LayoutCache()
    @State private var mapHeight: CGFloat = 600

    /// The list needs room next to the map; in a narrow window the map gets all the space.
    private var listFits: Bool { detailWidth >= 600 }
    private var listWidth: CGFloat { min(420, max(260, detailWidth * 0.42)) }

    var body: some View {
        let layout = currentLayout
        HStack(spacing: 0) {
            mapPane(layout)
                .frame(minWidth: 0, maxWidth: .infinity)
            if showList, listFits {
                ItemListView(session: session, layout: layout, onQuickLook: quickLook)
                    .frame(width: listWidth)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .leading) { Divider() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background { ChartBackdrop() }
        .animation(.snappy(duration: 0.25), value: showList && listFits)
        .toolbar { toolbar }
        .navigationTitle(session.source.name)
        .navigationSubtitle(subtitle)
        .quickLookPreview($quickLookURL)
        .focusedSceneValue(\.scanSession, session)
        .onKeyPress(.space) {
            guard let node = session.selected ?? session.hovered, node.isRealItem else { return .ignored }
            quickLook(node)
            return .handled
        }
        .onKeyPress(.escape) {
            guard session.canGoUp else { return .ignored }
            session.goUp()
            return .handled
        }
    }

    private func mapPane(_ layout: SunburstLayout) -> some View {
        SunburstView(session: session, layout: layout, onQuickLook: quickLook)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    PathBar(session: session)
                    if session.restrictedCount > 0, !model.hasFullDiskAccess || !session.scannedAsAdmin {
                        RestrictedBanner(session: session)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            // Room for the closed Collector; when its drawer opens it rolls up over the map instead of shrinking it.
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 70) }
            .overlay(alignment: .bottom) {
                CollectorBar(session: session, expandedHeight: mapHeight * 0.5, onQuickLook: quickLook)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
            .overlay(alignment: .top) { FreedToast(session: session) }
    }

    private var currentLayout: SunburstLayout {
        guard let focus = session.focus else { return SunburstLayout() }
        let key = SunburstLayout.Key(focus: focus.id, revision: session.revision, depth: chartDepth,
                                     showFree: showFreeSpace, colorfulFiles: colorfulFiles)
        return cache.layout(for: key) {
            let free = showFreeSpace && focus === session.root ? session.freeSpace : 0
            return SunburstLayout(focus: focus, depth: chartDepth, freeSpace: free, colorfulFiles: colorfulFiles)
        }
    }

    private var subtitle: String {
        guard let root = session.root else { return "" }
        var parts = ["\(Format.bytes(root.size)) used", "\(Format.count(root.fileCount)) files"]
        if session.source.isVolume { parts.insert("\(Format.bytes(session.freeSpace)) free", at: 1) }
        if session.scannedAsAdmin { parts.append("Administrator") }
        return parts.joined(separator: " · ")
    }

    private func quickLook(_ node: FileNode) {
        guard node.isRealItem else { return }
        quickLookURL = node.url
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Back", systemImage: "chevron.left") { session.goBack() }
                .disabled(!session.canGoBack)
                .help("Back")
            Button("Forward", systemImage: "chevron.right") { session.goForward() }
                .disabled(!session.canGoForward)
                .help("Forward")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Rescan", systemImage: "arrow.clockwise") { session.start() }
                Button("Rescan as Administrator", systemImage: "lock.open") { session.start(asAdmin: true) }
                Divider()
                Button("Export to CSV…", systemImage: "square.and.arrow.up") { exportCSV() }
                Button("Show in Finder", systemImage: "finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.focus?.url ?? session.source.url])
                }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            } primaryAction: {
                session.start()
            }
            .help("Rescan (hold for more options)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Contents", systemImage: "sidebar.trailing") { showList.toggle() }
                .disabled(!listFits)
                .help(listFits ? "Show or hide the contents list" : "Make the window wider to show the contents list")
        }
    }

    private func exportCSV() {
        guard let node = session.focus else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(node.name) scan.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.exportCSV(of: node, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Holds the last computed layout so hovering doesn't rebuild the rings.
private final class LayoutCache {
    private var key: SunburstLayout.Key?
    private var value = SunburstLayout()

    func layout(for key: SunburstLayout.Key, make: () -> SunburstLayout) -> SunburstLayout {
        if key != self.key {
            value = make()
            self.key = key
        }
        return value
    }
}

private struct ChartBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RadialGradient(
            colors: scheme == .dark
                ? [Color(red: 0.13, green: 0.14, blue: 0.20), Color(red: 0.07, green: 0.07, blue: 0.10)]
                : [Color(white: 0.99), Color(red: 0.92, green: 0.93, blue: 0.96)],
            center: .center, startRadius: 40, endRadius: 700)
        .ignoresSafeArea()
    }
}

/// Breadcrumbs from the scan root to the focused folder. Collapses leading crumbs into a menu
/// when the window is too narrow to show them all.
private struct PathBar: View {
    let session: ScanSession

    var body: some View {
        let _ = session.revision
        let lineage = session.focus?.lineage ?? []
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                ForEach([6, 4, 3, 2], id: \.self) { count in
                    crumbs(lineage, showing: count, fixed: true)
                }
                crumbs(lineage, showing: 1, fixed: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let focus = session.focus {
                Text(Format.bytes(focus.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.trailing, 6)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func crumbs(_ lineage: [FileNode], showing count: Int, fixed: Bool) -> some View {
        let tail = lineage.suffix(count)
        return HStack(spacing: 2) {
            if lineage.count > tail.count {
                Menu {
                    ForEach(lineage.dropLast(tail.count).reversed()) { node in
                        Button(node.name) { session.navigate(to: node) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                separator
            }
            ForEach(Array(tail.enumerated()), id: \.element.id) { index, node in
                if index > 0 { separator }
                Button {
                    session.navigate(to: node)
                } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: IconCache.icon(for: node)).resizable().frame(width: 16, height: 16)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: fixed, vertical: false)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fontWeight(node === session.focus ? .semibold : .regular)
                .foregroundStyle(node === session.focus ? .primary : .secondary)
            }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
    }
}

private struct RestrictedBanner: View {
    let session: ScanSession
    @Environment(AppModel.self) private var model
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            ViewThatFits(in: .horizontal) {
                banner(compact: false)
                banner(compact: true)
            }
            .help(model.hasFullDiskAccess
                  ? "Rescan as Administrator to look inside folders owned by the system and other users."
                  : "Grant Full Disk Access, or rescan as Administrator, to reveal them.")
        }
    }

    private func banner(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .foregroundStyle(.orange)
            Text(compact ? "\(Format.count(session.restrictedCount)) unreadable"
                         : "\(Format.count(session.restrictedCount)) folders couldn't be read")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: !compact, vertical: false)
            Spacer(minLength: 4)
            if !model.hasFullDiskAccess, !compact {
                Button("Grant Access") { Permissions.openFullDiskAccessSettings() }
                    .help("Open Full Disk Access in System Settings")
            }
            Button(compact ? "Admin Scan" : "Rescan as Admin") { session.start(asAdmin: true) }
                .fixedSize()
            Button("Dismiss", systemImage: "xmark") { withAnimation { dismissed = true } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .capsule)
    }
}

private struct FreedToast: View {
    @Bindable var session: ScanSession

    var body: some View {
        Group {
            if let freed = session.lastFreed {
                VStack(spacing: 4) {
                    Label(session.lastDeleteMovedToTrash
                          ? "Moved \(Format.bytes(freed)) to the Trash"
                          : "You've just freed up \(Format.bytes(freed))",
                          systemImage: "checkmark.circle.fill")
                        .font(.headline)
                    if session.lastDeleteMovedToTrash {
                        Text("Empty the Trash to reclaim the space.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.deletionFailures.isEmpty {
                        Text("\(session.deletionFailures.count) items couldn't be deleted.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(.green.opacity(0.2)), in: .capsule)
                .padding(.top, 70)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: freed) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { session.lastFreed = nil }
                }
            }
        }
        .animation(.spring, value: session.lastFreed)
    }
}

// MARK: - Focused session for menu commands

struct ScanSessionKey: FocusedValueKey {
    typealias Value = ScanSession
}

extension FocusedValues {
    var scanSession: ScanSession? {
        get { self[ScanSessionKey.self] }
        set { self[ScanSessionKey.self] = newValue }
    }
}
