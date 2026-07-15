// MemoryStats.swift - memory pressure, swap, and per-app memory usage.

import AppKit
import Darwin

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
        s.used = (UInt64(vm.active_count) + UInt64(vm.wire_count)
                  + UInt64(vm.compressor_page_count)) * page
        s.compressed = UInt64(vm.compressor_page_count) * page
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

struct ProcGroup {
    let name: String
    let bytes: UInt64
}

/// Top memory consumers, helper processes folded into their owning .app.
func topMemoryProcesses(limit: Int = 5) -> [ProcGroup] {
    let (out, _) = runCommand("/bin/ps", ["axo", "rss=,comm="])
    var byApp: [String: UInt64] = [:]
    for line in out.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " "),
              let rssKB = UInt64(trimmed[..<spaceIdx]) else { continue }
        let path = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
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

func runningApp(named name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.activationPolicy == .regular &&
        ($0.localizedName == name ||
         $0.bundleURL?.deletingPathExtension().lastPathComponent == name)
    }
}
