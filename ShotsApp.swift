// ShotsApp.swift - MacPulse Shots: screenshot organizer in the menu bar.
// Watches your screenshot folder (reads the com.apple.screencapture location,
// defaults to Desktop) and files new screenshots & screen recordings into
// ~/Pictures/Screenshots/YYYY-MM/. Files must be at least 3 seconds old before
// moving so in-progress captures are never touched. Pausable from the menu.
// Build: see build_shots.sh

import SwiftUI

// MARK: - Organizer engine

final class ShotsModel: ObservableObject {
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused") }
    }
    @Published var movedCount = 0
    @Published var lastMoved: String? = nil
    private var timer: Timer?

    var sourceDir: URL {
        // respect a custom screenshot location if the user set one
        if let loc = CFPreferencesCopyAppValue(
            "location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let expanded = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
               isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
    }

    var destRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Screenshots")
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func isCapture(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let exts = ["png", "jpg", "jpeg", "heic", "mov", "mp4"]
        guard exts.contains(url.pathExtension.lowercased()) else { return false }
        // localized default prefixes + custom prefix from screencapture "name"
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

    /// Move eligible captures. minAge avoids grabbing files still being written.
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
            // never overwrite: add a numeric suffix on collision
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

// MARK: - Menu bar UI

struct MenuContent: View {
    @ObservedObject var model: ShotsModel

    var body: some View {
        Toggle("Pause organizing", isOn: $model.paused)
        Divider()
        Text(model.movedCount == 0
             ? "No screenshots filed yet this session"
             : "Filed \(model.movedCount) this session")
        if let last = model.lastMoved {
            Text("Last: \(last)")
        }
        Text("Watching: \(model.sourceDir.path)")
        Divider()
        Button("Organize existing captures now") {
            model.organize(olderThan: 3)
        }
        Button("Open Screenshots folder") {
            try? FileManager.default.createDirectory(
                at: model.destRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(model.destRoot)
        }
        Divider()
        Button("Quit MacPulse Shots") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@main
struct MacPulseShotsApp: App {
    @StateObject var model = ShotsModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.paused
                  ? "camera.metering.none" : "camera.viewfinder")
        }
        .menuBarExtraStyle(.menu)
    }
}
