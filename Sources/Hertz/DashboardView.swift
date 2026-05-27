import SwiftUI
import AppKit
import ServiceManagement
import HertzCore

struct DashboardView: View {
    let model: MetricsModel
    let updater: UpdateChecker
    @State private var sortByMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderStrip(hardware: model.hardware, health: model.health)
                .padding(.bottom, 10)

            Group {
                CPUSection(cpu: model.cpu, history: model.cpuHistory,
                           sensors: model.sensors)
                divider
                MemorySection(mem: model.memory, history: model.memoryHistory)
                divider
                DiskSection(disk: model.disk)
                divider
                NetworkSection(net: model.network, history: model.networkHistory)
                if model.battery.present || !model.deviceBatteries.isEmpty {
                    divider
                    BatterySection(battery: model.battery,
                                   devices: model.deviceBatteries)
                }
                divider
                ProcessSection(roots: model.processTree, sortByMemory: $sortByMemory)
            }

            divider
            FooterBar(updater: updater)
                .padding(.top, 9)
        }
        .padding(14)
        .frame(width: 392)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 9)
    }
}

// MARK: - Header

private struct HeaderStrip: View {
    let hardware: HardwareInfo
    let health: HealthSummary

    private var uptime: String {
        let secs = max(0, Int(Date().timeIntervalSince(hardware.bootTime)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var specs: String {
        var parts: [String] = []
        if !hardware.chip.isEmpty { parts.append(hardware.chip) }
        if hardware.pCores > 0 || hardware.eCores > 0 {
            parts.append("\(hardware.pCores)P + \(hardware.eCores)E")
        }
        parts.append("\(hardware.memoryGB) GB")
        if !hardware.osVersion.isEmpty { parts.append(hardware.osVersion) }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(healthColor(health.score))
                .frame(width: 7, height: 7)
            Text("\(health.score)")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            if !health.label.isEmpty {
                Text(health.label)
            }
            Text("·").foregroundStyle(.tertiary)
            Text(specs).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Label("up \(uptime)", systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - CPU

private struct CPUSection: View {
    let cpu: CPUSnapshot
    let history: [Double]
    let sensors: SensorSnapshot

    private var detail: String {
        var parts = ["load " + String(format: "%.2f · %.2f · %.2f",
                                       cpu.load1, cpu.load5, cpu.load15)]
        if sensors.cpuTemperature > 0 {
            parts.append(String(format: "%.0f°C", sensors.cpuTemperature))
        }
        if cpu.thermalPressure != .unknown {
            parts.append("thermal \(cpu.thermalPressure.label)")
        }
        if let fan = sensors.fanRPM.first, fan > 0 {
            parts.append("\(fan) rpm")
        }
        return parts.joined(separator: "   ·   ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: "cpu", title: "CPU") {
                HStack(spacing: 8) {
                    ThermalBadge(pressure: cpu.thermalPressure)
                    Headline(value: cpu.total, fractionDigits: 1, color: loadColor(cpu.total))
                }
            }
            Sparkline(values: history).frame(height: 30)
            CoreBars(perCore: cpu.perCore)
            DetailLine(text: detail)
        }
    }
}

// MARK: - Memory

private struct MemorySection: View {
    let mem: MemorySnapshot
    let history: [Double]

    private var freePercent: Int { Int((100 - mem.usedPercent).rounded()) }
    private var pressureLabel: String {
        switch mem.pressureLevel {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        case .unknown: return "usage"
        }
    }

    private var pressureColor: Color {
        switch mem.pressureLevel {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return loadColor(mem.pressurePercent)
        }
    }

    private var footer: String {
        let pressure = mem.pressureLevel == .unknown
            ? "Pressure unavailable"
            : "Pressure \(pressureLabel) \(Int(mem.pressurePercent.rounded()))%"
        var parts = [
            pressure,
            "Used \(Int(mem.usedPercent.rounded()))%  \(fmtMem(mem.used))",
            "Free \(freePercent)%  \(fmtMem(mem.free))"
        ]
        if mem.swapTotal > 0 {
            parts.append("Swap \(fmtMem(mem.swapUsed)) / \(fmtMem(mem.swapTotal))")
        }
        return parts.joined(separator: "   ·   ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: "memorychip", title: "MEMORY") {
                HStack(spacing: 8) {
                    PressureBadge(label: pressureLabel, color: pressureColor)
                    Headline(value: mem.usedPercent, fractionDigits: 0,
                             color: loadColor(mem.usedPercent))
                }
            }
            Sparkline(values: history,
                      color: pressureColor,
                      fixedCeiling: 100)
                .frame(height: 30)
            DetailLine(text: footer)
        }
    }
}

private struct PressureBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Disk

private struct DiskSection: View {
    let disk: DiskSnapshot

    private var detail: String {
        let used = Double(disk.used) / 1_073_741_824
        let free = Double(disk.free) / 1_073_741_824
        let total = Double(disk.total) / 1_073_741_824
        var text = String(format: "%.0f GB used   ·   %.0f GB free   ·   %.0f GB total",
                           used, free, total)
        if !disk.fsType.isEmpty { text += "   ·   \(disk.fsType)" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: "internaldrive", title: "DISK") {
                Donut(usedFraction: disk.usedPercent / 100,
                      usedColor: loadColor(disk.usedPercent))
                    .frame(width: 22, height: 22)
            }
            Bar(fraction: disk.usedPercent / 100, color: loadColor(disk.usedPercent))
            DetailLine(text: detail)
            HStack(spacing: 20) {
                IORate(symbol: "arrow.down", label: "read", rate: disk.readRate)
                IORate(symbol: "arrow.up", label: "write", rate: disk.writeRate)
                Spacer()
            }
        }
    }

    private struct IORate: View {
        let symbol: String
        let label: String
        let rate: Double

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(fmtRate(rate))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Network

private struct NetworkSection: View {
    let net: NetSnapshot
    let history: [Double]

    private var detail: String {
        var parts: [String] = []
        if !net.interface.isEmpty { parts.append(net.interface) }
        if !net.localIP.isEmpty { parts.append(net.localIP) }
        if !net.ssid.isEmpty { parts.append("\u{201C}\(net.ssid)\u{201D}") }
        if net.vpnActive { parts.append("VPN") }
        return parts.isEmpty ? "offline" : parts.joined(separator: "   ·   ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: "wifi", title: "NETWORK") {
                if net.vpnActive {
                    Label("VPN", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Sparkline(values: history).frame(height: 26)
            HStack(spacing: 24) {
                NetStat(symbol: "arrow.down", label: "download", rate: net.down)
                NetStat(symbol: "arrow.up", label: "upload", rate: net.up)
                Spacer()
            }
            DetailLine(text: detail)
        }
    }

    private struct NetStat: View {
        let symbol: String
        let label: String
        let rate: Double

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text(fmtRate(rate))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ThermalBadge: View {
    let pressure: ThermalPressure

    private var color: Color {
        switch pressure {
        case .unknown, .nominal: return .secondary
        case .moderate: return .yellow
        case .heavy, .critical: return .red
        }
    }

    private var icon: String {
        switch pressure {
        case .unknown, .nominal: return "thermometer.low"
        case .moderate: return "thermometer.medium"
        case .heavy, .critical: return "thermometer.high"
        }
    }

    var body: some View {
        if pressure.isElevated {
            Label(pressure.label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(color)
                .fixedSize()
        }
    }
}

// MARK: - Battery

private struct BatterySection: View {
    let battery: BatterySnapshot
    let devices: [DeviceBattery]

    private var status: String {
        var base: String
        if battery.charging {
            base = battery.minutesRemaining >= 0
                ? "\(fmtMinutes(battery.minutesRemaining)) to full" : "charging"
        } else if battery.onAC {
            base = battery.percent >= 99 ? "charged" : "plugged in"
        } else {
            return battery.minutesRemaining >= 0
                ? "\(fmtMinutes(battery.minutesRemaining)) remaining" : "on battery"
        }
        if battery.acMinutes >= 0 {
            base += " · \(fmtMinutes(battery.acMinutes)) on AC"
        }
        return base
    }

    private var detail: String {
        var parts = [status]
        if abs(battery.powerWatts) >= 0.05 {
            let watts = abs(battery.powerWatts)
            parts.append(String(format: battery.powerWatts > 0
                                ? "%.1fW charge" : "%.1fW draw", watts))
        }
        if battery.cycleCount > 0 { parts.append("\(battery.cycleCount) cycles") }
        if battery.healthPercent > 0 {
            parts.append("\(Int(battery.healthPercent.rounded()))% health")
        }
        if battery.temperature > 0 {
            parts.append(String(format: "%.1f°C", battery.temperature))
        }
        if battery.onAC && battery.adapterWatts > 0 {
            parts.append("\(battery.adapterWatts)W adapter")
        }
        return parts.joined(separator: "   ·   ")
    }

    private var icon: String {
        if battery.charging { return "bolt.fill" }
        if battery.onAC { return "powerplug.fill" }
        return "battery.100"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: icon, title: "BATTERY") {
                if battery.present {
                    Headline(value: battery.percent, fractionDigits: 0,
                             color: batteryColor(battery.percent))
                }
            }
            if battery.present {
                Bar(fraction: battery.percent / 100,
                    color: batteryColor(battery.percent))
                DetailLine(text: detail)
            }
            ForEach(devices) { device in
                AccessoryRow(device: device)
            }
        }
    }

    /// One connected accessory — Magic Mouse / Keyboard / Trackpad.
    private struct AccessoryRow: View {
        let device: DeviceBattery

        private var icon: String {
            let name = device.name.lowercased()
            if name.contains("mouse") { return "magicmouse" }
            if name.contains("keyboard") { return "keyboard" }
            if name.contains("trackpad") { return "trackpad" }
            return "dot.radiowaves.right"
        }

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(device.name)
                    .font(.system(size: 12))
                Spacer()
                Text("\(device.percent)%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(batteryColor(Double(device.percent)))
            }
        }
    }
}

// MARK: - Processes

private struct ProcessSection: View {
    let roots: [ProcessNode]
    @Binding var sortByMemory: Bool
    @State private var expanded: Set<pid_t> = []

    private func metric(_ n: ProcessNode) -> Double {
        sortByMemory ? Double(n.subtreeMemory) : n.subtreeCPU
    }

    /// Top-8 roots, plus the children of any expanded node, in display order.
    private var visibleRows: [(node: ProcessNode, depth: Int)] {
        var out: [(ProcessNode, Int)] = []
        for root in roots.sorted(by: { metric($0) > metric($1) }).prefix(8) {
            append(root, depth: 0, into: &out)
        }
        return out
    }

    private func append(_ node: ProcessNode, depth: Int,
                        into out: inout [(ProcessNode, Int)]) {
        out.append((node, depth))
        guard expanded.contains(node.id) else { return }
        for child in node.children.sorted(by: { metric($0) > metric($1) }) {
            append(child, depth: depth + 1, into: &out)
        }
    }

    /// A column header that is also the sort button.
    private func sortHeader(_ title: String, active: Bool, width: CGFloat,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if active {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                Text(title)
                    .font(.caption2)
                    .fontWeight(active ? .bold : .regular)
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("TOP PROCESSES")
                    .font(.caption).fontWeight(.semibold).tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                sortHeader("CPU", active: !sortByMemory, width: 56) {
                    sortByMemory = false
                }
                sortHeader("MEMORY", active: sortByMemory, width: 64) {
                    sortByMemory = true
                }
            }

            ForEach(visibleRows, id: \.node.id) { row in
                ProcessRow(node: row.node, depth: row.depth,
                           isExpanded: expanded.contains(row.node.id),
                           sortByMemory: sortByMemory) {
                    if expanded.contains(row.node.id) {
                        expanded.remove(row.node.id)
                    } else {
                        expanded.insert(row.node.id)
                    }
                }
            }
        }
    }
}

/// One process row in the tree. Subtree totals on a parent; own values on a
/// leaf. Tapping a row with children expands it.
private struct ProcessRow: View {
    let node: ProcessNode
    let depth: Int
    let isExpanded: Bool
    let sortByMemory: Bool
    let onToggle: () -> Void

    private var hasChildren: Bool { !node.children.isEmpty }

    var body: some View {
        HStack(spacing: 7) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 16)
            }
            Group {
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 9)

            ProcessIcon(path: node.sample.path)

            HStack(spacing: 5) {
                Text(node.sample.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if hasChildren {
                    Text("\(node.processCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(node.subtreeCPU, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(sortByMemory ? .secondary : loadColor(node.subtreeCPU))
            Text(fmtMem(node.subtreeMemory))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(sortByMemory ? .primary : .secondary)
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onTapGesture { if hasChildren { onToggle() } }
    }
}

private struct FooterBar: View {
    let updater: UpdateChecker
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "Hertz \($0)" } ?? "Hertz"
    }

    @ViewBuilder private var updateControl: some View {
        switch updater.status {
        case .idle:
            Button {
                Task { await updater.checkNow() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Check for updates")
        case .checking:
            Text("checking\u{2026}").foregroundStyle(.tertiary)
        case .updating:
            Text("updating\u{2026}").foregroundStyle(.green)
        case .message(let text):
            Text(text).foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(version, systemImage: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            updateControl
                .font(.caption2)
            Spacer()
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Revert the toggle if the system call failed.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Shared pieces

private struct SectionHeader<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.caption).fontWeight(.semibold).tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

/// The headline value on the right of a section header.
private struct Headline: View {
    let value: Double
    let fractionDigits: Int
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DetailLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct ProcessIcon: View {
    let path: String
    var body: some View {
        if let image = IconProvider.shared.icon(forPath: path) {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}

// MARK: - Charts

/// A line chart of recent values. Auto-scales with headroom so an idle
/// machine still shows movement without amplifying noise to full height.
private struct Sparkline: View {
    let values: [Double]
    var color: Color = .green
    /// nil = auto-scale with headroom (good for CPU); a value = fixed scale
    /// (good for memory, which is meaningfully 0-100).
    var fixedCeiling: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let ceiling = fixedCeiling ?? max((values.max() ?? 0) * 1.25, 10)
            if values.count > 1 {
                let points = values.enumerated().map { index, value in
                    CGPoint(x: w * CGFloat(index) / CGFloat(values.count - 1),
                            y: h * (1 - CGFloat(min(value / ceiling, 1))))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.14))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                               lineJoin: .round))
                }
            }
        }
    }
}

/// One thin bar per core, height = that core's load.
private struct CoreBars: View {
    let perCore: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(perCore.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(loadColor(value))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, 18 * value / 100))
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

/// Two-segment ring: used vs free.
private struct Donut: View {
    let usedFraction: Double
    let usedColor: Color
    private let gap = 0.02

    var body: some View {
        ZStack {
            ring(from: gap, to: max(gap, usedFraction - gap), color: usedColor)
            ring(from: usedFraction + gap, to: 1 - gap, color: .green)
        }
    }

    private func ring(from: Double, to: Double, color: Color) -> some View {
        Circle()
            .trim(from: from, to: max(from, to))
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Icon cache

/// Resolves and caches process icons. App bundles get their real icon;
/// plain executables get the system's generic binary icon.
@MainActor
final class IconProvider {
    static let shared = IconProvider()
    private var cache: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = cache[path] { return cached }
        let target: String
        if let range = path.range(of: ".app/") {
            target = String(path[..<range.lowerBound]) + ".app"
        } else {
            target = path
        }
        let image = NSWorkspace.shared.icon(forFile: target)
        cache[path] = image
        return image
    }
}

// MARK: - Formatting

func loadColor(_ pct: Double) -> Color {
    switch pct {
    case ..<60: return .green
    case ..<85: return .yellow
    default: return .red
    }
}

func healthColor(_ score: Int) -> Color {
    switch score {
    case 80...: return .green
    case 55..<80: return .yellow
    default: return .red
    }
}

func batteryColor(_ pct: Double) -> Color {
    switch pct {
    case ..<20: return .red
    case ..<40: return .yellow
    default: return .green
    }
}

func fmtMem(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}

func fmtRate(_ bytesPerSec: Double) -> String {
    let kb = bytesPerSec / 1024
    if kb >= 1024 { return String(format: "%.1f MB/s", kb / 1024) }
    if kb >= 1 { return String(format: "%.0f KB/s", kb) }
    return "0 KB/s"
}

func fmtMinutes(_ minutes: Int) -> String {
    if minutes < 0 { return "—" }
    let h = minutes / 60
    let m = minutes % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
