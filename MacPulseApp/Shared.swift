// Shared.swift - helpers used across every MacPulse pane.

import AppKit

func home(_ rel: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel)
}

func fmtBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: n)
}

func gb(_ bytes: UInt64) -> String {
    String(format: "%.1fG", Double(bytes) / 1_073_741_824)
}

/// Recursive allocated size of a file or directory. Unreadable entries count 0.
func dirSize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize ?? 0)
    }
    var total: Int64 = 0
    guard let en = fm.enumerator(
        at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
        options: [], errorHandler: { _, _ in true }) else { return 0 }
    for case let f as URL in en {
        if let s = (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize {
            total += Int64(s)
        }
    }
    return total
}

func runCommand(_ path: String, _ args: [String]) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return ("", false) }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (s, p.terminationStatus == 0)
}

struct DiskStats {
    var total: Int64 = 0
    var free: Int64 = 0
    var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

func readDiskStats() -> DiskStats {
    var s = DiskStats()
    let url = URL(fileURLWithPath: "/")
    if let v = try? url.resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]) {
        s.total = Int64(v.volumeTotalCapacity ?? 0)
        s.free = v.volumeAvailableCapacityForImportantUsage ?? 0
    }
    return s
}
