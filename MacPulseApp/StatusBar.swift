// StatusBar.swift - the combined menu bar presence: CPU temperature tinted by
// heat + used memory tinted by pressure, refreshed every 5 s. Click for a
// glass popover with quick stats and an "Open MacPulse" button. Also hosts the
// app delegate that keeps MacPulse alive in the menu bar when the window closes
// and starts the background screenshot organizer.

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let settings = SettingsModel.shared
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    let tempRow = NSTextField(labelWithString: "–")
    let memRow = NSTextField(labelWithString: "–")
    let diskRow = NSTextField(labelWithString: "–")
    let shotsRow = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = ShotsModel.shared   // start the screenshot organizer engine

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.contentViewController = makePanel()

        update()
        reschedule()
        // settings changes apply live: recolor immediately, adopt new interval
        cancellable = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.update()
                self?.reschedule()
            }
        }
    }

    func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: settings.refreshInterval, repeats: true
        ) { _ in self.update() }
    }

    // keep running in the menu bar after the window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // clicking the Dock icon reopens the window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMain() }
        return true
    }

    func makePanel() -> NSViewController {
        let vc = NSViewController()
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active

        let title = NSTextField(labelWithString: "MacPulse")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        for row in [tempRow, memRow, diskRow, shotsRow] {
            row.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            row.textColor = .secondaryLabelColor
        }

        let open = NSButton(title: "Open MacPulse", target: self, action: #selector(openMainAction))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        if let icon = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil) {
            open.image = icon
            open.imagePosition = .imageLeading
        }

        let quit = NSButton(title: "Quit MacPulse", target: NSApp,
                            action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [title, tempRow, memRow, diskRow, shotsRow, open, quit])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(12, after: shotsRow)
        stack.setCustomSpacing(8, after: open)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
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

    private func glyph(_ symbol: String, _ color: NSColor) -> NSAttributedString {
        let attr = NSMutableAttributedString()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(.init(paletteColors: [color]))
            let attachment = NSTextAttachment()
            attachment.image = img.withSymbolConfiguration(config)
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            attr.append(NSAttributedString(attachment: attachment))
        }
        return attr
    }

    private func value(_ text: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: color,
            .baselineOffset: 0.5,
        ])
    }

    func update() {
        let temps = readTemperatures()
        let mem = readMemStats()
        let disk = readDiskStats()

        // menu bar: 🌡48° ▦12.3G - content and coloring follow Settings
        let attr = NSMutableAttributedString()
        if settings.showTemp, let cpu = temps.cpuMax {
            let tColor = settings.widgetColor(status: temperatureColor(cpu))
            attr.append(glyph("thermometer.medium", tColor))
            attr.append(value(fmtTempShort(cpu), tColor))
        }
        if settings.showMem {
            if attr.length > 0 { attr.append(NSAttributedString(string: "  ")) }
            let mColor = settings.widgetColor(status: pressureColor(mem.pressureLevel))
            attr.append(glyph("memorychip", mColor))
            attr.append(value(gb(mem.used), mColor))
        }
        if attr.length == 0 {
            // both hidden - keep a plain gauge so the popover stays reachable
            attr.append(glyph("gauge.with.needle", .labelColor))
        }
        statusItem.button?.attributedTitle = attr

        // popover rows always use status colors - they carry meaning here
        if let cpu = temps.cpuMax {
            tempRow.stringValue = "CPU  \(fmtTemp(cpu, decimals: 1)) · \(thermalStateName())"
            tempRow.textColor = temperatureColor(cpu)
        } else {
            tempRow.stringValue = "CPU  – (sensors unavailable)"
        }
        memRow.stringValue = "Memory  \(gb(mem.used)) / \(gb(mem.total)) · \(pressureName(mem.pressureLevel))"
        memRow.textColor = pressureColor(mem.pressureLevel)
        diskRow.stringValue = "Disk  \(fmtBytes(disk.free)) free"
        diskRow.textColor = disk.usedFraction > 0.85 ? .systemOrange : .secondaryLabelColor
        let shots = ShotsModel.shared
        shotsRow.stringValue = shots.paused
            ? "Screenshots  paused"
            : "Screenshots  \(shots.movedCount) filed"
    }

    @objc func openMainAction() {
        popover.performClose(nil)
        openMain()
    }

    func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows
        where window.canBecomeMain && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            update()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
