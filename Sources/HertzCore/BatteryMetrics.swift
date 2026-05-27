import Foundation
import IOKit
import IOKit.ps

/// Battery state. `present` is false on desktop Macs.
public struct BatterySnapshot {
    public var present: Bool
    public var percent: Double
    public var charging: Bool       // actively charging
    public var onAC: Bool           // plugged into power
    public var minutesRemaining: Int // -1 = unknown / still calculating
    public var healthPercent: Double // current max capacity vs design
    public var cycleCount: Int
    public var temperature: Double   // °C
    public var powerWatts: Double    // + charging, - discharging
    public var adapterWatts: Int     // 0 when not on AC
    public var acMinutes: Int        // minutes on AC, -1 if not on AC / unknown

    public init(present: Bool = false, percent: Double = 0, charging: Bool = false,
                onAC: Bool = false, minutesRemaining: Int = -1,
                healthPercent: Double = 0, cycleCount: Int = 0,
                temperature: Double = 0, powerWatts: Double = 0, adapterWatts: Int = 0,
                acMinutes: Int = -1) {
        self.present = present
        self.percent = percent
        self.charging = charging
        self.onAC = onAC
        self.minutesRemaining = minutesRemaining
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.temperature = temperature
        self.powerWatts = powerWatts
        self.adapterWatts = adapterWatts
        self.acMinutes = acMinutes
    }
}

/// Battery level of a connected Apple HID accessory (Magic Mouse, Keyboard,
/// Trackpad).
public struct DeviceBattery: Identifiable {
    public let name: String
    public let percent: Int
    public var id: String { name }
    public init(name: String, percent: Int) {
        self.name = name
        self.percent = percent
    }
}

/// Reads the battery: charge state from the power-sources API, and
/// health/cycles/temperature/power from the AppleSmartBattery registry.
public final class BatteryMetrics {
    // "Time on AC" — seeded once per AC session with the real plug-in time
    // from the power log. If that can't be read, it stays unknown (no value
    // is invented).
    private var acSince: Date?
    private var acLookupTried = false

    public init() {}

    public func read() -> BatterySnapshot {
        var snap = BatterySnapshot()

        // --- charge %, charging state, time remaining ---
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
            as? [CFTypeRef] {
            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                    let current = desc[kIOPSCurrentCapacityKey] as? Int,
                    let maximum = desc[kIOPSMaxCapacityKey] as? Int, maximum > 0
                else { continue }

                snap.present = true
                snap.percent = Double(current) / Double(maximum) * 100
                snap.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                snap.charging = desc[kIOPSIsChargingKey] as? Bool ?? false
                let key = snap.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                if let minutes = desc[key] as? Int, minutes >= 0 {
                    snap.minutesRemaining = minutes
                }
                break
            }
        }
        // --- time on AC ---
        if snap.onAC {
            // Look up the real plug-in time once per AC session. If the log
            // can't be read, leave it unknown — never invent a value.
            if !acLookupTried {
                acSince = acConnectedSince()
                acLookupTried = true
            }
        } else {
            acSince = nil
            acLookupTried = false
        }
        if let since = acSince {
            snap.acMinutes = max(0, Int(Date().timeIntervalSince(since) / 60))
        }

        guard snap.present else { return snap }

        // --- health, cycle count, temperature, battery/adapter wattage ---
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snap }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return snap }

        snap.cycleCount = intValue(dict["CycleCount"])

        let design = intValue(dict["DesignCapacity"])
        let rawMax = intValue(dict["AppleRawMaxCapacity"])
        let maxCapacity = rawMax != 0 ? rawMax : intValue(dict["MaxCapacity"])
        if design > 0 && maxCapacity > 0 {
            snap.healthPercent = min(100, Double(maxCapacity) / Double(design) * 100)
        }

        // Temperature is reported in hundredths of a degree Celsius.
        snap.temperature = Double(intValue(dict["Temperature"])) / 100.0

        let voltageMillivolts = intValue(dict["Voltage"])
        let currentMilliamps = batteryCurrentMilliamps(dict)
        if voltageMillivolts > 0, currentMilliamps != 0 {
            snap.powerWatts = Double(voltageMillivolts * currentMilliamps) / 1_000_000.0
        }

        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            snap.adapterWatts = intValue(adapter["Watts"])
        }
        return snap
    }

    /// Battery levels of connected Apple HID accessories — these expose a
    /// `BatteryPercent` property on their HID event service.
    public func accessories() -> [DeviceBattery] {
        var devices: [DeviceBattery] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &unmanaged,
                                                 kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = unmanaged?.takeRetainedValue() as? [String: Any] {
                let percent = intValue(dict["BatteryPercent"])
                if percent > 0 {
                    let name = (dict["Product"] as? String) ?? "Accessory"
                    devices.append(DeviceBattery(name: name, percent: percent))
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }
}

extension BatteryMetrics {
    /// The timestamp the Mac was last switched onto AC, parsed from the
    /// `pmset` power-management log. nil if it can't be determined.
    fileprivate func acConnectedSince() -> Date? {
        guard let log = runPmsetLog() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var onAC = false
        var sinceAC: Date?
        for line in log.split(separator: "\n") {
            let lower = line.lowercased()
            let isAC = lower.contains("using ac")
            let isBatt = lower.contains("using batt")
            guard isAC || isBatt,
                  let date = formatter.date(from: String(line.prefix(25)))
            else { continue }
            if isAC, !onAC {
                sinceAC = date // transitioned battery -> AC here
                onAC = true
            } else if isBatt {
                onAC = false
            }
        }
        return onAC ? sinceAC : nil
    }

    private func runPmsetLog() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// Registry numbers arrive as Int or NSNumber depending on the key.
private func intValue(_ any: Any?) -> Int {
    if let n = any as? Int { return n }
    if let n = any as? NSNumber { return n.intValue }
    return 0
}

private func batteryCurrentMilliamps(_ dict: [String: Any]) -> Int {
    let instant = intValue(dict["InstantAmperage"])
    if instant != 0 { return instant }
    return intValue(dict["Amperage"])
}
