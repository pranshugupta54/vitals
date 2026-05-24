import Darwin
import Foundation
import IOKit
import CoreWLAN

/// System-wide CPU, sampled per core.
public struct CPUSnapshot {
    public var total: Double      // 0-100 overall busy
    public var perCore: [Double]  // 0-100 per core
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public init(total: Double = 0, perCore: [Double] = [],
                load1: Double = 0, load5: Double = 0, load15: Double = 0) {
        self.total = total
        self.perCore = perCore
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
    }
}

/// System-wide memory.
public enum MemoryPressureLevel: Int {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    public static func fromKernelValue(_ rawValue: Int) -> MemoryPressureLevel {
        switch rawValue {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
}

public struct MemorySnapshot {
    public var total: UInt64
    public var used: UInt64
    public var free: UInt64
    public var usedPercent: Double
    public var pressurePercent: Double
    public var pressureLevel: MemoryPressureLevel
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public init(total: UInt64 = 0, used: UInt64 = 0, free: UInt64 = 0,
                usedPercent: Double = 0, pressurePercent: Double = 0,
                pressureLevel: MemoryPressureLevel = .unknown,
                swapUsed: UInt64 = 0, swapTotal: UInt64 = 0) {
        self.total = total
        self.used = used
        self.free = free
        self.usedPercent = usedPercent
        self.pressurePercent = pressurePercent
        self.pressureLevel = pressureLevel
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
    }
}

/// Boot volume usage and live I/O.
public struct DiskSnapshot {
    public var total: UInt64
    public var free: UInt64
    public var used: UInt64
    public var usedPercent: Double
    public var readRate: Double  // bytes/sec
    public var writeRate: Double // bytes/sec
    public var fsType: String
    public init(total: UInt64 = 0, free: UInt64 = 0, used: UInt64 = 0,
                usedPercent: Double = 0, readRate: Double = 0,
                writeRate: Double = 0, fsType: String = "") {
        self.total = total
        self.free = free
        self.used = used
        self.usedPercent = usedPercent
        self.readRate = readRate
        self.writeRate = writeRate
        self.fsType = fsType
    }
}

/// Network throughput plus the active connection's identity.
public struct NetSnapshot {
    public var down: Double // bytes/sec
    public var up: Double
    public var localIP: String
    public var interface: String
    public var ssid: String       // "" if unknown (or no Location permission)
    public var vpnActive: Bool
    public init(down: Double = 0, up: Double = 0, localIP: String = "",
                interface: String = "", ssid: String = "", vpnActive: Bool = false) {
        self.down = down
        self.up = up
        self.localIP = localIP
        self.interface = interface
        self.ssid = ssid
        self.vpnActive = vpnActive
    }
}

/// Static machine description, read once.
public struct HardwareInfo {
    public var chip: String
    public var memoryGB: Int
    public var osVersion: String
    public var pCores: Int
    public var eCores: Int
    public var bootTime: Date
    public init(chip: String = "", memoryGB: Int = 0, osVersion: String = "",
                pCores: Int = 0, eCores: Int = 0, bootTime: Date = Date()) {
        self.chip = chip
        self.memoryGB = memoryGB
        self.osVersion = osVersion
        self.pCores = pCores
        self.eCores = eCores
        self.bootTime = bootTime
    }
}

/// CPU and memory read straight from the Mach kernel interfaces — exact,
/// unlike summing per-process CPU.
public final class SystemMetrics {
    // CPU ticks are cumulative; percentage is a delta between two reads.
    private var prevTicks: [[UInt32]] = []
    // Interface byte counters are cumulative too.
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var prevNetWall: UInt64 = 0
    // Disk I/O byte counters likewise.
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var prevDiskWall: UInt64 = 0

    public init() {}

    /// host_processor_info(PROCESSOR_CPU_LOAD_INFO) — per-core tick counters
    /// [user, system, idle, nice]. Load averages come from getloadavg.
    public func cpu() -> CPUSnapshot {
        var coreCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &coreCount, &info, &infoCount)

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        guard kr == KERN_SUCCESS, let info else {
            return CPUSnapshot(load1: loads[0], load5: loads[1], load15: loads[2])
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }

        let cores = Int(coreCount)
        let stride = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        var perCore: [Double] = []

        for c in 0..<cores {
            let base = c * stride
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let sys = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            current.append([user, sys, idle, nice])

            if c < prevTicks.count {
                let p = prevTicks[c]
                let busy = Double((user &- p[0]) &+ (sys &- p[1]) &+ (nice &- p[3]))
                let all = busy + Double(idle &- p[2])
                let pct = all > 0 ? busy / all * 100 : 0
                perCore.append(min(100, max(0, pct)))
            } else {
                perCore.append(0)
            }
        }
        prevTicks = current

        // Total = arithmetic mean of per-core utilisation — matches `top`,
        // Activity Monitor, and `mo status`. A tick-weighted ratio skews on
        // Apple silicon because parked cores accumulate ticks unevenly.
        let total = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        return CPUSnapshot(total: total, perCore: perCore,
                           load1: loads[0], load5: loads[1], load15: loads[2])
    }

    /// hw.memsize for the total, host_statistics64(HOST_VM_INFO64) for the
    /// page breakdown, vm.swapusage for swap.
    public func memory() -> MemorySnapshot {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let pressureLevel = memoryPressureLevel()
        let pressurePercent = memoryPressurePercent(level: pressureLevel)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return MemorySnapshot(total: total, used: 0, free: total, usedPercent: 0,
                                  pressurePercent: pressurePercent,
                                  pressureLevel: pressureLevel,
                                  swapUsed: swap.xsu_used, swapTotal: swap.xsu_total)
        }

        let page = UInt64(sysconf(_SC_PAGESIZE))
        let used = (UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * page
        let free = total > used ? total - used : 0
        let pct = total > 0 ? Double(used) / Double(total) * 100 : 0
        let resolvedPressure = pressureLevel == .unknown && pressurePercent == 0
            ? pct
            : pressurePercent
        return MemorySnapshot(total: total, used: used, free: free, usedPercent: pct,
                              pressurePercent: resolvedPressure,
                              pressureLevel: pressureLevel,
                              swapUsed: swap.xsu_used, swapTotal: swap.xsu_total)
    }

    /// macOS exposes the same coarse memory-pressure state that dispatch and
    /// Chromium use: 1 normal, 2 warning, 4 critical.
    private func memoryPressureLevel() -> MemoryPressureLevel {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level",
                           &raw, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressureLevel.fromKernelValue(Int(raw))
    }

    /// `vm.memory_pressure` is a kernel-maintained 0-100 signal when
    /// available. Some systems mask it, so fall back to a stable midpoint for
    /// the coarse pressure band instead of inventing precision from page counts.
    private func memoryPressurePercent(level: MemoryPressureLevel) -> Double {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("vm.memory_pressure", &raw, &size, nil, 0) == 0 {
            return min(100, max(0, Double(raw)))
        }
        switch level {
        case .normal: return 35
        case .warning: return 72
        case .critical: return 94
        case .unknown: return 0
        }
    }

    /// statfs on the boot volume for space + filesystem type, plus IOKit
    /// byte counters delta'd into live read/write rates.
    ///
    /// total = every block, free = blocks available to the user, used = rest.
    /// `df`'s per-volume "used" hides other APFS volumes and snapshots.
    public func disk() -> DiskSnapshot {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return DiskSnapshot() }
        let bsize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * bsize
        let free = UInt64(fs.f_bavail) * bsize
        let used = total > free ? total - free : 0
        let pct = total > 0 ? Double(used) / Double(total) * 100 : 0

        let fsType = withUnsafeBytes(of: fs.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self)).uppercased()
        }

        let (readTotal, writeTotal) = diskIOBytes()
        let now = DispatchTime.now().uptimeNanoseconds
        var readRate = 0.0, writeRate = 0.0
        if prevDiskWall != 0 {
            let secs = Double(now &- prevDiskWall) / 1_000_000_000
            if secs > 0 {
                readRate = Double(readTotal &- prevDiskRead) / secs
                writeRate = Double(writeTotal &- prevDiskWrite) / secs
            }
        }
        prevDiskRead = readTotal
        prevDiskWrite = writeTotal
        prevDiskWall = now

        return DiskSnapshot(total: total, free: free, used: used, usedPercent: pct,
                            readRate: readRate, writeRate: writeRate, fsType: fsType)
    }

    /// Sum cumulative read/write bytes across every IOBlockStorageDriver.
    private func diskIOBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &unmanaged,
                                                 kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = unmanaged?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                read += uintValue(stats["Bytes (Read)"])
                write += uintValue(stats["Bytes (Write)"])
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }

    /// One getifaddrs walk: AF_LINK entries give byte counters (→ rates),
    /// AF_INET entries give the local IP and reveal VPN tunnels. SSID comes
    /// from CoreWLAN (nil without Location permission on recent macOS).
    public func network() -> NetSnapshot {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return NetSnapshot() }
        defer { freeifaddrs(head) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var localIP = ""
        var primaryInterface = ""
        var vpnActive = false

        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = node {
            defer { node = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard let addr = cur.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_LINK), name != "lo0", let raw = cur.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                totalIn += UInt64(data.ifi_ibytes)
                totalOut += UInt64(data.ifi_obytes)
            } else if family == UInt8(AF_INET) {
                if name.hasPrefix("utun") || name.hasPrefix("ppp")
                    || name.hasPrefix("ipsec") {
                    vpnActive = true
                } else if name != "lo0", localIP.isEmpty, let ip = ipv4String(addr) {
                    localIP = ip
                    primaryInterface = name
                }
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var snap = NetSnapshot()
        if prevNetWall != 0 {
            let secs = Double(now &- prevNetWall) / 1_000_000_000
            if secs > 0 {
                snap.down = Double(totalIn &- prevNetIn) / secs
                snap.up = Double(totalOut &- prevNetOut) / secs
            }
        }
        prevNetIn = totalIn
        prevNetOut = totalOut
        prevNetWall = now

        snap.localIP = localIP
        snap.interface = primaryInterface
        snap.vpnActive = vpnActive
        if let wifi = CWWiFiClient.shared().interface(), let ssid = wifi.ssid() {
            snap.ssid = ssid
        }
        return snap
    }

    /// Static machine info from sysctl — call once.
    public func hardware() -> HardwareInfo {
        var memBytes: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memBytes, &memSize, nil, 0)

        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0)

        let v = ProcessInfo.processInfo.operatingSystemVersion

        return HardwareInfo(
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryGB: Int((Double(memBytes) / 1_073_741_824).rounded()),
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion)",
            pCores: sysctlInt("hw.perflevel0.physicalcpu"),
            eCores: sysctlInt("hw.perflevel1.physicalcpu"),
            bootTime: Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))
    }
}

// MARK: - sysctl helpers

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}

/// Numeric host string for an IPv4 sockaddr.
private func ipv4String(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                             &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    return result == 0 ? String(cString: host) : nil
}

/// Registry numbers arrive as NSNumber/Int — coerce to UInt64.
private func uintValue(_ any: Any?) -> UInt64 {
    if let n = any as? NSNumber { return n.uint64Value }
    if let n = any as? UInt64 { return n }
    if let n = any as? Int { return UInt64(max(0, n)) }
    return 0
}

private func sysctlInt(_ name: String) -> Int {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return 0 }
    if size == 4 {
        var value: UInt32 = 0
        sysctlbyname(name, &value, &size, nil, 0)
        return Int(value)
    }
    if size == 8 {
        var value: UInt64 = 0
        sysctlbyname(name, &value, &size, nil, 0)
        return Int(value)
    }
    return 0
}
