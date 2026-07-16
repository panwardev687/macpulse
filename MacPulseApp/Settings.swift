// Settings.swift - user preferences: menu bar widget content & colors,
// temperature unit, refresh rate, launch at login. Persisted in UserDefaults.

import SwiftUI
import ServiceManagement

let sponsorURL = URL(string: "https://github.com/sponsors/panwardev687")!
let issuesURL = URL(string: "https://github.com/panwardev687/macpulse/issues")!

enum WidgetColorMode: String, CaseIterable, Identifiable {
    case status, fixed, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .status: return "Status colors (green → red by heat/pressure)"
        case .fixed: return "Custom color"
        case .mono: return "Monochrome (match menu bar)"
        }
    }
}

enum TempUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var label: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? NSColor.systemGreen.usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let d = UserDefaults.standard

    @Published var showTemp: Bool { didSet { d.set(showTemp, forKey: "widget.showTemp") } }
    @Published var showMem: Bool { didSet { d.set(showMem, forKey: "widget.showMem") } }
    @Published var colorMode: WidgetColorMode {
        didSet { d.set(colorMode.rawValue, forKey: "widget.colorMode") }
    }
    @Published var fixedColorHex: String {
        didSet { d.set(fixedColorHex, forKey: "widget.fixedColor") }
    }
    @Published var tempUnit: TempUnit {
        didSet { d.set(tempUnit.rawValue, forKey: "units.temp") }
    }
    @Published var refreshInterval: Double {
        didSet { d.set(refreshInterval, forKey: "widget.refresh") }
    }
    @Published var launchError: String? = nil

    private init() {
        showTemp = d.object(forKey: "widget.showTemp") as? Bool ?? true
        showMem = d.object(forKey: "widget.showMem") as? Bool ?? true
        colorMode = WidgetColorMode(
            rawValue: d.string(forKey: "widget.colorMode") ?? "") ?? .status
        fixedColorHex = d.string(forKey: "widget.fixedColor") ?? "#30D158"
        tempUnit = TempUnit(rawValue: d.string(forKey: "units.temp") ?? "") ?? .celsius
        let r = d.double(forKey: "widget.refresh")
        refreshInterval = r >= 1 ? r : 5
    }

    /// Resolve the menu bar color for a value whose natural "status" color is given.
    func widgetColor(status: NSColor) -> NSColor {
        switch colorMode {
        case .status: return status
        case .mono: return .labelColor
        case .fixed: return NSColor(hex: fixedColorHex) ?? .labelColor
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        launchError = nil
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchError = error.localizedDescription
        }
        objectWillChange.send()
    }
}

/// Format a Celsius reading in the user's chosen unit.
func fmtTemp(_ celsius: Double, decimals: Int = 0) -> String {
    let s = SettingsModel.shared
    let v = s.tempUnit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
    let unit = s.tempUnit == .fahrenheit ? "F" : "C"
    return String(format: "%.\(decimals)f°%@", v, unit)
}

/// Short form for the menu bar: "48°" (converted, no unit letter).
func fmtTempShort(_ celsius: Double) -> String {
    let s = SettingsModel.shared
    let v = s.tempUnit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
    return String(format: "%.0f°", v)
}

// MARK: - Settings pane

struct SettingsView: View {
    @ObservedObject var settings = SettingsModel.shared
    @State private var launchOn = SettingsModel.shared.launchAtLogin

    var fixedColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: settings.fixedColorHex) ?? .systemGreen) },
            set: { settings.fixedColorHex = NSColor($0).hexString }
        )
    }

    var body: some View {
        Form {
            Section("Menu Bar Widget") {
                Toggle("Show CPU temperature", isOn: $settings.showTemp)
                Toggle("Show memory usage", isOn: $settings.showMem)
                Picker("Coloring", selection: $settings.colorMode) {
                    ForEach(WidgetColorMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.colorMode == .fixed {
                    ColorPicker("Custom color", selection: fixedColorBinding,
                                supportsOpacity: false)
                }
                Picker("Refresh every", selection: $settings.refreshInterval) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
            }

            Section("Units") {
                Picker("Temperature", selection: $settings.tempUnit) {
                    ForEach(TempUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("General") {
                Toggle("Launch MacPulse at login", isOn: Binding(
                    get: { launchOn },
                    set: { on in
                        settings.setLaunchAtLogin(on)
                        launchOn = settings.launchAtLogin
                    }))
                if let err = settings.launchError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("MacPulse stays in the menu bar when the window is closed. Quit it from the menu bar popover.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.pink)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Support the Developer")
                            .font(.system(size: 13, weight: .semibold))
                        Text("MacPulse is built by an independent developer. If it keeps your Mac cool, fast, and tidy, consider sponsoring its development - it directly funds new features.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button {
                                NSWorkspace.shared.open(sponsorURL)
                            } label: {
                                Label("Sponsor on GitHub", systemImage: "heart")
                            }
                            Button {
                                NSWorkspace.shared.open(issuesURL)
                            } label: {
                                Label("Report an Issue", systemImage: "ladybug")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("About") {
                LabeledContent("Version", value: "1.1")
                LabeledContent("Status colors") {
                    Text("Temp: green ≤ 45° · yellow 65° · orange 80° · red ≥ 95°C. Memory follows macOS pressure.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
    }
}
