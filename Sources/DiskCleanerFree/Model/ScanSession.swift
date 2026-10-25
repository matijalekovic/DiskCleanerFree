import AppKit
import Observation

/// One scanned disk or folder: scan state, the result tree, navigation history and the Collector.
@MainActor @Observable
final class ScanSession: Identifiable {
    enum State: Equatable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    let source: ScanSource
    nonisolated var id: String { source.path }

    var state: State = .idle
    private(set) var root: FileNode?
    private(set) var focus: FileNode?
    var hovered: FileNode?
    /// Items selected in the contents list (or by clicking a file on the map), keyed by identity.
    private(set) var selection: [ObjectIdentifier: FileNode] = [:]
    @ObservationIgnored private var selectionAnchor: FileNode?
    private(set) var backStack: [FileNode] = []
    private(set) var forwardStack: [FileNode] = []
    private(set) var collected: [FileNode] = []
    /// Bumped whenever the tree changes in place, since nodes themselves are not observable.
    private(set) var revision = 0

    var scannedAsAdmin = false
    var isAdminScanInFlight = false
    var filesScanned = 0
    var bytesScanned: Int64 = 0
    var restrictedCount = 0
    var currentPath = ""
    var elapsed: TimeInterval = 0
    var freeSpace: Int64 = 0
    /// Free space plus what macOS can purge on demand.
    var freeAndPurgeable: Int64 = 0

    var isDeleting = false
    var lastFreed: Int64?
    var lastDeleteMovedToTrash = true
    var deletionFailures: [String] = []

    @ObservationIgnored private var collectedWithinCache: [ObjectIdentifier: Int64]?
    @ObservationIgnored private var progress: ScanProgress?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt = Date()

    init(source: ScanSource) {
        self.source = source
    }

    // MARK: Scanning

    func start(asAdmin: Bool = false) {
        progress?.cancel()
        let progress = ScanProgress()
        self.progress = progress
        state = .scanning
        isAdminScanInFlight = asAdmin
        filesScanned = 0
        bytesScanned = 0
        restrictedCount = 0
        currentPath = source.path
        startedAt = Date()
        elapsed = 0

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }

        let source = self.source
        let thread = Thread { [weak self] in
            let result: Result<FileNode, Error>
            if asAdmin {
                result = Result {
                    try AdminScanner.scan(path: source.path, name: source.name,
                                          isStartupDisk: source.isStartupDisk, progress: progress)
                }
            } else {
                result = .success(ScanEngine.scan(path: source.path, name: source.name,
                                                  isStartupDisk: source.isStartupDisk, progress: progress))
            }
            DispatchQueue.main.async { self?.finish(result, progress: progress, asAdmin: asAdmin) }
        }
        thread.stackSize = 128 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() {
        progress?.cancel()
    }

    private func poll() {
        guard let progress else { return }
        filesScanned = progress.files.load(ordering: .relaxed)
        bytesScanned = progress.bytes.load(ordering: .relaxed)
        restrictedCount = progress.restricted.load(ordering: .relaxed)
        currentPath = progress.currentPath
        elapsed = Date().timeIntervalSince(startedAt)
    }

    private func finish(_ result: Result<FileNode, Error>, progress: ScanProgress, asAdmin: Bool) {
        guard progress === self.progress else { return }
        poll()
        timer?.invalidate()
        timer = nil
        self.progress = nil
        isAdminScanInFlight = false

        if progress.isCancelled {
            state = root == nil ? .idle : .done
            return
        }
        switch result {
        case .failure(let error as AdminScanner.Failure):
            state = root == nil ? .failed(error.localizedDescription) : .done
        case .failure(let error):
            state = .failed(error.localizedDescription)
        case .success(let tree):
            addSpecialSpace(to: tree)
            root = tree
            focus = tree
            hovered = nil
            clearSelection()
            backStack = []
            forwardStack = []
            collected = []
            collectedWithinCache = nil
            scannedAsAdmin = asAdmin
            revision += 1
            state = .done
        }
    }

    /// Attributes the volume's used space that no scanned file accounts for.
    private func addSpecialSpace(to tree: FileNode) {
        guard source.isVolume, let volume = VolumeInfo(url: source.url) else { return }
        freeSpace = volume.available
        freeAndPurgeable = max(volume.availableForImportantUsage, volume.available)
        let unaccounted = max(0, volume.used - tree.size)
        let purgeable = min(volume.purgeable, unaccounted)
        if purgeable > 0 {
            tree.adopt(FileNode(name: "Purgeable space", kind: .purgeable, size: purgeable))
        }
        let hidden = unaccounted - purgeable
        if hidden > 1 << 20 {
            tree.adopt(FileNode(name: "Hidden space", kind: .hidden, size: hidden))
        }
    }

    // MARK: Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { focus?.parent != nil }

    func navigate(to node: FileNode) {
        guard node !== focus, node.isDirectory, node.canNavigate || node === root else { return }
        if let focus { backStack.append(focus) }
        forwardStack.removeAll()
        focus = node
        hovered = nil
        clearSelection()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let focus { forwardStack.append(focus) }
        focus = previous
        hovered = nil
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let focus { backStack.append(focus) }
        focus = next
        hovered = nil
    }

    // MARK: Selection

    /// The most recently clicked selected item.
    var selected: FileNode? {
        if let anchor = selectionAnchor, selection[anchor.id] != nil { return anchor }
        return selection.values.first
    }

    var selectedNodes: [FileNode] { Array(selection.values) }

    func isSelected(_ node: FileNode) -> Bool { selection[node.id] != nil }

    /// Plain click: select just this item.
    func select(_ node: FileNode?) {
        selection = node.map { [$0.id: $0] } ?? [:]
        selectionAnchor = node
    }

    /// Command-click: add or remove one item.
    func toggleSelection(_ node: FileNode) {
        if selection.removeValue(forKey: node.id) == nil { selection[node.id] = node }
        selectionAnchor = node
    }

    /// Shift-click: select everything between the last clicked item and this one, in list order.
    func selectRange(to node: FileNode, in ordered: [FileNode]) {
        guard let anchor = selectionAnchor,
              let a = ordered.firstIndex(where: { $0 === anchor }),
              let b = ordered.firstIndex(where: { $0 === node })
        else { return select(node) }
        selection = Dictionary(uniqueKeysWithValues: ordered[min(a, b)...max(a, b)].map { ($0.id, $0) })
    }

    /// Rubber-band selection: replaces the selection, or adds to `base` when Command is held.
    func setSelection(_ nodes: [FileNode], adding base: [ObjectIdentifier: FileNode] = [:]) {
        var result = base
        for node in nodes { result[node.id] = node }
        selection = result
        if let first = nodes.first { selectionAnchor = first }
    }

    func clearSelection() {
        selection = [:]
        selectionAnchor = nil
    }

    func goUp() {
        if let parent = focus?.parent { navigate(to: parent) }
    }

    /// Finds the node for a path on disk, e.g. for items dropped onto the Collector.
    func node(atPath rawPath: String) -> FileNode? {
        guard let root else { return nil }
        let path = (rawPath as NSString).standardizingPath
        var candidates = [path]
        // Finder hands out firmlinked paths such as /Users/…, which live on the data volume.
        if source.isStartupDisk, !path.hasPrefix(ScanEngine.dataVolumePath + "/") {
            candidates.insert(ScanEngine.dataVolumePath + path, at: 0)
        }
        let bases = ([root] + root.children.filter { $0.basePath != nil })
            .sorted { $0.path.count > $1.path.count }
        for candidate in candidates {
            for base in bases {
                let basePath = base.path
                if candidate == basePath { return base }
                let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
                guard candidate.hasPrefix(prefix) else { continue }
                var node: FileNode? = base
                for component in candidate.dropFirst(prefix.count).split(separator: "/") {
                    node = node?.child(named: String(component))
                }
                if let node { return node }
            }
        }
        return nil
    }

    // MARK: Collector

    var collectedSize: Int64 { collected.reduce(0) { $0 + $1.size } }

    func isCollected(_ node: FileNode) -> Bool {
        collected.contains { $0 === node || node.isDescendant(of: $0) }
    }

    func collect(_ node: FileNode) {
        guard node.isRealItem, !isCollected(node) else { return }
        collected.removeAll { $0.isDescendant(of: node) }
        collected.append(node)
        collectedWithinCache = nil
    }

    /// Collects dropped items. Dropping one item of a multi-selection collects the whole selection,
    /// since a drag carries only the item under the pointer.
    func collect(urls: [URL]) {
        let nodes = urls.compactMap { node(atPath: $0.path) }
        if nodes.contains(where: isSelected) { collectSelection() }
        for node in nodes { collect(node) }
    }

    func collectSelection() {
        for node in selection.values where node.isRealItem { collect(node) }
    }

    func uncollect(_ node: FileNode) {
        collected.removeAll { $0 === node }
        collectedWithinCache = nil
    }

    func clearCollector() {
        collected.removeAll()
        collectedWithinCache = nil
    }

    /// Bytes of collected items inside `node` (including `node` itself when it is collected).
    func collectedBytes(in node: FileNode) -> Int64 {
        let items = collected  // registers the observation dependency
        if collectedWithinCache == nil {
            var totals: [ObjectIdentifier: Int64] = [:]
            for item in items {
                var current: FileNode? = item
                while let n = current {
                    totals[n.id, default: 0] += item.size
                    current = n.parent
                }
            }
            collectedWithinCache = totals
        }
        return collectedWithinCache?[node.id] ?? 0
    }

    /// Size of `node` once everything collected inside it is deleted.
    func remainingSize(of node: FileNode) -> Int64 {
        node.size - collectedBytes(in: node)
    }

    /// Moves collected items to the Trash (or removes them outright) and prunes them from the tree.
    func deleteCollected(moveToTrash: Bool) async {
        let items = collected
        guard !items.isEmpty, !isDeleting else { return }
        isDeleting = true
        deletionFailures = []
        var freed: Int64 = 0
        for item in items {
            let url = item.url
            do {
                try await Task.detached(priority: .userInitiated) {
                    if moveToTrash {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    } else {
                        try FileManager.default.removeItem(at: url)
                    }
                }.value
                freed += item.size
                item.removeFromParent()
            } catch {
                deletionFailures.append(item.name)
            }
        }
        collected.removeAll { $0.isDeleted }
        collectedWithinCache = nil
        backStack.removeAll { !$0.isAlive }
        forwardStack.removeAll { !$0.isAlive }
        while let focus, !focus.isAlive, let parent = focus.parent { self.focus = parent }
        hovered = nil
        clearSelection()
        if !moveToTrash {
            freeSpace += freed
            freeAndPurgeable += freed
        }
        lastDeleteMovedToTrash = moveToTrash
        lastFreed = freed > 0 ? freed : nil
        isDeleting = false
        revision += 1
    }

    // MARK: Export

    func exportCSV(of node: FileNode, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = "Path,Size (bytes),Type\n"
        var stack: [(FileNode, String)] = [(node, node.path)]
        while let (current, path) = stack.popLast() {
            let type = current.isDirectory ? "Folder" : (current.isSpecial ? "Other" : "File")
            buffer += "\"\(path.replacingOccurrences(of: "\"", with: "\"\""))\",\(current.size),\(type)\n"
            if buffer.utf8.count > 1 << 20 {
                try handle.write(contentsOf: Data(buffer.utf8))
                buffer = ""
            }
            for child in current.children.reversed() {
                let childPath = child.basePath ?? (path.hasSuffix("/") ? path + child.name : path + "/" + child.name)
                stack.append((child, childPath))
            }
        }
        try handle.write(contentsOf: Data(buffer.utf8))
    }
}
