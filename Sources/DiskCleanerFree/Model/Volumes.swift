import AppKit

struct VolumeInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let availableForImportantUsage: Int64
    let format: String
    let isStartupDisk: Bool
    let isEjectable: Bool
    let isReadOnly: Bool
    let isInternal: Bool

    var id: String { url.path }
    var path: String { url.path }
    var used: Int64 { max(0, total - available) }
    /// Space counted as used that macOS can free on demand.
    var purgeable: Int64 { max(0, availableForImportantUsage - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var purgeableFraction: Double { total > 0 ? Double(min(purgeable, used)) / Double(total) : 0 }

    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey,
        .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
    ]

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
              values.volumeIsBrowsable ?? true,
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        self.url = url
        self.isStartupDisk = url.path == "/"
        self.name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
        self.total = Int64(total)
        self.available = Int64(values.volumeAvailableCapacity ?? 0)
        self.availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? self.available
        self.format = values.volumeLocalizedFormatDescription ?? ""
        self.isEjectable = values.volumeIsEjectable ?? false
        self.isReadOnly = values.volumeIsReadOnly ?? false
        self.isInternal = values.volumeIsInternal ?? false
    }

    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                        options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(VolumeInfo.init(url:))
            .sorted { lhs, rhs in
                if lhs.isStartupDisk != rhs.isStartupDisk { return lhs.isStartupDisk }
                if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// The mounted volume that contains `path`.
    static func containing(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return VolumeInfo(url: volumeURL)
    }
}

/// What a scan session looks at: a whole disk or a single folder.
struct ScanSource: Hashable {
    let url: URL
    let name: String
    let isVolume: Bool
    let isStartupDisk: Bool

    var path: String { url.path }

    init(volume: VolumeInfo) {
        url = volume.url
        name = volume.name
        isVolume = true
        isStartupDisk = volume.isStartupDisk
    }

    init(folder url: URL) {
        self.url = url
        name = FileManager.default.displayName(atPath: url.path)
        isVolume = false
        isStartupDisk = false
    }
}
