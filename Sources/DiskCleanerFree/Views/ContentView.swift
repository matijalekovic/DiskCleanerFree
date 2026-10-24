import SwiftUI

/// Width of the detail column, so views inside it can drop optional panels when space runs out.
struct DetailWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    var detailWidth: CGFloat {
        get { self[DetailWidthKey.self] }
        set { self[DetailWidthKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var sidebarAutoHidden = false
    @State private var detailWidth: CGFloat = .infinity

    /// Below this window width the sidebar folds away on its own, and comes back when there's room again.
    private let sidebarThreshold: CGFloat = 900

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            detail
                .environment(\.detailWidth, detailWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        .frame(minWidth: 620, minHeight: 500)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { adaptColumns(toWindowWidth: $0) }
    }

    private func adaptColumns(toWindowWidth width: CGFloat) {
        if width < sidebarThreshold, columns != .detailOnly {
            withAnimation { columns = .detailOnly }
            sidebarAutoHidden = true
        } else if width >= sidebarThreshold + 20, sidebarAutoHidden {
            withAnimation { columns = .all }
            sidebarAutoHidden = false
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = model.selection, let source = model.source(for: item) {
            let session = model.session(for: item)
            switch session?.state {
            case .scanning?:
                ScanningView(session: session!)
            case .done?:
                ReportView(session: session!)
                    .id(session!.id)
            default:
                SourceOverviewView(item: item, source: source, volume: model.volume(for: item), session: session)
            }
        } else {
            ContentUnavailableView {
                Label("Choose a Disk", systemImage: "internaldrive")
            } description: {
                Text("Pick a disk in the sidebar, or drop a folder here to see what takes up its space.")
            } actions: {
                Button("Scan Folder…") { model.chooseFolder() }
                    .buttonStyle(.glassProminent)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.open(url)
                return true
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Disks") {
                ForEach(model.volumes) { volume in
                    VolumeRow(volume: volume, session: model.session(for: .volume(volume.path)))
                        .tag(SidebarItem.volume(volume.path))
                        .contextMenu { menu(for: .volume(volume.path), volume: volume) }
                }
            }
            Section("Favorites") {
                ForEach(model.favorites, id: \.self) { path in
                    FolderRow(path: path, session: model.session(for: .folder(path)))
                        .tag(SidebarItem.folder(path))
                        .contextMenu { menu(for: .folder(path), volume: nil) }
                }
            }
            if !model.recentFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.recentFolders, id: \.self) { path in
                        FolderRow(path: path, session: model.session(for: .folder(path)))
                            .tag(SidebarItem.folder(path))
                            .contextMenu { menu(for: .folder(path), volume: nil) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.chooseFolder()
            } label: {
                Label("Scan Folder…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
    }

    @ViewBuilder
    private func menu(for item: SidebarItem, volume: VolumeInfo?) -> some View {
        let session = model.session(for: item)
        if session?.state == .scanning {
            Button("Cancel Scanning") { session?.cancel() }
        } else {
            Button(session?.root == nil ? "Scan" : "Rescan") { model.scan(item) }
            Button("Scan as Administrator") { model.scan(item, asAdmin: true) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
        if session?.root != nil {
            Button("Forget Scan Result") { model.forget(item) }
        }
        Divider()
        if case .folder(let path) = item {
            Button(model.isFavorite(path) ? "Remove from Favorites" : "Add to Favorites") {
                model.toggleFavorite(path)
            }
            if !model.isFavorite(path) {
                Button("Remove from List") { model.removeRecent(path) }
            }
        }
        if let volume, volume.isEjectable {
            Button("Eject “\(volume.name)”") { model.eject(volume) }
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let session: ScanSession?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: volume.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(volume.name).lineLimit(1)
                    Spacer(minLength: 4)
                    SessionBadge(session: session)
                }
                CapacityBar(used: volume.usedFraction, purgeable: volume.purgeableFraction)
                Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FolderRow: View {
    let path: String
    let session: ScanSession?

    var body: some View {
        let _ = session?.revision
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(forPath: path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(FileManager.default.displayName(atPath: path)).lineLimit(1)
            Spacer(minLength: 4)
            if let root = session?.root, session?.state != .scanning {
                Text(Format.bytes(root.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            SessionBadge(session: session)
        }
        .help(path)
    }
}

private struct SessionBadge: View {
    let session: ScanSession?

    var body: some View {
        switch session?.state {
        case .scanning?:
            ProgressView().controlSize(.mini)
        case .done?:
            Image(systemName: "chart.pie.fill").font(.caption).foregroundStyle(.tint)
        case .failed?:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

private struct CapacityBar: View {
    let used: Double
    let purgeable: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(used > 0.9 ? Color.red.gradient : Color.accentColor.gradient)
                    .frame(width: proxy.size.width * used)
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: proxy.size.width * purgeable)
                    .offset(x: proxy.size.width * (used - purgeable))
            }
        }
        .frame(height: 5)
    }
}
