import SwiftUI

struct DiskCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Disk Cleaner Free", id: "main") {
            ContentView()
                .environment(model)
                .onOpenURL { model.open($0) }
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Launch arguments for layout checks: `-WindowSize 820x560` opens the window at that size,
    /// `-ScanPath <folder>` scans a folder right away, and `-CollectPaths a,b` puts those items in the
    /// Collector once the scan is done.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "ScanPath") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self.model?.open(URL(fileURLWithPath: path)) }
            }
        }
        if let paths = defaults.string(forKey: "CollectPaths") {
            let urls = paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let session = self.model?.sessions.values.first(where: { $0.state == .done }) else { return }
                    session.collect(urls: urls)
                    timer.invalidate()
                }
            }
        }
        let parts = (UserDefaults.standard.string(forKey: "WindowSize") ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            var frame = window.frame
            frame.origin.y += frame.height - parts[1]
            frame.size = NSSize(width: parts[0], height: parts[1])
            window.setFrame(frame, display: true)
        }
    }

    /// Folders dropped onto the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { model?.open(url) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model else { return .terminateNow }
            let scanning = model.sessions.values.contains { $0.state == .scanning }
            let collected = model.sessions.values.contains { !$0.collected.isEmpty }
            guard scanning || collected else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = scanning ? "A scan is in progress" : "There are files collected but not deleted"
            alert.informativeText = scanning
                ? "If you quit now, the scan will not be completed."
                : "If you quit now, the Collector will be emptied."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.scanSession) private var session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Button("Rescan") {
                if let session { session.start() } else if let item = model.selection { model.scan(item) }
            }
            .keyboardShortcut("r")
            Button("Rescan as Administrator") {
                if let session { session.start(asAdmin: true) } else if let item = model.selection { model.scan(item, asAdmin: true) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Back") { session?.goBack() }
                .keyboardShortcut("[")
                .disabled(session?.canGoBack != true)
            Button("Forward") { session?.goForward() }
                .keyboardShortcut("]")
                .disabled(session?.canGoForward != true)
            Button("Enclosing Folder") { session?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(session?.canGoUp != true)
            Button("Top Level") { if let root = session?.root { session?.navigate(to: root) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(session?.canGoUp != true)
            Divider()
            Button("Move Selection to Collector") { session?.collectSelection() }
                .keyboardShortcut("k")
                .disabled(session?.selectedNodes.contains(where: \.isRealItem) != true)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.moveToTrash) private var moveToTrash = true
    @AppStorage(Prefs.confirmDelete) private var confirmDelete = true
    @AppStorage(Prefs.chartDepth) private var chartDepth = 6
    @AppStorage(Prefs.showFreeSpace) private var showFreeSpace = false
    @AppStorage(Prefs.colorfulFiles) private var colorfulFiles = false

    var body: some View {
        Form {
            Section("Deleting") {
                Picker("Collected items are", selection: $moveToTrash) {
                    Text("Moved to the Trash").tag(true)
                    Text("Deleted immediately").tag(false)
                }
                Toggle("Ask before deleting", isOn: $confirmDelete)
            }
            Section("Map") {
                Stepper("Rings: \(chartDepth)", value: $chartDepth, in: 3...10)
                Toggle("Show free space on the map", isOn: $showFreeSpace)
                Toggle("Tint files with their folder's color", isOn: $colorfulFiles)
            }
            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(model.hasFullDiskAccess ? "Granted" : "Not granted")
                            .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                        Button("Open Settings…") { Permissions.openFullDiskAccessSettings() }
                    }
                }
                Text("Full Disk Access lets the app measure protected folders. Scanning as Administrator additionally reveals files owned by the system and other users.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
