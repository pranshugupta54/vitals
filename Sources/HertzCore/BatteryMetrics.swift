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
    public var adapterWatts: Int     // 0 when not on AC

    public init(present: Bool = false, percent: Double = 0, charging: Bool = false,
                onAC: Bool = false, minutesRemaining: Int = -1,
                healthPercent: Double = 0, cycleCount: Int = 0,
                temperature: Double = 0, adapterWatts: Int = 0) {
        self.present = present
        self.percent = percent
        self.charging = charging
        self.onAC = onAC
        self.minutesRemaining = minutesRemaining
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.temperature = temperature
        self.adapterWatts = adapterWatts
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
/// health/cycles/temperature/adapter from the AppleSmartBattery registry.
public final class BatteryMetrics {
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
        guard snap.present else { return snap }

        // --- health, cycle count, temperature, adapter wattage ---
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

/// Registry numbers arrive as Int or NSNumber depending on the key.
private func intValue(_ any: Any?) -> Int {
    if let n = any as? Int { return n }
    if let n = any as? NSNumber { return n.intValue }
    return 0
}
