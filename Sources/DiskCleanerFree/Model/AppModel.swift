import AppKit
import Observation

enum SidebarItem: Hashable {
    case volume(String)
    case folder(String)

    var path: String {
        switch self {
        case .volume(let path), .folder(let path): path
        }
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var volumes: [VolumeInfo] = []
    private(set) var favorites: [String] = []
    private(set) var recentFolders: [String] = []
    private(set) var sessions: [String: ScanSession] = [:]
    var selection: SidebarItem?
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let favoritesKey = "favoriteFolders"

    init() {
        favorites = UserDefaults.standard.stringArray(forKey: Self.favoritesKey)
            ?? [NSHomeDirectory(), NSHomeDirectory() + "/Downloads"]
        reloadVolumes()
        selection = volumes.first.map { .volume($0.path) }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hasFullDiskAccess = Permissions.hasFullDiskAccess
                self?.reloadVolumes()
            }
        })
    }

    func reloadVolumes() {
        volumes = VolumeInfo.mounted()
        if case .volume(let path) = selection, !volumes.contains(where: { $0.path == path }) {
            selection = volumes.first.map { .volume($0.path) }
        }
    }

    // MARK: Sources & sessions

    func source(for item: SidebarItem) -> ScanSource? {
        switch item {
        case .volume(let path):
            volumes.first { $0.path == path }.map(ScanSource.init(volume:))
        case .folder(let path):
            FileManager.default.fileExists(atPath: path) ? ScanSource(folder: URL(fileURLWithPath: path)) : nil
        }
    }

    func volume(for item: SidebarItem) -> VolumeInfo? {
        guard case .volume(let path) = item else { return nil }
        return volumes.first { $0.path == path }
    }

    func session(for item: SidebarItem) -> ScanSession? {
        sessions[item.path]
    }

    func scan(_ item: SidebarItem, asAdmin: Bool = false) {
        guard let source = source(for: item) else { return }
        let session = sessions[source.path] ?? ScanSession(source: source)
        sessions[source.path] = session
        selection = item
        session.start(asAdmin: asAdmin)
    }

    func forget(_ item: SidebarItem) {
        sessions[item.path]?.cancel()
        sessions[item.path] = nil
    }

    /// Opens a folder or disk dropped onto the window or picked in the open panel, and scans it.
    func open(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let volume = volumes.first(where: { $0.path == path }) {
            scan(.volume(volume.path))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        if !favorites.contains(path) {
            recentFolders.removeAll { $0 == path }
            recentFolders.insert(path, at: 0)
        }
        scan(.folder(path))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: Favorites

    func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) {
            favorites.remove(at: index)
        } else {
            favorites.append(path)
            recentFolders.removeAll { $0 == path }
        }
        UserDefaults.standard.set(favorites, forKey: Self.favoritesKey)
    }

    func removeRecent(_ path: String) {
        recentFolders.removeAll { $0 == path }
        if selection == .folder(path) { selection = volumes.first.map { .volume($0.path) } }
    }

    func eject(_ volume: VolumeInfo) {
        sessions[volume.path]?.cancel()
        sessions[volume.path] = nil
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
    }
}
