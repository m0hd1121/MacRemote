#if os(macOS)
import Foundation
import IOKit
import IOKit.pwr_mgt
import AlwaysOnCore

/// System sleep / wake notifications via `IORegisterForSystemPower`.
///
/// We always acknowledge sleep immediately: this monitor records what happened, it never
/// vetoes or delays sleep. Idle sleep is prevented with assertions instead.
public final class SleepWakeMonitor {
    public enum Event: Sendable {
        case willSleep
        case willPowerOn
        case didWake
    }

    // iokit_common_msg() values from IOMessage.h (function-like macros are not imported).
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemWillNotSleep: UInt32 = 0xE000_0290
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300
    private static let systemWillPowerOn: UInt32 = 0xE000_0320

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let handler: (Event) -> Void

    public init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    /// Registers on the main run loop. Returns false if registration failed.
    @discardableResult
    public func start() -> Bool {
        guard rootPort == 0 else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<SleepWakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType: messageType, argument: messageArgument)
        }
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, callback, &notifier)
        guard rootPort != 0, let port = notifyPort else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), CFRunLoopMode.defaultMode)
        return true
    }

    public func stop() {
        guard rootPort != 0 else { return }
        if let port = notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), CFRunLoopMode.defaultMode)
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let port = notifyPort { IONotificationPortDestroy(port) }
        rootPort = 0
        notifyPort = nil
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            handler(.willSleep)
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillPowerOn:
            handler(.willPowerOn)
        case Self.systemHasPoweredOn:
            handler(.didWake)
        case Self.systemWillNotSleep:
            break
        default:
            break
        }
    }
}

/// Holds IOPM power assertions. Every assertion is named so it is visible in
/// `pmset -g assertions` and Activity Monitor.
public final class AssertionManager {
    public enum Kind: String, CaseIterable, Sendable {
        case preventIdleSleep = "PreventUserIdleSystemSleep"
        case preventSystemSleep = "PreventSystemSleep"
        case preventDisplaySleep = "PreventUserIdleDisplaySleep"
    }

    private var held: [Kind: IOPMAssertionID] = [:]
    private let lock = NSLock()
    private let name: String

    public init(name: String = "MacAlwaysOn: Always-On mode") {
        self.name = name
    }

    deinit { releaseAll() }

    /// Takes or releases an assertion. Returns an error message if creation failed.
    @discardableResult
    public func set(_ kind: Kind, held wanted: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if wanted {
            guard held[kind] == nil else { return nil }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kind.rawValue as CFString, IOPMAssertionLevel(255), name as CFString, &id)
            guard result == kIOReturnSuccess else {
                return "IOPMAssertionCreateWithName(\(kind.rawValue)) failed with 0x\(String(UInt32(bitPattern: result), radix: 16))"
            }
            held[kind] = id
        } else if let id = held.removeValue(forKey: kind) {
            IOPMAssertionRelease(id)
        }
        return nil
    }

    public func isHeld(_ kind: Kind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held[kind] != nil
    }

    public func releaseAll() {
        lock.lock()
        let ids = held
        held.removeAll()
        lock.unlock()
        for (_, id) in ids { IOPMAssertionRelease(id) }
    }

    public var status: AssertionStatus {
        var s = AssertionStatus()
        s.idleSleepPrevented = isHeld(.preventIdleSleep)
        s.systemSleepPrevented = isHeld(.preventSystemSleep)
        s.displaySleepPrevented = isHeld(.preventDisplaySleep)
        return s
    }
}
#endif
