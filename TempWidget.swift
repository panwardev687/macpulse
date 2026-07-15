// TempWidget.swift - menu bar temperature widget for macpulse.
// Shows live CPU temperature next to Control Center; text shifts green→yellow→orange→red
// as the chip heats up. Click for a native glass (vibrancy) panel with details.
// Build: see build_widget.sh

import AppKit

// MARK: - IOKit HID temperature reading (same private API as sensors.swift)

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

let kIOHIDEventTypeTemperature: Int64 = 15
let temperatureField = Int32(kIOHIDEventTypeTemperature << 16)

struct TempReading {
    var cpuMax: Double?
    var battery: Double?
    var ssd: Double?
}

func readTemperatures() -> TempReading {
    var reading = TempReading()
    guard let clientU = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return reading }
    let client = clientU.takeRetainedValue()
    let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
    IOHIDEventSystemClientSetMatching(client, matching)
    guard let servicesU = IOHIDEventSystemClientCopyServices(client) else { return reading }
    let services = servicesU.takeRetainedValue() as [AnyObject]

    var dieTemps: [Double] = []
    for service in services {
        guard let nameU = IOHIDServiceClientCopyProperty(service as CFTypeRef, "Product" as CFString),
              let name = nameU.takeRetainedValue() as? String,
              let eventU = IOHIDServiceClientCopyEvent(service as CFTypeRef, kIOHIDEventTypeTemperature, 0, 0)
        else { continue }
        let temp = IOHIDEventGetFloatValue(eventU.takeRetainedValue(), temperatureField)
        guard temp > -40, temp < 150 else { continue }
        let lower = name.lowercased()
        if lower.contains("tdie") { dieTemps.append(temp) }
        else if lower.contains("battery") { reading.battery = temp }
        else if lower.contains("nand") { reading.ssd = temp }
    }
    reading.cpuMax = dieTemps.max()
    return reading
}

func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "Nominal"
    case .fair: return "Fair"
    case .serious: return "Serious"
    case .critical: return "Critical"
    @unknown default: return "Unknown"
    }
}

// MARK: - Color: gradually red as temperature increases

/// Gradient stops: ≤45° green · 65° yellow · 80° orange · ≥95° red
func temperatureColor(_ t: Double) -> NSColor {
    let stops: [(Double, NSColor)] = [
        (45, NSColor.systemGreen),
        (65, NSColor.systemYellow),
        (80, NSColor.systemOrange),
        (95, NSColor.systemRed),
    ]
    if t <= stops[0].0 { return stops[0].1 }
    if t >= stops.last!.0 { return stops.last!.1 }
    for i in 0..<(stops.count - 1) {
        let (t0, c0) = stops[i], (t1, c1) = stops[i + 1]
        if t >= t0 && t <= t1 {
            let f = CGFloat((t - t0) / (t1 - t0))
            let a = c0.usingColorSpace(.sRGB)!, b = c1.usingColorSpace(.sRGB)!
            return NSColor(
                red: a.redComponent + (b.redComponent - a.redComponent) * f,
                green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                alpha: 1
            )
        }
    }
    return .labelColor
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()

    // panel labels
    let bigTemp = NSTextField(labelWithString: "–")
    let subtitle = NSTextField(labelWithString: "")
    let batteryRow = NSTextField(labelWithString: "")
    let ssdRow = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.contentViewController = makePanel()
        popover.delegate = self

        update()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.update() }
    }

    func makePanel() -> NSViewController {
        let vc = NSViewController()
        // Native macOS glass: vibrancy material behind the popover content
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 150))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active

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

        let dash = NSButton(title: "Open Dashboard", target: self, action: #selector(openDashboard))
        dash.bezelStyle = .rounded
        dash.controlSize = .regular
        dash.keyEquivalent = "\r"
        if let icon = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil) {
            dash.image = icon
            dash.imagePosition = .imageLeading
        }

        let quit = NSButton(title: "Quit widget", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [bigTemp, subtitle, batteryRow, ssdRow, dash, quit])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(2, after: bigTemp)
        stack.setCustomSpacing(12, after: ssdRow)
        stack.setCustomSpacing(8, after: dash)
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
        let r = readTemperatures()
        guard let cpu = r.cpuMax else {
            statusItem.button?.title = "–°"
            return
        }
        let color = temperatureColor(cpu)

        // menu bar: thermometer glyph + temperature, tinted by heat
        let text = String(format: "%.0f°", cpu)
        let attr = NSMutableAttributedString()
        if let glyph = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "temperature") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(.init(paletteColors: [color]))
            let attachment = NSTextAttachment()
            attachment.image = glyph.withSymbolConfiguration(config)
            attachment.bounds = NSRect(x: 0, y: -2.5, width: 14, height: 14)
            attr.append(NSAttributedString(attachment: attachment))
        }
        attr.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
            .baselineOffset: 0.5,
        ]))
        statusItem.button?.attributedTitle = attr

        // panel
        bigTemp.stringValue = String(format: "%.1f°C", cpu)
        bigTemp.textColor = color
        subtitle.stringValue = "CPU · Thermal \(thermalStateName())"
        batteryRow.stringValue = r.battery.map { String(format: "Battery  %.0f°C", $0) } ?? ""
        ssdRow.stringValue = r.ssd.map { String(format: "SSD  %.0f°C", $0) } ?? ""
    }

    @objc func openDashboard() {
        popover.performClose(nil)
        let url = URL(string: "http://127.0.0.1:8321")!
        // toolkit folder = where this .app bundle lives
        let toolkitDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent

        var req = URLRequest(url: url, timeoutInterval: 0.6)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                if resp is HTTPURLResponse {
                    NSWorkspace.shared.open(url)     // server already running
                } else {
                    // start the dashboard server, then open the page
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    p.arguments = [toolkitDir + "/macpulse.py", "dashboard", "--no-open"]
                    try? p.run()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }.resume()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
