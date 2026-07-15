// DashboardView.swift - at-a-glance system health: temperature, memory,
// disk, and the apps using the most memory. Refreshes every 5 seconds.

import SwiftUI

final class DashboardModel: ObservableObject {
    @Published var temp = TempReading()
    @Published var mem = MemStats()
    @Published var disk = DiskStats()
    @Published var procs: [ProcGroup] = []
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let t = readTemperatures()
            let m = readMemStats()
            let d = readDiskStats()
            let p = topMemoryProcesses(limit: 6)
            DispatchQueue.main.async {
                self.temp = t
                self.mem = m
                self.disk = d
                self.procs = p
            }
        }
    }
}

struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let sub: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var settings = SettingsModel.shared  // re-render on unit change

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("System at a glance")
                    .font(.system(size: 16, weight: .semibold))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                          spacing: 12) {
                    if let cpu = model.temp.cpuMax {
                        StatTile(
                            icon: "thermometer.medium", title: "CPU Temperature",
                            value: fmtTemp(cpu, decimals: 1),
                            sub: "Thermal pressure: \(thermalStateName())",
                            color: Color(nsColor: temperatureColor(cpu)))
                    } else {
                        StatTile(icon: "thermometer.medium", title: "CPU Temperature",
                                 value: "–", sub: "Sensors unavailable")
                    }
                    StatTile(
                        icon: "memorychip", title: "Memory",
                        value: "\(gb(model.mem.used)) / \(gb(model.mem.total))",
                        sub: "Pressure: \(pressureName(model.mem.pressureLevel)) · Compressed \(gb(model.mem.compressed))",
                        color: Color(nsColor: pressureColor(model.mem.pressureLevel)))
                    StatTile(
                        icon: "arrow.down.doc", title: "Swap",
                        value: model.mem.swapUsed > 0 ? gb(model.mem.swapUsed) : "None",
                        sub: model.mem.swapUsed > 4_294_967_296
                            ? "Heavy swapping - check memory hogs below"
                            : "Compressed memory spilling to disk",
                        color: model.mem.swapUsed > 4_294_967_296 ? .orange : .primary)
                    StatTile(
                        icon: "externaldrive", title: "Disk Free",
                        value: fmtBytes(model.disk.free),
                        sub: String(format: "%.0f%% used of %@",
                                    model.disk.usedFraction * 100, fmtBytes(model.disk.total)),
                        color: model.disk.usedFraction > 0.85 ? .orange : .primary)
                    if let batt = model.temp.battery {
                        StatTile(icon: "battery.75", title: "Battery Temp",
                                 value: fmtTemp(batt),
                                 sub: batt >= 38 ? "Warm - sun, hot room, or blocked vent?"
                                                 : "Normal ambient range")
                    }
                    if let ssd = model.temp.ssd {
                        StatTile(icon: "internaldrive", title: "SSD Temp",
                                 value: fmtTemp(ssd), sub: "NAND sensor")
                    }
                }

                Text("Top memory apps")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(model.procs, id: \.name) { proc in
                        HStack {
                            Text(proc.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Text(gb(proc.bytes))
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let app = runningApp(named: proc.name) {
                                Button("Quit") { app.terminate() }
                                    .controlSize(.small)
                                    .help("Polite quit - the app can still prompt to save")
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            }
            .padding(20)
        }
    }
}
