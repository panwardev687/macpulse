// CleanApp.swift - MacPulse Clean: a safe storage cleaner for macOS.
// Scans known-safe cache/log locations, shows what's reclaimable per category,
// and deletes only what the user checks and confirms. Whitelist-only: it never
// touches paths it doesn't recognize.
// Build: see build_clean.sh

import SwiftUI

// MARK: - Model

struct CleanCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    /// true = macOS/apps rebuild this automatically; false = gone forever once deleted
    let regenerable: Bool
    /// directories whose *contents* are deleted (the directory itself is kept)
    let paths: [URL]
    var size: Int64? = nil          // nil while scanning
    var selected: Bool = false
    var accessDenied: Bool = false
}

func home(_ rel: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel)
}

func defaultCategories() -> [CleanCategory] {
    [
        CleanCategory(
            id: "caches", name: "App caches", icon: "internaldrive",
            detail: "~/Library/Caches - browsers, Spotify, pip, Homebrew. Apps rebuild these on demand.",
            regenerable: true, paths: [home("Library/Caches")], selected: true),
        CleanCategory(
            id: "logs", name: "Logs & diagnostics", icon: "doc.text.magnifyingglass",
            detail: "~/Library/Logs - crash reports and app logs that accumulate for years.",
            regenerable: true, paths: [home("Library/Logs")], selected: true),
        CleanCategory(
            id: "dev", name: "Developer caches", icon: "hammer",
            detail: "Xcode DerivedData, device support, npm and generic ~/.cache. First build after cleaning is slower.",
            regenerable: true,
            paths: [
                home("Library/Developer/Xcode/DerivedData"),
                home("Library/Developer/Xcode/iOS DeviceSupport"),
                home(".npm/_cacache"),
                home(".cache"),
            ],
            selected: true),
        CleanCategory(
            id: "trash", name: "Trash", icon: "trash",
            detail: "~/.Trash - files you already deleted. Emptying is permanent; review contents first.",
            regenerable: false, paths: [home(".Trash")]),
        CleanCategory(
            id: "iosbackup", name: "iOS device backups", icon: "iphone",
            detail: "Old iPhone/iPad backups from Finder syncs. NOT regenerable - keep unless the device is backed up elsewhere.",
            regenerable: false, paths: [home("Library/Application Support/MobileSync/Backup")]),
    ]
}

// MARK: - Disk / size helpers

func directorySize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var total: Int64 = 0
    guard let en = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
        options: [],
        errorHandler: { _, _ in true }
    ) else { return 0 }
    for case let f as URL in en {
        if let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let s = v.totalFileAllocatedSize {
            total += Int64(s)
        }
    }
    return total
}

func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: n)
}

struct DiskStats {
    var total: Int64 = 0
    var free: Int64 = 0
    var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

func readDiskStats() -> DiskStats {
    var s = DiskStats()
    let url = URL(fileURLWithPath: "/")
    if let v = try? url.resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]) {
        s.total = Int64(v.volumeTotalCapacity ?? 0)
        s.free = v.volumeAvailableCapacityForImportantUsage ?? 0
    }
    return s
}

// MARK: - Time Machine local snapshots

func listLocalSnapshots() -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    p.arguments = ["listlocalsnapshots", "/"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return [] }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    return out.split(separator: "\n").map(String.init)
        .filter { $0.contains("com.apple.TimeMachine") }
}

/// Ask Time Machine to purge local snapshots (reclaims purgeable space).
func thinLocalSnapshots() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    p.arguments = ["thinlocalsnapshots", "/", "9999999999999", "4"]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    guard (try? p.run()) != nil else { return "Could not run tmutil." }
    p.waitUntilExit()
    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let combined = (o + e).trimmingCharacters(in: .whitespacesAndNewlines)
    return combined.isEmpty ? "Done." : combined
}

// MARK: - View model

@MainActor
final class CleanModel: ObservableObject {
    @Published var categories = defaultCategories()
    @Published var disk = readDiskStats()
    @Published var scanning = false
    @Published var cleaning = false
    @Published var snapshotCount: Int? = nil
    @Published var statusMessage: String? = nil

    var selectedTotal: Int64 {
        categories.filter { $0.selected }.compactMap { $0.size }.reduce(0, +)
    }
    var selectedNames: [String] {
        categories.filter { $0.selected && ($0.size ?? 0) > 0 }.map { $0.name }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        statusMessage = nil
        disk = readDiskStats()
        for i in categories.indices { categories[i].size = nil }
        let cats = categories
        Task.detached(priority: .userInitiated) {
            let snaps = listLocalSnapshots().count
            var results: [(String, Int64, Bool)] = []
            let fm = FileManager.default
            for cat in cats {
                var size: Int64 = 0
                var denied = false
                for path in cat.paths where fm.fileExists(atPath: path.path) {
                    if !fm.isReadableFile(atPath: path.path) { denied = true; continue }
                    size += directorySize(path)
                }
                results.append((cat.id, size, denied))
                let snapshot = results
                await MainActor.run { [snapshot] in
                    for (id, s, d) in snapshot {
                        if let idx = self.categories.firstIndex(where: { $0.id == id }) {
                            self.categories[idx].size = s
                            self.categories[idx].accessDenied = d
                        }
                    }
                }
            }
            await MainActor.run {
                self.snapshotCount = snaps
                self.scanning = false
            }
        }
    }

    /// Delete the contents of every selected category. Items that fail (in use,
    /// permission denied) are skipped silently - never force anything.
    func cleanSelected() {
        guard !cleaning else { return }
        cleaning = true
        statusMessage = nil
        let targets = categories.filter { $0.selected }.flatMap { $0.paths }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var freed: Int64 = 0
            for dir in targets where fm.fileExists(atPath: dir.path) {
                guard let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                ) else { continue }
                for child in children {
                    let s = directorySize(child)
                    do {
                        try fm.removeItem(at: child)
                        freed += s
                    } catch { /* in use or protected - skip */ }
                }
            }
            let freedFinal = freed
            await MainActor.run {
                self.cleaning = false
                self.statusMessage = "Freed \(formatBytes(freedFinal))"
                self.scan()
            }
        }
    }

    func thinSnapshots() {
        statusMessage = nil
        Task.detached(priority: .userInitiated) {
            let msg = thinLocalSnapshots()
            let snaps = listLocalSnapshots().count
            await MainActor.run {
                self.snapshotCount = snaps
                self.statusMessage = msg
                self.disk = readDiskStats()
            }
        }
    }
}

// MARK: - Views

struct CategoryRow: View {
    @Binding var category: CleanCategory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $category.selected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: category.icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category.name).font(.system(size: 13, weight: .semibold))
                    if category.regenerable {
                        Text("SAFE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.18))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    } else {
                        Text("PERMANENT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(category.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if category.accessDenied {
                Text("needs Full Disk Access")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if let size = category.size {
                Text(formatBytes(size))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(size > 0 ? .primary : .tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
            Button {
                if let first = category.paths.first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                }) {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 6)
    }
}

struct ContentView: View {
    @StateObject var model = CleanModel()
    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            // header: disk usage
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.secondary)
                    Text("Macintosh HD").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(formatBytes(model.disk.free)) free of \(formatBytes(model.disk.total))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(model.disk.usedFraction > 0.85 ? Color.orange : Color.accentColor)
                            .frame(width: geo.size.width * model.disk.usedFraction)
                    }
                }
                .frame(height: 6)
                if model.disk.usedFraction > 0.85 {
                    Text("Disk is over 85% full - macOS performs best with 10-15% free.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)

            Divider()

            // categories
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($model.categories) { $cat in
                        CategoryRow(category: $cat)
                            .padding(.horizontal, 16)
                        Divider().padding(.leading, 66)
                    }

                    // Time Machine snapshots row
                    HStack(spacing: 12) {
                        Spacer().frame(width: 16)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Time Machine local snapshots")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("SAFE")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Color.green.opacity(0.18))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            }
                            Text("Hourly on-disk snapshots. Thinning asks macOS to purge them; your external backups are untouched.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let n = model.snapshotCount {
                            Text("\(n) snapshot\(n == 1 ? "" : "s")")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(n > 0 ? .primary : .tertiary)
                        }
                        Button("Thin") { model.thinSnapshots() }
                            .disabled((model.snapshotCount ?? 0) == 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.trailing, 16)
                }
            }

            Divider()

            // footer
            HStack {
                Button {
                    model.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.scanning || model.cleaning)

                if let msg = model.statusMessage {
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                Spacer()
                Text("Selected: \(formatBytes(model.selectedTotal))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    confirmClean = true
                } label: {
                    Label(
                        model.cleaning ? "Cleaning…" : "Clean Selected",
                        systemImage: "sparkles")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.scanning || model.cleaning || model.selectedTotal == 0)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { model.scan() }
        .confirmationDialog(
            "Delete \(formatBytes(model.selectedTotal)) from: \(model.selectedNames.joined(separator: ", "))?",
            isPresented: $confirmClean, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.cleanSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items marked SAFE are rebuilt automatically by macOS and apps. Items marked PERMANENT cannot be recovered.")
        }
    }
}

@main
struct MacPulseCleanApp: App {
    var body: some Scene {
        WindowGroup("MacPulse Clean") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
