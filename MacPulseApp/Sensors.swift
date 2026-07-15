// Sensors.swift - CPU/battery/SSD temperature via the IOKit HID interface
// (same private API the Stats app uses; works without sudo on Apple Silicon).
// Note: private API - fine for direct distribution, not Mac App Store.

import AppKit

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
