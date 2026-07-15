// UninstallApp.swift - MacPulse Uninstall: removes an app AND its leftovers.
// Drop an app (or pick one), it resolves the bundle ID and finds every
// associated file in the standard per-user locations: Application Support,
// Caches, Preferences, Containers, Group Containers, Saved State, WebKit,
// HTTPStorages, LaunchAgents, Logs. Everything goes to the Trash - recoverable,
// never hard-deleted. Matching is conservative: bundle-ID prefix or exact
// (case-insensitive) app-name match only.
// Build: see build_uninstall.sh

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct Leftover: Identifiable {
    let id: String        // path
    let url: URL
    let kind: String      // which Library area it was found in
    var size: Int64
    var selected: Bool = true
}

struct TargetApp {
    let url: URL
    let name: String
    let bundleID: String
    let icon: NSImage
    let size: Int64
}

func dirSize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize ?? 0)
    }
    var total: Int64 = 0
    guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                 options: [], errorHandler: { _, _ in true }) else { return 0 }
    for case let f as URL in en {
        if let s = (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize {
            total += Int64(s)
        }
    }
    return total
}

func fmtBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: n)
}

/// Conservative match: item name equals/prefixes the bundle ID, or equals the
/// app name exactly (case-insensitive). Never substring-matches short names.
func matches(itemName: String, bundleID: String, appName: String) -> Bool {
    let item = itemName.lowercased()
    let bid = bundleID.lowercased()
    let name = appName.lowercased()
    if item == bid || item.hasPrefix(bid + ".") { return true }
    // "com.foo.Bar.plist", "com.foo.Bar.savedState" etc.
    if item.hasPrefix(bid) {
        let rest = item.dropFirst(bid.count)
        if rest.isEmpty || rest.first == "." { return true }
    }
    // exact folder named after the app ("Google Chrome")
    if item == name { return true }
    // group containers: "XXXXXXXX.com.foo.bar"
    if item.contains("." + bid) { return true }
    return false
}

func findLeftovers(bundleID: String, appName: String) -> [Leftover] {
    let fm = FileManager.default
    let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    // (directory to search, human label, search depth is direct children only)
    let areas: [(String, String)] = [
        ("Application Support", "Application Support"),
        ("Caches", "Caches"),
        ("Preferences", "Preferences"),
        ("Containers", "Containers"),
        ("Group Containers", "Group Containers"),
        ("Saved Application State", "Saved State"),
        ("WebKit", "WebKit"),
        ("HTTPStorages", "HTTP Storage"),
        ("LaunchAgents", "Launch Agents"),
        ("Logs", "Logs"),
        ("Application Scripts", "App Scripts"),
    ]
    var found: [Leftover] = []
    for (rel, label) in areas {
        let dir = lib.appendingPathComponent(rel)
        guard let children = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { continue }
        for child in children
        where matches(itemName: child.lastPathComponent, bundleID: bundleID, appName: appName) {
            found.append(Leftover(
                id: child.path, url: child, kind: label, size: dirSize(child)))
        }
    }
    return found.sorted { $0.size > $1.size }
}

// MARK: - View model

final class UninstallModel: ObservableObject {
    @Published var target: TargetApp? = nil
    @Published var leftovers: [Leftover] = []
    @Published var removeAppItself = true
    @Published var scanning = false
    @Published var working = false
    @Published var status: String? = nil
    @Published var appIsRunning = false

    var selectedTotal: Int64 {
        var t = leftovers.filter { $0.selected }.map { $0.size }.reduce(0, +)
        if removeAppItself, let app = target { t += app.size }
        return t
    }
    var selectedCount: Int {
        leftovers.filter { $0.selected }.count + (removeAppItself && target != nil ? 1 : 0)
    }

    func load(appURL: URL) {
        guard appURL.pathExtension == "app",
              let bundle = Bundle(url: appURL),
              let bid = bundle.bundleIdentifier else {
            status = "That doesn't look like an app bundle."
            return
        }
        let name = appURL.deletingPathExtension().lastPathComponent
        scanning = true
        status = nil
        leftovers = []
        appIsRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bid }
        DispatchQueue.global(qos: .userInitiated).async {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            let appSize = dirSize(appURL)
            let items = findLeftovers(bundleID: bid, appName: name)
            DispatchQueue.main.async {
                self.target = TargetApp(
                    url: appURL, name: name, bundleID: bid, icon: icon, size: appSize)
                self.leftovers = items
                self.scanning = false
            }
        }
    }

    func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the app to uninstall"
        if panel.runModal() == .OK, let url = panel.url {
            load(appURL: url)
        }
    }

    /// Move the app and selected leftovers to the Trash.
    func uninstall() {
        guard let app = target, !working else { return }
        working = true
        status = nil
        let items = leftovers.filter { $0.selected }.map { $0.url }
        let includeApp = removeAppItself
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var trashed = 0, failed: [String] = []
            var urls = items
            if includeApp { urls.append(app.url) }
            for url in urls {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    trashed += 1
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            DispatchQueue.main.async {
                self.working = false
                if failed.isEmpty {
                    self.status = "Moved \(trashed) item\(trashed == 1 ? "" : "s") to Trash."
                    self.leftovers = []
                    self.target = nil
                } else {
                    self.status = "Trashed \(trashed); couldn't move: \(failed.joined(separator: ", "))"
                    if let t = self.target { self.load(appURL: t.url) }
                }
            }
        }
    }
}

// MARK: - Views

struct DropZone: View {
    let model: UninstallModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app.dashed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
            Text("Drop an app here")
                .font(.system(size: 15, weight: .semibold))
            Text("or")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("Choose from Applications…") { model.pickApp() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .padding(20))
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                var url: URL? = nil
                if let d = data as? Data {
                    url = URL(dataRepresentation: d, relativeTo: nil)
                } else if let u = data as? URL {
                    url = u
                }
                if let u = url {
                    DispatchQueue.main.async { model.load(appURL: u) }
                }
            }
            return true
        }
    }
}

struct ContentView: View {
    @StateObject var model = UninstallModel()
    @State private var confirmUninstall = false

    var body: some View {
        Group {
            if let app = model.target {
                VStack(spacing: 0) {
                    // header
                    HStack(spacing: 12) {
                        Image(nsImage: app.icon)
                            .resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.system(size: 15, weight: .semibold))
                            Text(app.bundleID)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if model.appIsRunning {
                                Text("⚠ App is currently running - quit it first")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Choose Different App…") { model.pickApp() }
                    }
                    .padding(14)
                    Divider()

                    // items
                    ScrollView {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Toggle("", isOn: $model.removeAppItself)
                                    .toggleStyle(.checkbox).labelsHidden()
                                Image(systemName: "app.fill")
                                    .foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("The app itself")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(app.url.path)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(fmtBytes(app.size))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            Divider().padding(.leading, 54)

                            if model.scanning {
                                ProgressView("Scanning for leftovers…")
                                    .controlSize(.small).padding(30)
                            } else if model.leftovers.isEmpty {
                                Text("No leftover files found - this app is tidy.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .padding(30)
                            }

                            ForEach($model.leftovers) { $item in
                                HStack(spacing: 12) {
                                    Toggle("", isOn: $item.selected)
                                        .toggleStyle(.checkbox).labelsHidden()
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(item.url.lastPathComponent)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1).truncationMode(.middle)
                                            Text(item.kind)
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                                .background(Color.secondary.opacity(0.12))
                                                .foregroundStyle(.secondary)
                                                .clipShape(Capsule())
                                        }
                                        Text(item.url.path)
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(fmtBytes(item.size))
                                        .font(.system(size: 12).monospacedDigit())
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                        .help("Reveal in Finder")
                                }
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                Divider().padding(.leading, 54)
                            }
                        }
                    }

                    Divider()
                    // footer
                    HStack {
                        if let status = model.status {
                            Text(status).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("Selected: \(fmtBytes(model.selectedTotal))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            confirmUninstall = true
                        } label: {
                            Label(model.working ? "Working…" : "Move to Trash",
                                  systemImage: "trash")
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.working || model.scanning || model.selectedCount == 0)
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 0) {
                    DropZone(model: model)
                    if let status = model.status {
                        Text(status).font(.system(size: 11))
                            .foregroundStyle(.secondary).padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(minWidth: 580, minHeight: 460)
        .confirmationDialog(
            "Move \(model.selectedCount) items (\(fmtBytes(model.selectedTotal))) to Trash?",
            isPresented: $confirmUninstall, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything goes to the Trash - you can restore items from there until you empty it.")
        }
    }
}

@main
struct MacPulseUninstallApp: App {
    var body: some Scene {
        WindowGroup("MacPulse Uninstall") {
            ContentView()
        }
    }
}
