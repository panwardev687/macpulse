// StatusBar.swift - the menu bar presence: CPU temperature + memory next to
// the clock (content and colors follow Settings), and the click-down panel in
// the original MacPulse Temp widget design: big colored temperature,
// thermal state, battery and SSD rows, one Open MacPulse button.
//
// The panel is a non-activating NSPanel rather than an NSPopover on purpose:
// it opens instantly even while another app is frontmost (popovers wait for
// app activation, which felt broken), it never yanks the main MacPulse window
// forward, and it closes as soon as you click anywhere else on screen.
// Also hosts the app delegate that keeps MacPulse alive in the menu bar when
// the window closes and starts the background screenshot organizer.

import AppKit
import Combine

/// Borderless panels can't become key by default; the panel must be key so
/// its buttons respond to the first click.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: WidgetPanel!
    let settings = SettingsModel.shared
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    // panel labels (original temp-widget design)
    let bigTemp = NSTextField(labelWithString: "–")
    let subtitle = NSTextField(labelWithString: "")
    let batteryRow = NSTextField(labelWithString: "")
    let ssdRow = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = ShotsModel.shared   // start the screenshot organizer engine

        if settings.hideDock {
            NSApp.setActivationPolicy(.accessory)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self

        buildPanel()
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

    // MARK: - Panel (original MacPulse Temp design)

    func buildPanel() {
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true

        bigTemp.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        bigTemp.alignment = .center

        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        for row in [batteryRow, ssdRow] {
            row.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            row.textColor = .secondaryLabelColor
            row.alignment = .center
        }

        let open = NSButton(title: "Open MacPulse", target: self, action: #selector(openMainAction))
        open.bezelStyle = .rounded
        open.controlSize = .regular
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

        let stack = NSStackView(views: [bigTemp, subtitle, batteryRow, ssdRow, open, quit])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(2, after: bigTemp)
        stack.setCustomSpacing(12, after: ssdRow)
        stack.setCustomSpacing(8, after: open)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        ])

        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 170),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = glass
    }

    @objc func togglePanel() {
        if panel.isVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        update()
        // center under the status item, clamped to the screen edge
        if let btnWin = statusItem.button?.window {
            let btnFrame = btnWin.frame
            var x = btnFrame.midX - panel.frame.width / 2
            if let screen = btnWin.screen {
                x = min(max(x, screen.visibleFrame.minX + 8),
                        screen.visibleFrame.maxX - panel.frame.width - 8)
            }
            let y = btnFrame.minY - panel.frame.height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)

        // click anywhere outside -> close. Global monitor covers clicks in
        // other apps and the desktop; the local one covers our own windows.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel,
               event.window !== self.statusItem.button?.window {
                self.closePanel()
            }
            return event
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    // MARK: - Menu bar title

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

        // menu bar: content and coloring follow Settings
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
            // both hidden - keep a plain gauge so the panel stays reachable
            attr.append(glyph("gauge.with.needle", .labelColor))
        }
        statusItem.button?.attributedTitle = attr

        // panel: the original temp-widget layout, always status-colored
        if let cpu = temps.cpuMax {
            bigTemp.stringValue = fmtTemp(cpu, decimals: 1)
            bigTemp.textColor = temperatureColor(cpu)
        } else {
            bigTemp.stringValue = "–"
            bigTemp.textColor = .labelColor
        }
        subtitle.stringValue = "CPU · Thermal \(thermalStateName())"
        batteryRow.stringValue = temps.battery.map { "Battery  " + fmtTemp($0) } ?? ""
        ssdRow.stringValue = temps.ssd.map { "SSD  " + fmtTemp($0) } ?? ""
    }

    // MARK: - Window

    @objc func openMainAction() {
        closePanel()
        openMain()
    }

    func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows
        where window.canBecomeMain && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
