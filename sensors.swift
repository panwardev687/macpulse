// sensors.swift - dump Apple Silicon temperature sensors as JSON, no sudo needed.
// Uses the private IOHIDEventSystemClient API (same approach as the Stats app / macmon).
// Build: swiftc -O sensors.swift -o sensors

import Foundation

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

let kHIDPage_AppleVendor = 0xff00
let kHIDUsage_AppleVendor_TemperatureSensor = 5
let kIOHIDEventTypeTemperature: Int64 = 15
let temperatureField = Int32(kIOHIDEventTypeTemperature << 16)

guard let clientUnmanaged = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
    FileHandle.standardError.write("error: cannot create HID event system client\n".data(using: .utf8)!)
    exit(1)
}
let client = clientUnmanaged.takeRetainedValue()

let matching = [
    "PrimaryUsagePage": kHIDPage_AppleVendor,
    "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor,
] as CFDictionary
IOHIDEventSystemClientSetMatching(client, matching)

guard let servicesUnmanaged = IOHIDEventSystemClientCopyServices(client) else {
    FileHandle.standardError.write("error: no temperature services found\n".data(using: .utf8)!)
    exit(1)
}
let services = servicesUnmanaged.takeRetainedValue() as [AnyObject]

var readings: [String: Double] = [:]
for service in services {
    guard let nameUnmanaged = IOHIDServiceClientCopyProperty(service as CFTypeRef, "Product" as CFString),
          let name = nameUnmanaged.takeRetainedValue() as? String,
          let eventUnmanaged = IOHIDServiceClientCopyEvent(service as CFTypeRef, kIOHIDEventTypeTemperature, 0, 0)
    else { continue }
    let event = eventUnmanaged.takeRetainedValue()
    let temp = IOHIDEventGetFloatValue(event, temperatureField)
    if temp > -40 && temp < 150 {
        readings[name] = temp
    }
}

let thermalState: String
switch ProcessInfo.processInfo.thermalState {
case .nominal: thermalState = "Nominal"
case .fair: thermalState = "Fair"
case .serious: thermalState = "Serious"
case .critical: thermalState = "Critical"
@unknown default: thermalState = "Unknown"
}

var output: [String: Any] = readings.mapValues { ($0 * 100).rounded() / 100 }
output["_thermal_state"] = thermalState

let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)
