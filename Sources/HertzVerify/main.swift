import Foundation
import HertzCore

// Dev-only verification. Runs each real collector and an independent system
// command, then checks they agree. Run with `swift run HertzVerify`.
// This is a separate product — it never ships inside the Hertz app.

// MARK: - Harness

var failures = 0

func check(_ name: String, _ passed: Bool, _ detail: String) {
    print("  \(passed ? "✓ PASS" : "✗ FAIL")  \(name)")
    print("          \(detail)")
    if !passed { failures += 1 }
}

func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// First run of digits (with optional decimal) in a string.
func firstNumber(_ s: String) -> Double? {
    var digits = ""
    for ch in s {
        if ch.isNumber || (ch == "." && !digits.contains(".")) {
            digits.append(ch)
        } else if !digits.isEmpty {
            break
        }
    }
    return Double(digits)
}

/// Parse a human size token like "12.3M" / "1.4G" into bytes.
func humanBytes(_ token: String) -> Double {
    guard let n = firstNumber(token) else { return 0 }
    if token.contains("G") { return n * 1_073_741_824 }
    if token.contains("M") { return n * 1_048_576 }
    if token.contains("K") { return n * 1024 }
    return n
}

setvbuf(stdout, nil, _IONBF, 0) // unbuffered so output is visible live

print("Hertz — metric verification")
print(String(repeating: "─", count: 52))

// MARK: - Disk vs `df`

do {
    // Hertz uses the physical-disk view, so verify total + free against
    // `df` (df Size = all blocks, df Avail = available) — NOT df's per-volume
    // "used"/capacity, which deliberately excludes other volumes/snapshots.
    let snap = SystemMetrics().disk()
    let lines = shell("df -k /").split(separator: "\n")
    if lines.count >= 2 {
        let fields = lines[1].split(separator: " ").map(String.init)
        let dfSize = (Double(fields[1]) ?? 0) * 1024
        let dfAvail = (Double(fields[3]) ?? 0) * 1024
        let totalDelta = abs(Double(snap.total) - dfSize) / max(dfSize, 1) * 100
        let freeDelta = abs(Double(snap.free) - dfAvail) / max(dfAvail, 1) * 100
        check("Disk total + free vs df", totalDelta < 1 && freeDelta < 4,
              "collector total \(fmtGB(snap.total)) free \(fmtGB(snap.free))  ·  "
              + "df size \(fmtGB(UInt64(dfSize))) avail \(fmtGB(UInt64(dfAvail)))")
    }
}

// MARK: - Memory vs `sysctl` + `vm_stat`

do {
    let snap = SystemMetrics().memory()
    let sysctlTotal = UInt64(shell("sysctl -n hw.memsize")
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    check("Memory total vs sysctl", snap.total == sysctlTotal,
          "collector \(snap.total)  ·  sysctl \(sysctlTotal)")

    let out = shell("vm_stat")
    func pages(_ label: String) -> Double {
        for line in out.split(separator: "\n") where line.contains(label) {
            return firstNumber(String(line.split(separator: ":").last ?? "")) ?? 0
        }
        return 0
    }
    let pageSize = Double(sysconf(_SC_PAGESIZE))
    let vmUsed = (pages("Pages active") + pages("Pages wired down")
        + pages("Pages occupied by compressor")) * pageSize
    let deltaPct = abs(Double(snap.used) - vmUsed) / max(vmUsed, 1) * 100
    check("Memory used vs vm_stat", deltaPct < 8,
          "collector \(fmtGB(snap.used))  ·  vm_stat \(fmtGB(UInt64(vmUsed)))"
          + "  (\(String(format: "%.1f", deltaPct))% apart)")
}

// MARK: - CPU vs `sysctl` + `top`

do {
    let metrics = SystemMetrics()
    _ = metrics.cpu()
    let logical = Int(shell("sysctl -n hw.logicalcpu")
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    check("CPU core count vs sysctl", metrics.cpu().perCore.count == logical,
          "collector \(metrics.cpu().perCore.count)  ·  sysctl \(logical)")

    _ = metrics.cpu()
    Thread.sleep(forTimeInterval: 1.0)
    let snap = metrics.cpu()
    let topLines = shell("top -l2 -n0").split(separator: "\n")
        .filter { $0.contains("CPU usage") }
    var topBusy = -1.0
    if let last = topLines.last,
       let idleField = last.split(separator: ",").first(where: { $0.contains("idle") }),
       let idle = firstNumber(String(idleField)) {
        topBusy = 100 - idle
    }
    check("CPU total vs top", snap.total >= 0 && snap.total <= 100
          && (topBusy < 0 || abs(snap.total - topBusy) < 30),
          "collector \(String(format: "%.1f", snap.total))%  ·  "
          + "top \(String(format: "%.1f", topBusy))%  (CPU is noisy)")
}

// MARK: - CPU load average vs `uptime`

do {
    let cpu = SystemMetrics().cpu()
    let out = shell("uptime")
    if let range = out.range(of: "load average"),
       let load1 = firstNumber(String(out[range.upperBound...])) {
        check("CPU load1 vs uptime", abs(cpu.load1 - load1) < 0.6,
              "collector \(String(format: "%.2f", cpu.load1))  ·  "
              + "uptime \(String(format: "%.2f", load1))")
    }
}

// MARK: - Per-process CPU units (the timebase fix)

do {
    let collector = ProcessCollector()
    _ = collector.sample()

    let burn = Thread {
        var x = 1.0
        let end = Date().addingTimeInterval(1.2)
        while Date() < end { x = (x + 1).squareRoot() + x }
    }
    burn.stackSize = 1 << 20
    burn.start()
    Thread.sleep(forTimeInterval: 1.0)

    let mine = collector.sample().first { $0.pid == getpid() }
    // One core fully busy ≈ 100%. Pre-fix units bug reported ~2.4%.
    check("Process CPU units (burn 1 core)", (mine?.cpu ?? 0) > 50,
          "this process measured \(String(format: "%.1f", mine?.cpu ?? -1))% "
          + "— expect ~100 (1 core); pre-fix bug gave ~2.4")
}

// MARK: - Per-process memory vs `ps`

do {
    // Collector reports phys_footprint (the Activity Monitor figure). Verify
    // against `vmmap --summary`, which prints "Physical footprint:".
    let mine = ProcessCollector().sample().first { $0.pid == getpid() }
    let out = shell("vmmap --summary \(getpid()) 2>/dev/null")
    var vmFootprint = 0.0
    for line in out.split(separator: "\n")
        where line.contains("Physical footprint:") && !line.contains("peak") {
        vmFootprint = humanBytes(String(line.split(separator: ":").last ?? ""))
        break
    }
    let collectorFP = Double(mine?.memory ?? 0)
    let deltaPct = abs(collectorFP - vmFootprint) / max(vmFootprint, 1) * 100
    check("Process memory (footprint) vs vmmap", vmFootprint > 0 && deltaPct < 12,
          "collector \(fmtGB(UInt64(collectorFP)))  ·  vmmap \(fmtGB(UInt64(vmFootprint)))")
}

// MARK: - Battery vs `pmset`

do {
    let snap = BatteryMetrics().read()
    let out = shell("pmset -g batt")
    if out.contains("InternalBattery"),
       let pctField = out.split(separator: "\t").first(where: { $0.contains("%") }),
       let pmsetPct = firstNumber(String(pctField)) {
        check("Battery vs pmset", snap.present && abs(snap.percent - pmsetPct) <= 2,
              "collector \(Int(snap.percent))%  ·  pmset \(Int(pmsetPct))%")
    } else {
        check("Battery vs pmset", !snap.present, "no battery present (desktop Mac)")
    }
}

// MARK: - Disk filesystem type vs `mount`

do {
    let snap = SystemMetrics().disk()
    let mountOut = shell("mount").lowercased()
    let looksAPFS = mountOut.contains("apfs")
    check("Disk filesystem type", !snap.fsType.isEmpty
          && (!looksAPFS || snap.fsType.uppercased() == "APFS"),
          "collector \(snap.fsType)  ·  read/write \(fmtGB(UInt64(max(0, snap.readRate))))"
          + "/s, \(fmtGB(UInt64(max(0, snap.writeRate))))/s")
}

// MARK: - Battery cycle count vs `ioreg`

do {
    let snap = BatteryMetrics().read()
    if snap.present {
        let out = shell("ioreg -r -c AppleSmartBattery -d1")
        var ioregCycles = -1
        var ioregVoltage = 0
        var ioregAmperage = 0
        var ioregInstantAmperage = 0
        for line in out.split(separator: "\n") where line.contains("\"CycleCount\"") {
            ioregCycles = Int(firstNumber(String(line.split(separator: "=").last ?? "")) ?? -1)
        }
        for line in out.split(separator: "\n") where line.contains("\"Voltage\"") {
            ioregVoltage = Int(firstNumber(String(line.split(separator: "=").last ?? "")) ?? 0)
        }
        for line in out.split(separator: "\n") where line.contains("\"Amperage\"") {
            let raw = String(line.split(separator: "=").last ?? "")
                .trimmingCharacters(in: .whitespaces)
            ioregAmperage = Int(raw) ?? 0
        }
        for line in out.split(separator: "\n") where line.contains("\"InstantAmperage\"") {
            let raw = String(line.split(separator: "=").last ?? "")
                .trimmingCharacters(in: .whitespaces)
            ioregInstantAmperage = Int(raw) ?? 0
        }
        let ioregCurrent = ioregInstantAmperage != 0 ? ioregInstantAmperage : ioregAmperage
        let ioregWatts = ioregVoltage > 0 && ioregCurrent != 0
            ? Double(ioregVoltage * ioregCurrent) / 1_000_000.0 : 0
        let wattsMatch = abs(ioregWatts) < 0.05 || abs(snap.powerWatts - ioregWatts) < 0.2
        check("Battery cycle count vs ioreg",
              ioregCycles >= 0 && snap.cycleCount == ioregCycles && wattsMatch,
              "collector \(snap.cycleCount) cycles, \(Int(snap.healthPercent))% health, "
              + "\(String(format: "%.1f", snap.temperature))°C, "
              + "\(String(format: "%.1f", snap.powerWatts))W  ·  "
              + "ioreg \(ioregCycles) cycles, \(String(format: "%.1f", ioregWatts))W")
    } else {
        check("Battery cycle count vs ioreg", true, "no battery (desktop Mac)")
    }
}

// MARK: - Cleanup Scout safety

do {
    let fm = FileManager.default
    let tempHome = fm.temporaryDirectory
        .appendingPathComponent("hertz-cleanup-scout-\(UUID().uuidString)",
                                isDirectory: true)
    defer { try? fm.removeItem(at: tempHome) }

    let npmLogs = tempHome.appendingPathComponent(".npm/_logs", isDirectory: true)
    try? fm.createDirectory(at: npmLogs, withIntermediateDirectories: true)
    let logFile = npmLogs.appendingPathComponent("debug.log")
    try? Data(repeating: 7, count: 4096).write(to: logFile)

    let protectedPrefs = tempHome.appendingPathComponent("Library/Preferences",
                                                         isDirectory: true)
    try? fm.createDirectory(at: protectedPrefs, withIntermediateDirectories: true)
    let protectedFile = protectedPrefs.appendingPathComponent("keep.plist")
    try? Data(repeating: 1, count: 4096).write(to: protectedFile)

    let scout = CleanupScout(homeDirectory: tempHome)
    let scan = scout.scan()
    let foundNPM = scan.candidates.contains { $0.path == npmLogs.path }
    let foundProtected = scan.candidates.contains { $0.path.hasPrefix(protectedPrefs.path) }
    let result = scout.clean(scan.candidates)
    let cleanedLog = !fm.fileExists(atPath: logFile.path)
    let keptProtected = fm.fileExists(atPath: protectedFile.path)

    check("Cleanup Scout safe cache guard",
          foundNPM && !foundProtected && cleanedLog && keptProtected
          && result.cleanedBytes > 0,
          "found npm logs \(foundNPM), protected prefs kept \(keptProtected), "
          + "cleaned \(fmtGB(result.cleanedBytes))")
}

// MARK: - SMC sensors

do {
    let s = SMCReader().read()
    let plausible = s.cpuTemperature > 10 && s.cpuTemperature < 110
    check("SMC CPU temperature", plausible,
          plausible
            ? "CPU \(String(format: "%.1f", s.cpuTemperature))°C  ·  "
              + "\(s.fanRPM.isEmpty ? "fanless" : "\(s.fanRPM.count) fan(s)")"
            : "no temp key matched (got \(String(format: "%.1f", s.cpuTemperature))) "
              + "— M4 SMC keys differ")
}

// MARK: - CPU method comparison (debug)

do {
    func f(_ v: Double) -> String { String(format: "%.1f", v) }

    let m = SystemMetrics()
    _ = m.cpu()
    Thread.sleep(forTimeInterval: 2.0)
    let snap = m.cpu()
    let vCores = snap.perCore.map { String(format: "%.0f", $0) }.joined(separator: ",")

    var topBusy = -1.0
    let topLines = shell("top -l2 -n0").split(separator: "\n")
        .filter { $0.contains("CPU usage") }
    if let last = topLines.last,
       let idleField = last.split(separator: ",").first(where: { $0.contains("idle") }),
       let idle = firstNumber(String(idleField)) {
        topBusy = 100 - idle
    }

    let moOut = shell("/opt/homebrew/bin/mo status --json 2>/dev/null")
    var moUsage = -1.0
    if let r = moOut.range(of: "\"usage\":") {
        moUsage = firstNumber(String(moOut[r.upperBound...])) ?? -1
    }
    var moCores = "?"
    if let r = moOut.range(of: "\"per_core\":") {
        let after = moOut[r.upperBound...]
        if let close = after.firstIndex(of: "]") {
            moCores = String(after[after.startIndex...close])
                .filter { !" \n[]".contains($0) }
        }
    }

    print("  CPU totals — Hertz \(f(snap.total))   top \(f(topBusy))   mo \(f(moUsage))")
    print("    Hertz per-core: \(vCores)")
    print("    mo     per-core: \(moCores)")
}

// MARK: - SMC key discovery (debug)

do {
    let smc = SMCReader()
    print("  SMC: \(smc.debugInfo())")
    let all = smc.enumerateKeys(prefix: "")
    print("  total keys enumerated: \(all.count)")
    let temps = smc.enumerateKeys(prefix: "T")
        .compactMap { entry -> (String, Double)? in
            guard let v = entry.value, v > 5, v < 120 else { return nil }
            return (entry.key, v)
        }
        .sorted { $0.1 > $1.1 }
    print("  T-keys reading 5-120: \(temps.count)")
    for (key, value) in temps.prefix(40) {
        print("     \(key)  =  \(String(format: "%.1f", value))°C")
    }
}

// MARK: - Summary

print(String(repeating: "─", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)

// MARK: - Local format helper

func fmtGB(_ bytes: UInt64) -> String {
    if bytes < 1_048_576 {
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}
