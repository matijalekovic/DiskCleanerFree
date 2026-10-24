import Darwin
import Foundation
import Synchronization

/// Live counters shared between the scanning threads and the UI.
final class ScanProgress: @unchecked Sendable {
    let files = Atomic<Int>(0)
    let bytes = Atomic<Int64>(0)
    let restricted = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let path = Mutex<String>("")

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
    func cancel() { cancelled.store(true, ordering: .relaxed) }

    var currentPath: String {
        get { path.withLock { $0 } }
        set { path.withLock { $0 = newValue } }
    }
}

/// Multi-threaded file system walker. The top two directory levels are listed up front and every
/// directory below that becomes an independent `fts` job, so large trees scan on all cores.
enum ScanEngine {
    static let dataVolumePath = "/System/Volumes/Data"
    private static let splitDepth = 2

    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcarchive", "pkg", "mpkg", "rtfd",
        "sparsebundle", "sparseimage", "dsym", "playground", "xcodeproj", "xcworkspace", "aplibrary",
        "lrdata", "lrlibrary", "theater", "photolibrary", "migratedphotolibrary",
    ]

    /// Scans a disk or folder. For the startup disk the writable data volume is scanned, and the
    /// sealed system volume is attached as a node of its own so firmlinked folders are not counted twice.
    static func scan(path: String, name: String, isStartupDisk: Bool, progress: ScanProgress) -> FileNode {
        guard isStartupDisk, FileManager.default.fileExists(atPath: dataVolumePath) else {
            return scanTree(path: path, name: name, progress: progress)
        }
        let root = scanTree(path: dataVolumePath, name: name, progress: progress)
        if !progress.isCancelled {
            let system = scanTree(path: "/", name: "macOS System", progress: progress, excluding: systemVolumeExclusions())
            system.kind = .systemVolume
            system.children.removeAll { $0.size == 0 }
            root.adopt(system)
        }
        return root
    }

    /// Paths on the system volume that are really the data volume (firmlinks) or other APFS volumes.
    /// They share the system volume's device number, so `FTS_XDEV` alone doesn't stop the walk.
    static func systemVolumeExclusions() -> Set<String> {
        var paths: Set<String> = ["/System/Volumes"]
        if let table = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) {
            for line in table.split(separator: "\n") {
                if let source = line.split(separator: "\t").first, source.hasPrefix("/") { paths.insert(String(source)) }
            }
        } else {
            paths.formUnion(["/Applications", "/Library", "/Users", "/Volumes", "/private", "/opt", "/cores", "/usr/local"])
        }
        return paths
    }

    static func scanTree(path: String, name: String, progress: ScanProgress, excluding excluded: Set<String> = []) -> FileNode {
        let root = FileNode(name: name, kind: .folder)
        root.basePath = path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            root.kind = .restricted
            return root
        }
        let context = Context(device: st.st_dev, progress: progress, excluded: excluded)
        var jobs: [Job] = []
        split(root, path: path, depth: 0, context: context, jobs: &jobs)
        runParallel(jobs, context: context)
        root.finalizeTree()
        return root
    }

    // MARK: - Internals

    private struct Job {
        let node: FileNode
        let path: String
    }

    private final class Context: @unchecked Sendable {
        let device: dev_t
        let progress: ScanProgress
        let excluded: Set<String>
        private let seenInodes = Mutex<Set<UInt64>>([])

        init(device: dev_t, progress: ScanProgress, excluded: Set<String>) {
            self.device = device
            self.progress = progress
            self.excluded = excluded
        }

        func fileNode(name: String, stat st: stat) -> FileNode {
            let type = st.st_mode & S_IFMT
            var size = Int64(st.st_blocks) * 512
            // Hard links share their blocks; count each inode only once.
            if type == S_IFREG, st.st_nlink > 1 {
                let isFirst = seenInodes.withLock { $0.insert(st.st_ino).inserted }
                if !isFirst { size = 0 }
            }
            progress.files.add(1, ordering: .relaxed)
            progress.bytes.add(size, ordering: .relaxed)
            return FileNode(name: name, kind: type == S_IFLNK ? .symlink : .file, size: size)
        }
    }

    private final class JobCursor: @unchecked Sendable {
        let next = Atomic<Int>(0)
    }

    static func kind(forDirectoryNamed name: String) -> FileNode.Kind {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .folder }
        let ext = name[name.index(after: dot)...].lowercased()
        return packageExtensions.contains(ext) ? .package : .folder
    }

    private static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private static func split(_ node: FileNode, path: String, depth: Int, context: Context, jobs: inout [Job]) {
        guard let dir = opendir(path) else {
            node.kind = .restricted
            context.progress.restricted.add(1, ordering: .relaxed)
            return
        }
        defer { closedir(dir) }
        context.progress.currentPath = path
        while let entry = readdir(dir) {
            var rawName = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &rawName) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name == "." || name == ".." { continue }
            let childPath = join(path, name)
            if context.excluded.contains(childPath) { continue }
            var st = stat()
            guard lstat(childPath, &st) == 0 else { continue }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                node.children.append(context.fileNode(name: name, stat: st))
                continue
            }
            let child = FileNode(name: name, kind: kind(forDirectoryNamed: name), size: Int64(st.st_blocks) * 512)
            node.children.append(child)
            // A different device means another volume is mounted here.
            guard st.st_dev == context.device else { continue }
            if depth + 1 < splitDepth {
                split(child, path: childPath, depth: depth + 1, context: context, jobs: &jobs)
            } else {
                jobs.append(Job(node: child, path: childPath))
            }
        }
    }

    private static func runParallel(_ jobs: [Job], context: Context) {
        guard !jobs.isEmpty else { return }
        let width = min(jobs.count, max(4, min(ProcessInfo.processInfo.activeProcessorCount * 2, 24)))
        let cursor = JobCursor()
        let group = DispatchGroup()
        for _ in 0..<width {
            group.enter()
            let thread = Thread {
                while !context.progress.isCancelled {
                    let index = cursor.next.add(1, ordering: .relaxed).oldValue
                    guard index < jobs.count else { break }
                    walk(jobs[index], context: context)
                }
                group.leave()
            }
            thread.stackSize = 4 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
    }

    /// Walks one directory subtree with `fts`, appending nodes under `job.node`.
    private static func walk(_ job: Job, context: Context) {
        let progress = context.progress
        guard let cPath = strdup(job.path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            job.node.kind = .restricted
            return
        }
        defer { fts_close(fts) }

        // stack[level] is the directory currently open at that depth.
        var stack: [FileNode] = [job.node]
        var tick = 0
        while let entry = fts_read(fts) {
            let e = entry.pointee
            let level = Int(e.fts_level)
            let info = Int32(e.fts_info)
            if level == 0 {
                if info == FTS_DNR || info == FTS_ERR {
                    job.node.kind = .restricted
                    progress.restricted.add(1, ordering: .relaxed)
                }
                continue
            }
            tick += 1
            if tick & 2047 == 0 {
                if progress.isCancelled { return }
                progress.currentPath = String(cString: e.fts_path)
            }
            if stack.count > level { stack.removeSubrange(level...) }
            guard stack.count == level else { continue }
            let parent = stack[level - 1]

            switch info {
            case FTS_D:
                if !context.excluded.isEmpty, context.excluded.contains(String(cString: e.fts_path)) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                let name = entryName(e)
                let child = FileNode(name: name, kind: kind(forDirectoryNamed: name),
                                     size: Int64(e.fts_statp.pointee.st_blocks) * 512)
                parent.children.append(child)
                stack.append(child)
            case FTS_DNR, FTS_ERR:
                let name = entryName(e)
                // fts reports an unreadable directory again after its FTS_D entry.
                if let last = parent.children.last, last.name == name, last.isDirectory {
                    last.kind = .restricted
                } else {
                    parent.children.append(FileNode(name: name, kind: .restricted))
                }
                progress.restricted.add(1, ordering: .relaxed)
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                parent.children.append(context.fileNode(name: entryName(e), stat: e.fts_statp.pointee))
            default:
                break
            }
        }
    }

    private static func entryName(_ e: FTSENT) -> String {
        String(cString: e.fts_path + (Int(e.fts_pathlen) - Int(e.fts_namelen)))
    }
}
