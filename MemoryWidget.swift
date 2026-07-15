// MemoryWidget.swift - MacPulse Memory: memory pressure watchdog for the menu bar.
// Shows used memory next to the clock, tinted by macOS memory-pressure level
// (green = normal, yellow = warning, red = critical). Click for a glass panel
// with swap usage and the top 5 memory-hungry apps, each with a Quit button.
// Build: see build_memory.sh

import AppKit
import Darwin

// MARK: - Memory statistics

struct MemStats {
    var total: UInt64 = 0
    var used: UInt64 = 0          // active + wired + compressed
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: Int32 = 1  // 1 normal, 2 warning, 4 critical
}

func readMemStats() -> MemStats {
    var s = MemStats()

    var memsize: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &memsize, &len, nil, 0)
    s.total = memsize

    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let page = UInt64(getpagesize())
        let active = UInt64(vm.active_count) * page
        let wired = UInt64(vm.wire_count) * page
        let compressed = UInt64(vm.compressor_page_count) * page
        s.used = active + wired + compressed
        s.compressed = compressed
    }

    var pressure: Int32 = 1
    var plen = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &plen, nil, 0)
    s.pressureLevel = pressure

    var swap = xsw_usage()
    var slen = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &slen, nil, 0)
    s.swapUsed = swap.xsu_used

    return s
}

// MARK: - Top memory processes (grouped by owning app)

struct ProcGroup {
    let name: String
    let bytes: UInt64
}

func topMemoryProcesses(limit: Int = 5) -> [ProcGroup] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["axo", "rss=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return [] }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    var byApp: [String: UInt64] = [:]
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " "),
              let rssKB = UInt64(trimmed[..<spaceIdx]) else { continue }
        let path = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
        // fold helper processes into their owning .app
        var name = (path as NSString).lastPathComponent
        for comp in path.components(separatedBy: "/") where comp.hasSuffix(".app") {
            name = String(comp.dropLast(4))
            break
        }
        byApp[name, default: 0] += rssKB * 1024
    }
    return byApp.map { ProcGroup(name: $0.key, bytes: $0.value) }
        .sorted { $0.bytes > $1.bytes }
        .prefix(limit).map { $0 }
}

// MARK: - Formatting

func gb(_ bytes: UInt64) -> String {
    String(format: "%.1fG", Double(bytes) / 1_073_741_824)
}

func pressureColor(_ level: Int32) -> NSColor {
    switch level {
    case 4: return .systemRed
    case 2: return .systemYellow
    default: return .systemGreen
    }
}

func pressureName(_ level: Int32) -> String {
    switch level {
    case 4: return "Critical"
    case 2: return "Warning"
    default: return "Normal"
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()

    let bigUsed = NSTextField(labelWithString: "–")
    let subtitle = NSTextField(labelWithString: "")
    let swapRow = NSTextField(labelWithString: "")
    let procStack = NSStackView()
    var topProcs: [ProcGroup] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.contentViewController = makePanel()

        update()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.update() }
    }

    func makePanel() -> NSViewController {
        let vc = NSViewController()
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 280))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active

        bigUsed.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        bigUsed.alignment = .center

        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        swapRow.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        swapRow.textColor = .secondaryLabelColor
        swapRow.alignment = .center

        let header = NSTextField(labelWithString: "Top memory apps")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor

        procStack.orientation = .vertical
        procStack.spacing = 3
        procStack.alignment = .leading

        let quit = NSButton(title: "Quit widget", target: NSApp,
                            action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [bigUsed, subtitle, swapRow, header, procStack, quit])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.setCustomSpacing(2, after: bigUsed)
        stack.setCustomSpacing(12, after: swapRow)
        stack.setCustomSpacing(6, after: header)
        stack.setCustomSpacing(10, after: procStack)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        ])
        vc.view = glass
        return vc
    }

    func update() {
        let s = readMemStats()
        let color = pressureColor(s.pressureLevel)

        // menu bar: memory chip glyph + used GB, tinted by pressure
        let attr = NSMutableAttributedString()
        if let glyph = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "memory") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(.init(paletteColors: [color]))
            let attachment = NSTextAttachment()
            attachment.image = glyph.withSymbolConfiguration(config)
            attachment.bounds = NSRect(x: 0, y: -2.5, width: 14, height: 14)
            attr.append(NSAttributedString(attachment: attachment))
            attr.append(NSAttributedString(string: " "))
        }
        attr.append(NSAttributedString(string: gb(s.used), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
            .baselineOffset: 0.5,
        ]))
        statusItem.button?.attributedTitle = attr

        // panel
        bigUsed.stringValue = "\(gb(s.used)) / \(gb(s.total))"
        bigUsed.textColor = color
        subtitle.stringValue = "Pressure: \(pressureName(s.pressureLevel)) · Compressed \(gb(s.compressed))"
        swapRow.stringValue = s.swapUsed > 0 ? "Swap in use: \(gb(s.swapUsed))" : "No swap in use"
        swapRow.textColor = s.swapUsed > 4_294_967_296 ? .systemOrange : .secondaryLabelColor

        // refresh top-process rows only while the panel is visible (ps is not free)
        if popover.isShown { refreshProcs() }
    }

    func refreshProcs() {
        DispatchQueue.global(qos: .userInitiated).async {
            let procs = topMemoryProcesses()
            DispatchQueue.main.async {
                self.topProcs = procs
                self.procStack.arrangedSubviews.forEach {
                    self.procStack.removeArrangedSubview($0)
                    $0.removeFromSuperview()
                }
                for (i, proc) in procs.enumerated() {
                    let label = NSTextField(
                        labelWithString: "\(gb(proc.bytes))  \(proc.name)")
                    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                    label.lineBreakMode = .byTruncatingTail
                    label.preferredMaxLayoutWidth = 160

                    let row = NSStackView()
                    row.orientation = .horizontal
                    row.spacing = 6
                    row.addArrangedSubview(label)

                    // Quit button only for real user apps we can address
                    if self.runningApp(named: proc.name) != nil {
                        let btn = NSButton(title: "Quit", target: self,
                                           action: #selector(self.quitProc(_:)))
                        btn.bezelStyle = .inline
                        btn.controlSize = .mini
                        btn.font = .systemFont(ofSize: 10)
                        btn.tag = i
                        row.addArrangedSubview(btn)
                    }
                    self.procStack.addArrangedSubview(row)
                }
            }
        }
    }

    func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular &&
            ($0.localizedName == name ||
             $0.bundleURL?.deletingPathExtension().lastPathComponent == name)
        }
    }

    @objc func quitProc(_ sender: NSButton) {
        guard sender.tag < topProcs.count,
              let app = runningApp(named: topProcs[sender.tag].name) else { return }
        app.terminate()   // polite quit - app can prompt to save unsaved work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshProcs() }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            update()
            refreshProcs()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
