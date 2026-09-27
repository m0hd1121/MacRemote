#if os(macOS)
import Foundation
import Darwin
import CoreGraphics
import AlwaysOnCore

/// Collects system-wide metrics with Mach / sysctl calls (no subprocesses).
public final class SystemMetrics {
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private let lock = NSLock()

    public init() {}

    public func collect() -> SystemStatus {
        var s = SystemStatus()
        s.model = Self.sysctlString("hw.model") ?? "Mac"
        s.osVersion = Self.osVersion()
        s.bootTime = Self.bootTime()
        s.cpuPercent = cpuPercent()
        let memory = Self.memory()
        s.memoryUsedBytes = memory.used
        s.memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
        s.memoryPressure = Self.memoryPressure()
        let disk = Self.disk()
        s.diskFreeBytes = disk.free
        s.diskTotalBytes = disk.total
        s.thermal = ThermalReader.current()
        s.externalDisplayConnected = Self.externalDisplayConnected()
        return s
    }

    /// System-wide CPU busy percentage since the previous call.
    public func cpuPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        lock.lock()
        defer { lock.unlock() }
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        let busyDelta = Double(busy &- previous.busy)
        let totalDelta = Double(total &- previous.total)
        return min(100, max(0, busyDelta / totalDelta * 100))
    }

    static func memory() -> (used: UInt64?, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (nil, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        // Approximates Activity Monitor's "Memory Used": app memory + wired + compressed.
        let appPages = UInt64(stats.internal_page_count) &- UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return (pages * UInt64(pageSize), total)
    }

    static func memoryPressure() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown (\(level))"
        }
    }

    static func disk() -> (free: UInt64?, total: UInt64?) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else {
            return (nil, nil)
        }
        let free = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        let total = values.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        return (free, total)
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion").map { " (\($0))" } ?? ""
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(build)"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// True if any online display is not the built-in panel.
    public static func externalDisplayConnected() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

/// Per-process CPU / memory / start time via libproc. Works unprivileged for the user's
/// own processes.
public final class MacProcessInspector: ProcessInspector {
    private var previous: [Int32: (cpu: UInt64, wall: UInt64)] = [:]
    private let lock = NSLock()

    public init() {}

    public func startTime(pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    public func sample(pid: Int32) -> ProcessSample? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            lock.lock()
            previous[pid] = nil
            lock.unlock()
            return nil
        }
        // ri_user_time / ri_system_time are in Mach absolute-time units on Apple Silicon
        // (nanoseconds on Intel); mach_absolute_time uses the same units, so the ratio needs
        // no timebase conversion on either architecture.
        let cpu = usage.ri_user_time + usage.ri_system_time
        let wall = mach_absolute_time()
        lock.lock()
        let last = previous[pid]
        previous[pid] = (cpu, wall)
        lock.unlock()
        var percent: Double?
        if let last, wall > last.wall, cpu >= last.cpu {
            percent = Double(cpu - last.cpu) / Double(wall - last.wall) * 100
        }
        return ProcessSample(cpuPercent: percent, memoryBytes: usage.ri_phys_footprint)
    }
}
#endif
