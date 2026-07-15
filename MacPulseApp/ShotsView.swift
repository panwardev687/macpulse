// ShotsView.swift - screenshot organizer: background engine + settings pane.
// The engine runs for the whole app lifetime (started from the app delegate),
// regardless of which pane is showing.

import SwiftUI

final class ShotsModel: ObservableObject {
    static let shared = ShotsModel()

    @Published var paused = UserDefaults.standard.bool(forKey: "shots.paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "shots.paused") }
    }
    @Published var movedCount = 0
    @Published var lastMoved: String? = nil
    private var timer: Timer?

    var sourceDir: URL {
        if let loc = CFPreferencesCopyAppValue(
            "location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let expanded = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
               isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return home("Desktop")
    }

    var destRoot: URL { home("Pictures/Screenshots") }

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func isCapture(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let exts = ["png", "jpg", "jpeg", "heic", "mov", "mp4"]
        guard exts.contains(url.pathExtension.lowercased()) else { return false }
        var prefixes = ["Screenshot", "Screen Shot", "Screen Recording", "CleanShot"]
        if let custom = CFPreferencesCopyAppValue(
            "name" as CFString, "com.apple.screencapture" as CFString) as? String,
           !custom.isEmpty {
            prefixes.append(custom)
        }
        return prefixes.contains { name.hasPrefix($0) }
    }

    func tick() {
        guard !paused else { return }
        organize(olderThan: 3)
    }

    func organize(olderThan minAge: TimeInterval) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])
        else { return }

        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "yyyy-MM"

        var moved = 0
        var lastName: String? = nil
        for url in children where isCapture(url) {
            guard let v = try? url.resourceValues(forKeys:
                    [.contentModificationDateKey, .creationDateKey]),
                  let mod = v.contentModificationDate,
                  Date().timeIntervalSince(mod) > minAge else { continue }
            let stamp = v.creationDate ?? mod
            let destDir = destRoot.appendingPathComponent(monthFmt.string(from: stamp))
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            var dest = destDir.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = url.deletingPathExtension().lastPathComponent
                dest = destDir.appendingPathComponent(
                    "\(base) (\(n)).\(url.pathExtension)")
                n += 1
            }
            do {
                try fm.moveItem(at: url, to: dest)
                moved += 1
                lastName = dest.lastPathComponent
            } catch { /* locked or no permission - leave it */ }
        }
        if moved > 0 {
            DispatchQueue.main.async {
                self.movedCount += moved
                self.lastMoved = lastName
            }
        }
    }
}

struct ShotsView: View {
    @ObservedObject var model = ShotsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screenshot Organizer")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.paused
                         ? "Paused - new captures stay where they land"
                         : "Active - new captures are filed automatically")
                        .font(.system(size: 11))
                        .foregroundStyle(model.paused ? .orange : .green)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !model.paused },
                    set: { model.paused = !$0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(16)
            Divider()

            Form {
                LabeledContent("Watching") {
                    Text(model.sourceDir.path).foregroundStyle(.secondary)
                }
                LabeledContent("Filing into") {
                    Text(model.destRoot.path + "/YYYY-MM/").foregroundStyle(.secondary)
                }
                LabeledContent("Filed this session") {
                    Text("\(model.movedCount)").foregroundStyle(.secondary)
                }
                if let last = model.lastMoved {
                    LabeledContent("Most recent") {
                        Text(last).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 220)

            HStack {
                Button("Organize existing captures now") {
                    model.organize(olderThan: 3)
                }
                Button("Open Screenshots folder") {
                    try? FileManager.default.createDirectory(
                        at: model.destRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.destRoot)
                }
            }
            .padding(16)

            Text("Captures must be at least 3 seconds old before they're moved, so in-progress recordings are never touched. Existing files are never overwritten - collisions get a numeric suffix. A custom screenshot location (set via `defaults write com.apple.screencapture location`) is respected automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            Spacer()
        }
    }
}
