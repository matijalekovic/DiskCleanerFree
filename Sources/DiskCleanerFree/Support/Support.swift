import AppKit
import SwiftUI

enum Format {
    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String { bytesFormatter.string(fromByteCount: value) }

    /// Number and unit with a fixed single decimal, so live counters don't change width every tick.
    static func steadyBytes(_ value: Int64) -> (number: String, unit: String) {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(max(0, value))
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let number = index == 0 ? amount.formatted(.number.precision(.fractionLength(0)))
                                : amount.formatted(.number.precision(.fractionLength(1)))
        return (number, units[index])
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "" }
        let value = Double(part) / Double(whole)
        return value < 0.001 ? "<0.1%" : value.formatted(.percent.precision(.fractionLength(value < 0.1 ? 1 : 0)))
    }
}

enum Permissions {
    /// Probes a TCC-protected location; it is only readable with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Containers/com.apple.stocks",
            NSHomeDirectory() + "/Library/Safari",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            if probe.hasSuffix(".db") {
                if let handle = FileHandle(forReadingAtPath: probe) {
                    try? handle.close()
                    return true
                }
                return false
            }
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }
        return true
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        return c
    }()

    static func icon(for node: FileNode) -> NSImage {
        icon(forPath: node.path)
    }

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Settings shared by @AppStorage across views.
enum Prefs {
    static let chartDepth = "chartDepth"
    static let showFreeSpace = "showFreeSpace"
    static let moveToTrash = "moveToTrash"
    static let confirmDelete = "confirmDelete"
    static let colorfulFiles = "colorfulFiles"
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

extension FileNode {
    var kindDescription: String {
        switch kind {
        case .file: "File"
        case .symlink: "Alias"
        case .folder: "Folder"
        case .package: "Package"
        case .restricted: "Restricted folder"
        case .systemVolume: "Sealed system volume"
        case .hidden: "Hidden space"
        case .purgeable: "Purgeable space"
        }
    }

    var explanation: String? {
        switch kind {
        case .hidden:
            "Space in use that no scanned file accounts for: other APFS volumes in the same container (VM, Preboot, Recovery), Time Machine local snapshots, and folders that need extra permissions. Scanning as Administrator reveals more of it."
        case .purgeable:
            "Space macOS reclaims automatically when it's needed, such as caches, local snapshots and iCloud files that can be downloaded again. No action is required."
        case .restricted:
            "This folder couldn't be read. Grant Full Disk Access or scan as Administrator to see its contents."
        case .systemVolume:
            "macOS itself lives on a sealed, read-only volume. It can't be cleaned up."
        default:
            nil
        }
    }

    @MainActor
    var symbolName: String? {
        switch kind {
        case .hidden: "eye.slash"
        case .purgeable: "arrow.3.trianglepath"
        case .restricted: "lock.fill"
        default: nil
        }
    }
}
