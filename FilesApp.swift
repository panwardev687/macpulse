// FilesApp.swift - MacPulse Files: duplicate & large file finder.
// Scans your user folders (Desktop, Documents, Downloads, Movies, Music,
// Pictures) - never ~/Library or system paths. Two views:
//   Large Files: top 100 by size, with last-opened date.
//   Duplicates: same size + same SHA-256 of first 4 MB, grouped, sorted by
//               wasted space. "Auto-select older copies" keeps the newest.
// Deletion always goes to the Trash, always behind a confirmation.
// Build: see build_files.sh

import SwiftUI
import CryptoKit
import QuickLook

// MARK: - Model

struct FileEntry: Identifiable {
    let id: String
    let url: URL
    let size: Int64
    let lastOpened: Date?
    let modified: Date?
    var selected: Bool = false
}

struct DupGroup: Identifiable {
    let id: String
    var files: [FileEntry]
    var size: Int64 { files.first?.size ?? 0 }
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

func fmtSize(_ n: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: n)
}

func fmtDate(_ d: Date?) -> String {
    guard let d else { return "-" }
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
    return f.string(from: d)
}

func defaultRoots() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
        .map { home.appendingPathComponent($0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
}

/// SHA-256 of the first 4 MB - enough to distinguish same-size files reliably.
func partialHash(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty
    else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func collectFiles(roots: [URL]) -> [FileEntry] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
        .contentAccessDateKey, .contentModificationDateKey,
    ]
    var out: [FileEntry] = []
    for root in roots {
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }) else { continue }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true,
                  let size = v.totalFileAllocatedSize, size > 0 else { continue }
            out.append(FileEntry(
                id: url.path, url: url, size: Int64(size),
                lastOpened: v.contentAccessDate, modified: v.contentModificationDate))
        }
    }
    return out
}

func findDuplicates(in files: [FileEntry]) -> [DupGroup] {
    // candidates: same size, ≥ 1 MB
    var bySize: [Int64: [FileEntry]] = [:]
    for f in files where f.size >= 1_048_576 {
        bySize[f.size, default: []].append(f)
    }
    var groups: [DupGroup] = []
    for (size, candidates) in bySize where candidates.count > 1 {
        var byHash: [String: [FileEntry]] = [:]
        for f in candidates {
            guard let h = partialHash(f.url) else { continue }
            byHash[h, default: []].append(f)
        }
        for (hash, dups) in byHash where dups.count > 1 {
            let sorted = dups.sorted {
                ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
            }
            groups.append(DupGroup(id: "\(size)-\(hash)", files: sorted))
        }
    }
    return groups.sorted { $0.wasted > $1.wasted }.prefix(100).map { $0 }
}

// MARK: - View model

final class FilesModel: ObservableObject {
    @Published var largeFiles: [FileEntry] = []
    @Published var dupGroups: [DupGroup] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var status: String? = nil
    @Published var roots: [URL] = defaultRoots()
    @Published var selectedPath: String? = nil
    @Published var previewURL: URL? = nil
    @Published var tab = 0
    private var keyMonitor: Any?

    /// files visible in the current tab, in display order
    var currentURLs: [URL] {
        tab == 0 ? largeFiles.map { $0.url }
                 : dupGroups.flatMap { $0.files.map { $0.url } }
    }

    init() {
        // Finder-style Quick Look: Space previews the selected row, Space/Esc
        // closes. ↑/↓ move the selection - also while the preview is open, so
        // you can flip through files without leaving the panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 49:  // Space
                if self.previewURL != nil {
                    self.previewURL = nil
                    return nil
                }
                if let sel = self.selectedPath {
                    self.previewURL = URL(fileURLWithPath: sel)
                    return nil
                }
                return event
            case 125, 126:  // ↓, ↑
                let urls = self.currentURLs
                guard !urls.isEmpty,
                      self.selectedPath != nil || self.previewURL != nil
                else { return event }
                let idx = urls.firstIndex { $0.path == self.selectedPath } ?? -1
                let next = event.keyCode == 125
                    ? min(idx + 1, urls.count - 1)
                    : max(idx - 1, 0)
                let url = urls[next]
                self.selectedPath = url.path
                if self.previewURL != nil { self.previewURL = url }
                return nil
            default:
                return event
            }
        }
    }

    var selectedLarge: [FileEntry] { largeFiles.filter { $0.selected } }
    var selectedDups: [FileEntry] { dupGroups.flatMap { $0.files.filter { $0.selected } } }
    var selectedTotal: Int64 {
        (selectedLarge + selectedDups).map { $0.size }.reduce(0, +)
    }
    var selectedCount: Int { selectedLarge.count + selectedDups.count }
    var totalWasted: Int64 { dupGroups.map { $0.wasted }.reduce(0, +) }

    func scan() {
        guard !scanning else { return }
        scanning = true
        status = nil
        selectedPath = nil
        previewURL = nil
        progress = "Listing files…"
        let roots = self.roots
        DispatchQueue.global(qos: .userInitiated).async {
            let all = collectFiles(roots: roots)
            DispatchQueue.main.async { self.progress = "Hashing \(all.count) files for duplicates…" }
            let large = all.sorted { $0.size > $1.size }.prefix(100).map { $0 }
            let dups = findDuplicates(in: all)
            DispatchQueue.main.async {
                self.largeFiles = large
                self.dupGroups = dups
                self.scanning = false
                self.progress = ""
            }
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to scan"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            roots = panel.urls
            scan()
        }
    }

    /// In every duplicate group, select all copies except the most recent.
    func autoSelectOlder() {
        for g in dupGroups.indices {
            for i in dupGroups[g].files.indices {
                dupGroups[g].files[i].selected = (i != 0)  // files sorted newest-first
            }
        }
    }

    func trashSelected() {
        let urls = (selectedLarge + selectedDups).map { $0.url }
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var ok = 0, failed = 0
            for url in urls {
                do { try fm.trashItem(at: url, resultingItemURL: nil); ok += 1 }
                catch { failed += 1 }
            }
            DispatchQueue.main.async {
                self.status = failed == 0
                    ? "Moved \(ok) file\(ok == 1 ? "" : "s") to Trash."
                    : "Trashed \(ok); \(failed) could not be moved."
                self.scan()
            }
        }
    }
}

// MARK: - Views

struct FileRow: View {
    @Binding var file: FileEntry
    var subtitle: String
    var isSelected: Bool = false
    var select: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $file.selected).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(fmtSize(file.size))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help("Click to select, press Space to Quick Look")
    }
}

struct ContentView: View {
    @StateObject var model = FilesModel()
    @State private var confirmTrash = false

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Picker("", selection: $model.tab) {
                    Text("Large Files").tag(0)
                    Text("Duplicates" + (model.dupGroups.isEmpty ? "" :
                        "  (\(fmtSize(model.totalWasted)) wasted)")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text(model.progress).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button("Choose Folders…") { model.pickFolder() }
                    .disabled(model.scanning)
                Button {
                    model.scan()
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
            }
            .padding(12)
            Text("Scanning: " + model.roots.map { $0.lastPathComponent }.joined(separator: ", ")
                 + "   ·   click a file, Space to Quick Look, ↑↓ to move through files")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 8)
            Divider()

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if model.tab == 0 {
                        ForEach($model.largeFiles) { $f in
                            FileRow(file: $f, subtitle:
                                "\(f.url.deletingLastPathComponent().path)  ·  last opened \(fmtDate(f.lastOpened))",
                                isSelected: model.selectedPath == f.id,
                                select: { model.selectedPath = f.id })
                                .padding(.horizontal, 14)
                                .id(f.id)
                            Divider().padding(.leading, 60)
                        }
                        if model.largeFiles.isEmpty && !model.scanning {
                            Text("No files found - run a scan.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(40)
                        }
                    } else {
                        if !model.dupGroups.isEmpty {
                            HStack {
                                Button("Auto-select older copies (keep newest)") {
                                    model.autoSelectOlder()
                                }
                                .controlSize(.small)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        ForEach($model.dupGroups) { $group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(group.files.count) copies · \(fmtSize(group.size)) each · \(fmtSize(group.wasted)) wasted")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.06))
                                ForEach($group.files) { $f in
                                    FileRow(file: $f, subtitle:
                                        "\(f.url.deletingLastPathComponent().path)  ·  modified \(fmtDate(f.modified))",
                                        isSelected: model.selectedPath == f.id,
                                        select: { model.selectedPath = f.id })
                                        .padding(.horizontal, 14)
                                        .id(f.id)
                                    Divider().padding(.leading, 60)
                                }
                            }
                        }
                        if model.dupGroups.isEmpty && !model.scanning {
                            Text("No duplicates found (files ≥ 1 MB with identical content).")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(40)
                        }
                    }
                }
            }
            .onChange(of: model.selectedPath) { sel in
                // keep the highlighted row visible while arrowing through files
                if let sel { withAnimation { proxy.scrollTo(sel) } }
            }
            }

            Divider()
            HStack {
                if let status = model.status {
                    Text(status).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
                Spacer()
                Text("Selected: \(model.selectedCount) files · \(fmtSize(model.selectedTotal))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    confirmTrash = true
                } label: { Label("Move to Trash", systemImage: "trash") }
                    .disabled(model.selectedCount == 0 || model.scanning)
            }
            .padding(12)
        }
        .frame(minWidth: 680, minHeight: 520)
        .quickLookPreview($model.previewURL, in: model.currentURLs)
        .onAppear { model.scan() }
        .confirmationDialog(
            "Move \(model.selectedCount) files (\(fmtSize(model.selectedTotal))) to Trash?",
            isPresented: $confirmTrash, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files go to the Trash - recoverable until you empty it.")
        }
    }
}

@main
struct MacPulseFilesApp: App {
    var body: some Scene {
        WindowGroup("MacPulse Files") {
            ContentView()
        }
    }
}
