import SwiftUI

/// Picks regenerable files to clean. Nothing is deleted here: the choice goes into the Collector,
/// where it can be reviewed before Move to Trash.
struct CleanupSheet: View {
    let session: ScanSession
    @Environment(\.dismiss) private var dismiss

    @State private var categories: [CleanupCategory] = []
    @State private var chosen: Set<String> = []
    @State private var expanded: Set<String> = []

    private var chosenSize: Int64 {
        categories.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up Caches").font(.title2.weight(.semibold))
                    Text("Pick what to collect. Nothing is deleted until you review the Collector and click Move to Trash.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    if categories.isEmpty {
                        ContentUnavailableView("No caches found", systemImage: "checkmark.circle",
                                               description: Text("There's nothing to clean up in the scanned folders."))
                            .padding(.top, 40)
                    }
                    ForEach(categories) { category in
                        CategoryCard(category: category,
                                     isChosen: chosen.contains(category.id),
                                     isExpanded: expanded.contains(category.id),
                                     toggle: { toggle(category.id, in: &chosen) },
                                     toggleExpanded: { toggle(category.id, in: &expanded) })
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Format.bytes(chosenSize)).font(.headline).monospacedDigit()
                    Text("selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Collector", systemImage: "tray.and.arrow.down") { collect() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenSize == 0)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 600, height: 620)
        .onAppear {
            categories = CacheCleanup.categories(in: session)
            chosen = Set(categories.filter(\.selectedByDefault).map(\.id))
        }
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func collect() {
        for category in categories where chosen.contains(category.id) {
            for item in category.items { session.collect(item) }
        }
        dismiss()
    }
}

private struct CategoryCard: View {
    let category: CleanupCategory
    let isChosen: Bool
    let isExpanded: Bool
    var toggle: () -> Void
    var toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: Binding(get: { isChosen }, set: { _ in toggle() })) {
                    Text(category.title).font(.headline)
                }
                .toggleStyle(.checkbox)
                SafetyBadge(safety: category.safety)
                Spacer()
                Text(Format.bytes(category.size)).font(.headline).monospacedDigit()
            }
            Text(category.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)
            Button(isExpanded ? "Hide items" : "Show \(category.items.count) item\(category.items.count == 1 ? "" : "s")",
                   action: toggleExpanded)
                .buttonStyle(.link)
                .font(.callout)
                .padding(.leading, 22)
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(category.items.sorted { $0.size > $1.size }.prefix(60)) { item in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.icon(for: item)).resizable().frame(width: 16, height: 16)
                            Text(item.name).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(Format.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                        .help(item.path)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(isChosen ? 0.07 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct SafetyBadge: View {
    let safety: CleanupCategory.Safety

    var body: some View {
        let (text, color): (String, Color) = safety == .safe ? ("Safe", .green) : ("Use care", .orange)
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
