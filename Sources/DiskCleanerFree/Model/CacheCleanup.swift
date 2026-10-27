import Foundation

/// A group of regenerable files (caches, logs) found in the scanned tree.
struct CleanupCategory: Identifiable {
    enum Safety {
        /// Rebuilt automatically; the only cost is a slower first launch.
        case safe
        /// Safe for your data, but costs time or downloads to rebuild.
        case caution
    }

    let id: String
    let title: String
    let detail: String
    let safety: Safety
    let selectedByDefault: Bool
    let items: [FileNode]

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Finds well-known cache locations in the user's home folder. Only per-user locations are listed:
/// system caches can break things and need administrator rights, and app data (Application Support,
/// Containers) is never treated as cache.
enum CacheCleanup {
    @MainActor
    static func categories(in session: ScanSession) -> [CleanupCategory] {
        let home = NSHomeDirectory()
        func node(_ relative: String) -> FileNode? { session.node(atPath: home + relative) }
        func contents(of relative: String, where include: (FileNode) -> Bool = { _ in true }) -> [FileNode] {
            (node(relative)?.children ?? []).filter { $0.isRealItem && $0.size > 0 && include($0) }
        }
        let isApple: (FileNode) -> Bool = { $0.name.hasPrefix("com.apple.") }

        let developerPaths = [
            "/.npm/_cacache", "/.bun/install/cache", "/.gradle/caches", "/.cargo/registry/cache",
            "/Library/Developer/Xcode/DerivedData", "/Library/Developer/CoreSimulator/Caches",
        ]

        let categories = [
            CleanupCategory(
                id: "app", title: "App caches",
                detail: "Temporary files apps keep in ~/Library/Caches, such as browser caches, thumbnails and update downloads. Apps rebuild them as needed, so the first launch afterwards can be a little slower. Quit the apps first.",
                safety: .safe, selectedByDefault: true,
                items: contents(of: "/Library/Caches") { !isApple($0) }),
            CleanupCategory(
                id: "logs", title: "Logs",
                detail: "Diagnostic logs in ~/Library/Logs. They're only useful when troubleshooting a problem.",
                safety: .safe, selectedByDefault: true,
                items: contents(of: "/Library/Logs")),
            CleanupCategory(
                id: "apple", title: "macOS caches",
                detail: "Caches of Apple apps and services in ~/Library/Caches. Safe for your data, but macOS recreates many of them right away, and some are protected and will be skipped.",
                safety: .caution, selectedByDefault: false,
                items: contents(of: "/Library/Caches", where: isApple)),
            CleanupCategory(
                id: "dev", title: "Developer caches",
                detail: "Package and build caches for npm, Bun, Gradle, Cargo, Xcode and the iOS Simulator. Your projects aren't touched; dependencies are downloaded or rebuilt the next time you build.",
                safety: .caution, selectedByDefault: false,
                items: developerPaths.compactMap(node).filter { $0.size > 0 }),
            CleanupCategory(
                id: "tools", title: "Tool caches (~/.cache)",
                detail: "Used by command-line tools and AI frameworks. It can hold large downloaded models (for example from Hugging Face) that would have to be downloaded again.",
                safety: .caution, selectedByDefault: false,
                items: contents(of: "/.cache")),
        ]
        return categories.filter { !$0.items.isEmpty }
    }

    /// Whether the scan covers the home folder, which is where every cleanup location lives.
    @MainActor
    static func isAvailable(in session: ScanSession) -> Bool {
        session.node(atPath: NSHomeDirectory()) != nil
    }
}
