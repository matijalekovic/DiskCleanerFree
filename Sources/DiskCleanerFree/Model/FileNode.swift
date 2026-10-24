import Foundation

/// One entry of the scanned tree. Kept deliberately small: a full disk can produce millions of these.
final class FileNode: Identifiable, @unchecked Sendable {
    enum Kind: UInt8 {
        case file, folder, package, symlink, restricted
        /// The sealed, read-only macOS system volume attached to the startup disk.
        case systemVolume
        /// Space used on the volume that the scan could not attribute to any file.
        case hidden
        /// Space macOS can reclaim on its own (caches, snapshots, evictable iCloud files).
        case purgeable
    }

    var name: String
    var kind: Kind
    /// Allocated bytes. Holds only the entry's own allocation until `finalizeTree()` sums the subtree.
    var size: Int64
    var fileCount: Int = 0
    var children: [FileNode] = []
    weak var parent: FileNode?
    /// Absolute path for nodes whose path is not `parent.path + name` (scan roots, the system volume).
    var basePath: String?
    var isDeleted = false

    init(name: String, kind: Kind, size: Int64 = 0) {
        self.name = name
        self.kind = kind
        self.size = size
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    var isDirectory: Bool {
        switch kind {
        case .folder, .package, .restricted, .systemVolume: true
        default: false
        }
    }

    var isSpecial: Bool { kind == .hidden || kind == .purgeable }
    var canNavigate: Bool { isDirectory && !children.isEmpty }
    /// Whether the item exists on disk and could be collected for deletion.
    var isRealItem: Bool { !isSpecial && kind != .systemVolume && parent != nil }

    var path: String {
        if let basePath { return basePath }
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// Path from the root down to and including this node.
    var lineage: [FileNode] {
        var result: [FileNode] = []
        var node: FileNode? = self
        while let n = node {
            result.append(n)
            node = n.parent
        }
        return result.reversed()
    }

    func isDescendant(of other: FileNode) -> Bool {
        var node = parent
        while let n = node {
            if n === other { return true }
            node = n.parent
        }
        return false
    }

    var isAlive: Bool {
        var node: FileNode? = self
        while let n = node {
            if n.isDeleted { return false }
            node = n.parent
        }
        return true
    }

    /// Sums sizes bottom-up, links parents and sorts children largest first.
    /// Recursive, so call it from a thread with a generous stack.
    func finalizeTree() {
        var total = size
        var count = (kind == .file || kind == .symlink) ? 1 : 0
        for child in children {
            child.parent = self
            child.finalizeTree()
            total += child.size
            count += child.fileCount
        }
        children.sort { $0.size > $1.size }
        size = total
        fileCount = count
    }

    /// Attaches an already finalized subtree and updates the totals of this node and its ancestors.
    func adopt(_ child: FileNode) {
        child.parent = self
        children.append(child)
        children.sort { $0.size > $1.size }
        var node: FileNode? = self
        while let n = node {
            n.size += child.size
            n.fileCount += child.fileCount
            node = n.parent
        }
    }

    /// Detaches the node after it was deleted from disk, subtracting its size from every ancestor.
    func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var node: FileNode? = parent
        while let n = node {
            n.size -= size
            n.fileCount -= fileCount
            node = n.parent
            node?.children.sort { $0.size > $1.size }
        }
        isDeleted = true
    }

    func child(named name: String) -> FileNode? {
        children.first { $0.name == name }
    }
}
