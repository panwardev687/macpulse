// StartupView.swift - login items & background process auditor pane
// (ported from StartupApp.swift).

import SwiftUI

enum AgentDomain: String, CaseIterable {
    case userAgent = "Your Launch Agents"
    case globalAgent = "System-wide Launch Agents"
    case globalDaemon = "System-wide Launch Daemons"
    case disabled = "Disabled by MacPulse"

    var dir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .userAgent: return home.appendingPathComponent("Library/LaunchAgents")
        case .globalAgent: return URL(fileURLWithPath: "/Library/LaunchAgents")
        case .globalDaemon: return URL(fileURLWithPath: "/Library/LaunchDaemons")
        case .disabled: return home.appendingPathComponent("Library/LaunchAgents (Disabled)")
        }
    }
    var editable: Bool { self == .userAgent || self == .disabled }
}

struct AgentItem: Identifiable {
    let id: String
    let label: String
    let plist: URL
    let program: String?
    let domain: AgentDomain
    let running: Bool
    let orphan: Bool
}

func loadedUserServices() -> [String: Bool] {
    var result: [String: Bool] = [:]
    let (out, _) = runCommand("/bin/launchctl", ["list"])
    for line in out.split(separator: "\n").dropFirst() {
        let cols = line.split(separator: "\t", maxSplits: 2)
        guard cols.count == 3 else { continue }
        result[String(cols[2])] = cols[0] != "-"
    }
    return result
}

func scanAgents() -> [AgentItem] {
    let fm = FileManager.default
    let loaded = loadedUserServices()
    var items: [AgentItem] = []

    for domain in AgentDomain.allCases {
        guard let files = try? fm.contentsOfDirectory(
            at: domain.dir, includingPropertiesForKeys: nil) else { continue }
        for f in files where f.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: f),
                  let dict = (try? PropertyListSerialization.propertyList(
                      from: data, format: nil)) as? [String: Any]
            else {
                items.append(AgentItem(
                    id: f.path, label: f.deletingPathExtension().lastPathComponent,
                    plist: f, program: nil, domain: domain, running: false, orphan: false))
                continue
            }
            let label = dict["Label"] as? String
                ?? f.deletingPathExtension().lastPathComponent
            var program = dict["Program"] as? String
            if program == nil, let args = dict["ProgramArguments"] as? [String] {
                program = args.first
            }
            var orphan = false
            if let prog = program, prog.hasPrefix("/"),
               !fm.fileExists(atPath: prog) {
                orphan = true
            }
            items.append(AgentItem(
                id: f.path, label: label, plist: f, program: program,
                domain: domain,
                running: loaded[label] ?? false,
                orphan: orphan))
        }
    }
    return items
}

func loginItemNames() -> [String]? {
    let (out, ok) = runCommand("/usr/bin/osascript",
        ["-e", "tell application \"System Events\" to get the name of every login item"])
    guard ok else { return nil }
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }
    return trimmed.components(separatedBy: ", ")
}

final class StartupModel: ObservableObject {
    @Published var items: [AgentItem] = []
    @Published var loginItems: [String]? = []
    @Published var loginItemsDenied = false
    @Published var scanning = false
    @Published var status: String? = nil
    var neverScanned = true

    func scan() {
        guard !scanning else { return }
        scanning = true
        neverScanned = false
        status = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let agents = scanAgents()
            let logins = loginItemNames()
            DispatchQueue.main.async {
                self.items = agents
                self.loginItems = logins
                self.loginItemsDenied = (logins == nil)
                self.scanning = false
            }
        }
    }

    func disable(_ item: AgentItem) {
        guard item.domain == .userAgent else { return }
        let disabledDir = AgentDomain.disabled.dir
        try? FileManager.default.createDirectory(
            at: disabledDir, withIntermediateDirectories: true)
        _ = runCommand("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        let dest = disabledDir.appendingPathComponent(item.plist.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.plist, to: dest)
            status = "Disabled \(item.label) - takes full effect after next login"
        } catch {
            status = "Could not move \(item.plist.lastPathComponent): \(error.localizedDescription)"
        }
        scan()
    }

    func enable(_ item: AgentItem) {
        guard item.domain == .disabled else { return }
        let dest = AgentDomain.userAgent.dir.appendingPathComponent(item.plist.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.plist, to: dest)
            _ = runCommand("/bin/launchctl", ["bootstrap", "gui/\(getuid())", dest.path])
            status = "Re-enabled \(item.label)"
        } catch {
            status = "Could not restore: \(error.localizedDescription)"
        }
        scan()
    }

    func removeLoginItem(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let (_, ok) = runCommand("/usr/bin/osascript",
            ["-e", "tell application \"System Events\" to delete login item \"\(escaped)\""])
        status = ok ? "Removed login item \(name)" : "Could not remove \(name)"
        scan()
    }
}

struct AgentRow: View {
    let item: AgentItem
    let model: StartupModel
    @State private var confirmDisable = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.running ? Color.green :
                      item.domain == .disabled ? Color.gray.opacity(0.4) : Color.secondary.opacity(0.25))
                .frame(width: 8, height: 8)
                .help(item.running ? "Running now" : "Not currently running")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).font(.system(size: 12, weight: .medium))
                    if item.orphan {
                        Text("ORPHAN - app is gone")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }
                if let prog = item.program {
                    Text(prog)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.plist])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal plist in Finder")
            if item.domain == .userAgent {
                Button("Disable") { confirmDisable = true }
                    .controlSize(.small)
            } else if item.domain == .disabled {
                Button("Enable") { model.enable(item) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Disable \(item.label)?", isPresented: $confirmDisable, titleVisibility: .visible
        ) {
            Button("Disable", role: .destructive) { model.disable(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be unloaded and its plist moved to \"LaunchAgents (Disabled)\". You can re-enable it here anytime.")
        }
    }
}

struct StartupView: View {
    @ObservedObject var model: StartupModel

    var orphanCount: Int { model.items.filter { $0.orphan }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Startup & Background Items")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(model.items.count) launch items · \(model.items.filter { $0.running }.count) running now" +
                         (orphanCount > 0 ? " · \(orphanCount) orphaned" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(orphanCount > 0 ? .orange : .secondary)
                }
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button {
                    model.scan()
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
            }
            .padding(14)
            Divider()

            List {
                Section("Login Items (System Settings)") {
                    if model.loginItemsDenied {
                        Text("Needs Automation permission - System Settings → Privacy & Security → Automation → MacPulse → System Events")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else if let logins = model.loginItems, !logins.isEmpty {
                        ForEach(logins, id: \.self) { name in
                            HStack {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(.secondary)
                                Text(name).font(.system(size: 12))
                                Spacer()
                                Button("Remove") { model.removeLoginItem(name) }
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        Text("None").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                ForEach(AgentDomain.allCases, id: \.self) { domain in
                    let rows = model.items.filter { $0.domain == domain }
                    if !rows.isEmpty {
                        Section(header: HStack {
                            Text(domain.rawValue)
                            if !domain.editable {
                                Text("read-only - needs admin; reveal & delete in Finder")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }) {
                            ForEach(rows) { AgentRow(item: $0, model: model) }
                        }
                    }
                }
            }
            .listStyle(.inset)

            if let status = model.status {
                Divider()
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .onAppear { if model.neverScanned { model.scan() } }
    }
}
