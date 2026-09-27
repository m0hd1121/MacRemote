#if os(macOS)
import Foundation
import IOKit
import IOKit.ps
import AlwaysOnCore

public struct PowerReading: Equatable, Sendable {
    public var source: PowerSourceKind = .unknown
    public var hasBattery = false
    public var percent: Int?
    public var isCharging: Bool?
    public var isCharged: Bool?
    public var timeToEmptyMinutes: Int?
    public var health: String?

    public init() {}
}

/// Reads the IOKit power-source snapshot (`IOPSCopyPowerSourcesInfo`). Unprivileged.
public enum PowerSourceReader {
    // Keys from IOPSKeys.h, spelled out so we do not depend on macro import behaviour.
    private static let typeKey = "Type"
    private static let internalBattery = "InternalBattery"
    private static let currentCapacityKey = "Current Capacity"
    private static let maxCapacityKey = "Max Capacity"
    private static let isChargingKey = "Is Charging"
    private static let isChargedKey = "Is Charged"
    private static let timeToEmptyKey = "Time to Empty"
    private static let healthKey = "BatteryHealth"
    private static let powerSourceStateKey = "Power Source State"

    public static func read() -> PowerReading {
        var reading = PowerReading()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return reading }

        if let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            reading.source = kind(providing)
        }

        let list: [AnyObject] = IOPSCopyPowerSourcesList(blob).map { $0.takeRetainedValue() as Array } ?? []
        for ps in list {
            guard let raw = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue(),
                  let desc = raw as NSDictionary as? [String: Any] else { continue }
            guard (desc[typeKey] as? String) == internalBattery else { continue }
            reading.hasBattery = true
            if let current = desc[currentCapacityKey] as? Int, let max = desc[maxCapacityKey] as? Int, max > 0 {
                reading.percent = Int((Double(current) / Double(max) * 100).rounded())
            }
            reading.isCharging = desc[isChargingKey] as? Bool
            reading.isCharged = desc[isChargedKey] as? Bool
            if let minutes = desc[timeToEmptyKey] as? Int, minutes > 0 { reading.timeToEmptyMinutes = minutes }
            reading.health = desc[healthKey] as? String
            if reading.source == .unknown, let state = desc[powerSourceStateKey] as? String {
                reading.source = kind(state)
            }
        }
        if reading.source == .unknown && !reading.hasBattery {
            // Desktop Macs report no power sources; they are always on mains power.
            reading.source = .ac
        }
        return reading
    }

    private static func kind(_ value: String) -> PowerSourceKind {
        switch value {
        case "AC Power": return .ac
        case "Battery Power": return .battery
        case "UPS Power": return .ups
        default: return .unknown
        }
    }
}

/// Event-driven power-source change notifications (no polling).
public final class PowerSourceMonitor {
    private var runLoopSource: CFRunLoopSource?
    private let handler: () -> Void

    public init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    /// Must be called on a thread whose run loop runs (the main thread in our executables).
    public func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            Unmanaged<PowerSourceMonitor>.fromOpaque(ctx).takeUnretainedValue().handler()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        runLoopSource = source
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            runLoopSource = nil
        }
    }
}

/// Reads IOPMrootDomain / AppleSmartBattery registry properties. Unprivileged.
public enum PowerRegistry {
    public static func rootDomainProperty(_ key: String) -> Any? {
        property(serviceClass: "IOPMrootDomain", key: key)
    }

    public static func lidState() -> LidState {
        guard let value = rootDomainProperty("AppleClamshellState") else { return .notPresent }
        guard let closed = value as? Bool else { return .unknown }
        return closed ? .closed : .open
    }

    /// `AppleClamshellCausesSleep`: whether closing the lid would sleep the Mac right now.
    public static func clamshellCausesSleep() -> Bool? {
        rootDomainProperty("AppleClamshellCausesSleep") as? Bool
    }

    public static func batteryCycleCount() -> Int? {
        property(serviceClass: "AppleSmartBattery", key: "CycleCount") as? Int
    }

    private static func property(serviceClass: String, key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

public enum ThermalReader {
    public static func current() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
#endif
