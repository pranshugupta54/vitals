import Foundation

public enum DiagnosticSeverity: Int {
    case info = 0
    case warning = 1
    case critical = 2
}

public struct DiagnosticInsight: Identifiable {
    public let id: String
    public let severity: DiagnosticSeverity
    public let title: String
    public let detail: String

    public init(id: String, severity: DiagnosticSeverity,
                title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct DiagnosticContext {
    public let cpu: CPUSnapshot
    public let memory: MemorySnapshot
    public let disk: DiskSnapshot
    public let network: NetSnapshot
    public let battery: BatterySnapshot
    public let sensors: SensorSnapshot
    public let processTree: [ProcessNode]
    public let hardware: HardwareInfo
    public let health: HealthSummary

    public init(cpu: CPUSnapshot, memory: MemorySnapshot, disk: DiskSnapshot,
                network: NetSnapshot, battery: BatterySnapshot,
                sensors: SensorSnapshot, processTree: [ProcessNode],
                hardware: HardwareInfo, health: HealthSummary) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.sensors = sensors
        self.processTree = processTree
        self.hardware = hardware
        self.health = health
    }
}

public func diagnose(_ context: DiagnosticContext) -> [DiagnosticInsight] {
    var insights: [DiagnosticInsight] = []
    let topCPU = context.processTree.max { $0.subtreeCPU < $1.subtreeCPU }
    let topMemory = context.processTree.max { $0.subtreeMemory < $1.subtreeMemory }

    if context.memory.pressureLevel == .critical || context.memory.pressurePercent >= 90 {
        insights.append(memoryInsight(context, topMemory: topMemory, severity: .critical))
    } else if context.memory.pressureLevel == .warning || context.memory.pressurePercent >= 72 {
        insights.append(memoryInsight(context, topMemory: topMemory, severity: .warning))
    }

    if context.cpu.thermalPressure == .critical || context.cpu.thermalPressure == .heavy {
        insights.append(DiagnosticInsight(
            id: "thermal",
            severity: .critical,
            title: "Thermal pressure is limiting performance",
            detail: thermalDetail(context)
        ))
    } else if context.cpu.thermalPressure == .moderate {
        insights.append(DiagnosticInsight(
            id: "thermal",
            severity: .warning,
            title: "Thermals are starting to climb",
            detail: thermalDetail(context)
        ))
    }

    if context.cpu.total >= 85 {
        insights.append(cpuInsight(context, topCPU: topCPU, severity: .critical))
    } else if context.cpu.total >= 65, let topCPU, topCPU.subtreeCPU >= 45 {
        insights.append(cpuInsight(context, topCPU: topCPU, severity: .warning))
    }

    if context.disk.usedPercent >= 95 {
        insights.append(diskInsight(context, severity: .critical))
    } else if context.disk.usedPercent >= 90 {
        insights.append(diskInsight(context, severity: .warning))
    }

    if context.battery.present, context.battery.healthPercent > 0,
       context.battery.healthPercent < 80 {
        insights.append(DiagnosticInsight(
            id: "battery-health",
            severity: .warning,
            title: "Battery health is below service range",
            detail: "Health is \(whole(context.battery.healthPercent))% after "
                + "\(context.battery.cycleCount) cycles."
        ))
    }

    if context.battery.present, !context.battery.onAC,
       context.battery.powerWatts <= -22 {
        insights.append(DiagnosticInsight(
            id: "battery-draw",
            severity: .warning,
            title: "Battery is draining quickly",
            detail: "Current draw is \(oneDecimal(abs(context.battery.powerWatts)))W; "
                + "check the top CPU process before unplugged work."
        ))
    }

    let active = insights.sorted {
        if $0.severity.rawValue != $1.severity.rawValue {
            return $0.severity.rawValue > $1.severity.rawValue
        }
        return $0.title < $1.title
    }
    if !active.isEmpty { return Array(active.prefix(3)) }

    return [DiagnosticInsight(
        id: "balanced",
        severity: .info,
        title: "System looks balanced",
        detail: "No pressure signal is elevated; top processes are the best next place to inspect."
    )]
}

public func diagnosticReport(_ context: DiagnosticContext,
                             generatedAt date: Date = Date()) -> String {
    let insights = diagnose(context)
    let topCPU = context.processTree
        .sorted { $0.subtreeCPU > $1.subtreeCPU }
        .prefix(5)
    let topMemory = context.processTree
        .sorted { $0.subtreeMemory > $1.subtreeMemory }
        .prefix(5)

    var lines: [String] = [
        "Hertz diagnostic snapshot",
        "Generated: \(reportDate.string(from: date))",
        "",
        "Hardware: \(hardwareLine(context.hardware))",
        "Health: \(context.health.score) \(context.health.label)",
        "CPU: \(oneDecimal(context.cpu.total))% · load "
            + "\(twoDecimal(context.cpu.load1)), \(twoDecimal(context.cpu.load5)), "
            + "\(twoDecimal(context.cpu.load15)) · thermal "
            + "\(context.cpu.thermalPressure.label)",
        "Memory: pressure \(whole(context.memory.pressurePercent))% · used "
            + "\(whole(context.memory.usedPercent))% · swap "
            + "\(formatBytes(context.memory.swapUsed)) / \(formatBytes(context.memory.swapTotal))",
        "Disk: \(whole(context.disk.usedPercent))% used · "
            + "\(formatBytes(context.disk.free)) free",
        "Network: down \(formatRate(context.network.down)) · up "
            + "\(formatRate(context.network.up))",
        batteryLine(context.battery),
        ""
    ]

    lines.append("Diagnosis:")
    for insight in insights {
        lines.append("- \(insight.title): \(insight.detail)")
    }

    lines.append("")
    lines.append("Top CPU:")
    for node in topCPU {
        lines.append("- \(node.sample.name): \(oneDecimal(node.subtreeCPU))% CPU, "
            + "\(formatBytes(node.subtreeMemory))")
    }

    lines.append("")
    lines.append("Top Memory:")
    for node in topMemory {
        lines.append("- \(node.sample.name): \(formatBytes(node.subtreeMemory)), "
            + "\(oneDecimal(node.subtreeCPU))% CPU")
    }

    return lines.joined(separator: "\n")
}

private func memoryInsight(_ context: DiagnosticContext, topMemory: ProcessNode?,
                           severity: DiagnosticSeverity) -> DiagnosticInsight {
    let title = severity == .critical
        ? "Memory pressure is critical"
        : "Memory pressure needs attention"
    var detail = "Pressure is \(whole(context.memory.pressurePercent))% with "
        + "\(formatBytes(context.memory.swapUsed)) swap used."
    if let topMemory, topMemory.subtreeMemory >= 1_073_741_824 {
        detail += " \(topMemory.sample.name) is the largest app at "
            + "\(formatBytes(topMemory.subtreeMemory))."
    }
    return DiagnosticInsight(id: "memory", severity: severity,
                             title: title, detail: detail)
}

private func cpuInsight(_ context: DiagnosticContext, topCPU: ProcessNode?,
                        severity: DiagnosticSeverity) -> DiagnosticInsight {
    var detail = "CPU is at \(oneDecimal(context.cpu.total))%."
    if let topCPU, topCPU.subtreeCPU >= 25 {
        detail += " \(topCPU.sample.name) is leading at "
            + "\(oneDecimal(topCPU.subtreeCPU))% across "
            + "\(topCPU.processCount) process\(topCPU.processCount == 1 ? "" : "es")."
    }
    return DiagnosticInsight(id: "cpu", severity: severity,
                             title: "CPU is the current bottleneck",
                             detail: detail)
}

private func thermalDetail(_ context: DiagnosticContext) -> String {
    var parts = ["macOS reports \(context.cpu.thermalPressure.label) thermal pressure."]
    if context.sensors.cpuTemperature > 0 {
        parts.append("CPU temperature is \(whole(context.sensors.cpuTemperature))°C.")
    }
    if let fan = context.sensors.fanRPM.first, fan > 0 {
        parts.append("Fan is at \(fan) rpm.")
    }
    return parts.joined(separator: " ")
}

private func diskInsight(_ context: DiagnosticContext,
                         severity: DiagnosticSeverity) -> DiagnosticInsight {
    DiagnosticInsight(
        id: "disk",
        severity: severity,
        title: severity == .critical ? "Startup disk is almost full" : "Startup disk is getting tight",
        detail: "\(formatBytes(context.disk.free)) free on \(context.disk.fsType.isEmpty ? "disk" : context.disk.fsType)."
    )
}

private func hardwareLine(_ hardware: HardwareInfo) -> String {
    var parts: [String] = []
    if !hardware.chip.isEmpty { parts.append(hardware.chip) }
    if hardware.pCores > 0 || hardware.eCores > 0 {
        parts.append("\(hardware.pCores)P+\(hardware.eCores)E")
    }
    parts.append("\(hardware.memoryGB) GB RAM")
    if !hardware.osVersion.isEmpty { parts.append(hardware.osVersion) }
    return parts.joined(separator: " · ")
}

private func batteryLine(_ battery: BatterySnapshot) -> String {
    guard battery.present else { return "Battery: not present" }
    var parts = ["Battery: \(whole(battery.percent))%"]
    if battery.onAC {
        parts.append(battery.charging ? "charging" : "on AC")
    } else {
        parts.append("on battery")
    }
    if abs(battery.powerWatts) >= 0.05 {
        parts.append("\(oneDecimal(battery.powerWatts))W")
    }
    if battery.healthPercent > 0 {
        parts.append("\(whole(battery.healthPercent))% health")
    }
    return parts.joined(separator: " · ")
}

private let reportDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()

private func formatBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}

private func formatRate(_ bytesPerSec: Double) -> String {
    let kb = bytesPerSec / 1024
    if kb >= 1024 { return String(format: "%.1f MB/s", kb / 1024) }
    if kb >= 1 { return String(format: "%.0f KB/s", kb) }
    return "0 KB/s"
}

private func oneDecimal(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func twoDecimal(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func whole(_ value: Double) -> String {
    String(format: "%.0f", value)
}
