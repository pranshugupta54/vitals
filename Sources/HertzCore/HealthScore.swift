/// A composite 0-100 system health score with a human label.
public struct HealthSummary {
    public let score: Int
    public let label: String
    public init(score: Int = 100, label: String = "") {
        self.score = score
        self.label = label
    }
}

/// Start at 100, deduct weighted penalties once each metric passes a
/// comfortable threshold. Disk weighs heaviest — a near-full disk hurts the
/// system far more than a brief CPU spike.
public func computeHealth(cpu: CPUSnapshot, memory: MemorySnapshot,
                          disk: DiskSnapshot, battery: BatterySnapshot)
    -> HealthSummary {
    var penalty = 0.0
    penalty += max(0, cpu.total - 60) * 0.35
    penalty += max(0, memory.pressurePercent - 60) * 0.95
    penalty += max(0, disk.usedPercent - 85) * 1.60
    if battery.present, battery.healthPercent > 0 {
        penalty += max(0, 80 - battery.healthPercent) * 0.50
    }

    let score = max(0, min(100, Int((100 - penalty).rounded())))
    let label: String
    switch score {
    case 85...:   label = "Excellent"
    case 70..<85: label = "Good"
    case 50..<70: label = "Fair"
    default:      label = "Poor"
    }
    return HealthSummary(score: score, label: label)
}
