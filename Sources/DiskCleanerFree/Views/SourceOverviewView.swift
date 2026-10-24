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
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    model.scan(item)
                } label: {
                    Label("Scan", systemImage: "chart.pie.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, compact ? 12 : 26)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)

                Button("Scan as Administrator", systemImage: "lock.open.fill") { model.scan(item, asAdmin: true) }
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .buttonStyle(.glass)
                    .help("Also scans folders owned by the system and other users. Asks for your password.")

                Button("Show in Finder", systemImage: "finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
            }
            .fixedSize()
            .controlSize(.extraLarge)
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

private struct CapacityCard: View {
    let volume: VolumeInfo

    private struct Slice: Identifiable {
        let name: String
        let value: Int64
        let color: Color
        var id: String { name }
    }

    var body: some View {
        let purgeable = min(volume.purgeable, volume.used)
        let slices = [
            Slice(name: "Used", value: volume.used - purgeable, color: .accentColor),
            Slice(name: "Purgeable", value: purgeable, color: .accentColor.opacity(0.45)),
            Slice(name: "Free", value: volume.available, color: .secondary.opacity(0.2)),
        ].filter { $0.value > 0 }

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 36) { donut(slices); legend(slices) }
            VStack(spacing: 22) { donut(slices); legend(slices) }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
    }

    private func donut(_ slices: [Slice]) -> some View {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Bytes", slice.value), innerRadius: .ratio(0.66), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(slice.color)
                }
                .chartLegend(.hidden)
                VStack(spacing: 0) {
                    Text(volume.usedFraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("used").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
    }

    private func legend(_ slices: [Slice]) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(slice.color).frame(width: 12, height: 12)
                        Text(slice.name)
                        Spacer(minLength: 24)
                        Text(Format.bytes(slice.value)).monospacedDigit().fontWeight(.medium)
                    }
                }
                Divider()
                HStack {
                    Text("Capacity").foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.bytes(volume.total)).monospacedDigit()
                }
            }
            .frame(width: 240)
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

/// Lists APFS local snapshots, which hold space that shows up as purgeable or hidden.
private struct SnapshotsCard: View {
    @State private var snapshots: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Local Snapshots", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if let snapshots {
                if snapshots.isEmpty {
                    Text("There are currently no snapshots.").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots, id: \.self) { name in
                        Text(name).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("Snapshots are temporary backups managed by macOS and Time Machine. macOS removes them automatically when space runs low; `tmutil deletelocalsnapshots /` removes them now.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
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
        snapshots = output.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("com.apple") }
    }
}
