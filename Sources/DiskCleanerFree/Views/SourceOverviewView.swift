import Charts
import SwiftUI

/// Shown for a disk or folder that hasn't been scanned yet (or whose scan failed).
struct SourceOverviewView: View {
    let item: SidebarItem
    let source: ScanSource
    let volume: VolumeInfo?
    let session: ScanSession?
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                header
                if let volume { CapacityCard(volume: volume) }
                actions
                if case .failed(let message) = session?.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 520)
                }
                if !model.hasFullDiskAccess { FullDiskAccessCard() }
                if source.isStartupDisk { SnapshotsCard() }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(source.name)
        .navigationSubtitle(volume.map { "\(Format.bytes($0.available)) available of \(Format.bytes($0.total))" } ?? source.path)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: source.path))
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Text(source.name).font(.largeTitle.weight(.semibold))
            Text(volume.map { [$0.format, $0.isReadOnly ? "Read-only" : nil].compactMap { $0 }.joined(separator: " · ") } ?? source.path)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(compact: false)
            actionRow(compact: true)
        }
    }

    private func actionRow(compact: Bool) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.scan(item)
                } label: {
                    Label("Scan", systemImage: "chart.pie.fill")
                        .frame(minWidth: compact ? 70 : 110)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    model.scan(item, asAdmin: true)
                } label: {
                    Label("Scan as Administrator", systemImage: "lock.open.fill")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .buttonStyle(.glass)
                .help("Also scans folders owned by the system and other users. Asks for your password.")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
                        .padding(.vertical, 1)  // icon alone is 2 pt shorter than the text buttons
                }
                .buttonStyle(.glass)
                .help("Show in Finder")
            }
            .font(.body.weight(.semibold))
            .controlSize(.extraLarge)
            .fixedSize()
        }
    }
}

/// Type-erased label style so the action row can switch styles.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Used / purgeable / free donut. Click a slice or a legend row to see what it means.
private struct CapacityCard: View {
    let volume: VolumeInfo

    /// Pinned by clicking a slice or a legend row; drives the explanation below the chart.
    @State private var selected: Kind?
    /// Slice under the pointer; previews it in the center without pinning anything.
    @State private var hovered: Kind?
    @State private var angle: Double?

    enum Kind: String, CaseIterable, Identifiable {
        case used = "Used", purgeable = "Purgeable", free = "Free"
        var id: String { rawValue }
    }

    private struct Slice: Identifiable {
        let kind: Kind
        let value: Int64
        let color: Color
        var id: Kind { kind }
    }

    private var slices: [Slice] {
        let purgeable = min(volume.purgeable, volume.used)
        return [
            Slice(kind: .used, value: volume.used - purgeable, color: .accentColor),
            Slice(kind: .purgeable, value: purgeable, color: .accentColor.opacity(0.45)),
            Slice(kind: .free, value: volume.available, color: .secondary.opacity(0.25)),
        ].filter { $0.value > 0 }
    }

    var body: some View {
        let slices = slices
        VStack(spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 36) { donut(slices); legend(slices) }
                VStack(spacing: 22) { donut(slices); legend(slices) }
            }
            if let selected, let slice = slices.first(where: { $0.kind == selected }) {
                detail(for: slice)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .animation(.snappy(duration: 0.25), value: selected)
        // Hover only previews. Toggling here made the center flicker between two labels.
        .onChange(of: angle) { _, value in hovered = value.flatMap { kind(at: $0, in: slices) } }
    }

    private func kind(at value: Double, in slices: [Slice]) -> Kind? {
        var running = 0.0
        for slice in slices {
            running += Double(slice.value)
            if value <= running { return slice.kind }
        }
        return slices.last?.kind
    }

    private func select(_ kind: Kind) {
        let next: Kind? = selected == kind ? nil : kind
        if selected != nil, next != nil {
            // Switching explanations: swap instantly so two paragraphs never overlap mid-fade.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { selected = next }
        } else {
            selected = next
        }
    }

    private func donut(_ slices: [Slice]) -> some View {
        let shown = hovered ?? selected
        return ZStack {
            Chart(slices) { slice in
                SectorMark(angle: .value("Bytes", Double(slice.value)), innerRadius: .ratio(0.66), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(slice.color)
                    .opacity(shown == nil || shown == slice.kind ? 1 : 0.35)
            }
            .chartLegend(.hidden)
            .chartAngleSelection(value: $angle)
            .onTapGesture { if let hovered { select(hovered) } }
            VStack(spacing: 0) {
                if let shown, let slice = slices.first(where: { $0.kind == shown }) {
                    Text(Format.bytes(slice.value))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(slice.kind.rawValue.lowercased()).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(volume.usedFraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("used").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsHitTesting(false)
            // Swap instantly: a crossfade here briefly shows both labels on top of each other.
            .transaction { $0.animation = nil }
        }
        .frame(width: 190, height: 190)
    }

    private func legend(_ slices: [Slice]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slices) { slice in
                Button { select(slice.kind) } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(slice.color).frame(width: 12, height: 12)
                        Text(slice.kind.rawValue)
                        Spacer(minLength: 24)
                        Text(Format.bytes(slice.value)).monospacedDigit().fontWeight(.medium)
                        Image(systemName: selected == slice.kind ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected == slice.kind ? Color.primary.opacity(0.08)
                              : hovered == slice.kind ? Color.primary.opacity(0.04) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 6)
            HStack {
                Text("Capacity").foregroundStyle(.secondary)
                Spacer()
                Text(Format.bytes(volume.total)).monospacedDigit()
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 270)
    }

    @ViewBuilder
    private func detail(for slice: Slice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch slice.kind {
            case .used:
                Text("Files, apps and the system on this disk. Scan it to see exactly what takes up the space, then collect what you don't need.")
            case .purgeable:
                Text("Space macOS frees on its own when it needs room: caches, local Time Machine snapshots and iCloud files that can be downloaded again. Apps can already use it, so there's nothing you need to do.")
            case .free:
                Text("Empty space, ready to use. Together with purgeable space, \(Format.bytes(volume.available + min(volume.purgeable, volume.used))) is available to apps.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct FullDiskAccessCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access is off").font(.headline)
                Text("Without it, protected folders like Mail, Messages and Safari data can't be measured. Turn it on in System Settings, then relaunch the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(.glass)
        }
        .padding(18)
        .frame(maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.tint(.orange.opacity(0.1)), in: .rect(cornerRadius: 22, style: .continuous))
    }
}

/// Time Machine local snapshots, shown only when there are any. They hold space that macOS
/// counts as purgeable and removes automatically.
private struct SnapshotsCard: View {
    @State private var snapshots: [String] = []

    var body: some View {
        Group {
            if !snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Time Machine Snapshots", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text("While Time Machine is on, macOS keeps hourly snapshots of your disk so you can restore files even when the backup drive isn't connected. They count as purgeable space and are deleted automatically after 24 hours or when space runs low.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(snapshots, id: \.self) { date in
                        Label(date, systemImage: "camera.aperture")
                            .font(.callout)
                            .monospacedDigit()
                    }
                }
                .padding(18)
                .frame(maxWidth: 560, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            }
        }
        .task { await load() }
    }

    private func load() async {
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            process.arguments = ["listlocalsnapshots", "/"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        // Names look like com.apple.TimeMachine.2026-10-24-120000.local
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd-HHmmss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        snapshots = output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("com.apple") else { return nil }
            let parts = line.split(separator: ".")
            if let stamp = parts.first(where: { $0.count == 17 && $0.first?.isNumber == true }),
               let date = parser.date(from: String(stamp)) {
                return date.formatted(date: .abbreviated, time: .shortened)
            }
            return String(line)
        }
    }
}
