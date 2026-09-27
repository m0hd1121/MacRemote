import Foundation

/// How a supervised process ended.
public struct ExitInfo: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case exited
        case signaled
        /// An `.app` that disappeared without us asking (no exit code is available).
        case vanished
    }

    public var reason: Reason
    /// Exit status for `.exited`, signal number for `.signaled`, 0 for `.vanished`.
    public var code: Int32
    /// True when the supervisor requested the stop.
    public var requested: Bool

    public init(reason: Reason, code: Int32, requested: Bool) {
        self.reason = reason
        self.code = code
        self.requested = requested
    }

    public var isCrash: Bool {
        guard !requested else { return false }
        switch reason {
        case .exited: return code != 0
        case .signaled, .vanished: return true
        }
    }

    public var description: String {
        let base: String
        switch reason {
        case .exited: base = "exited with status \(code)"
        case .signaled: base = "terminated by signal \(code)\(Self.signalName(code).map { " (\($0))" } ?? "")"
        case .vanished: base = "quit unexpectedly"
        }
        return requested ? "\(base) after stop request" : base
    }

    static func signalName(_ signal: Int32) -> String? {
        switch signal {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        case 15: return "SIGTERM"
        default: return nil
        }
    }
}

public enum ExitAction: Equatable, Sendable {
    case none
    case restart(after: Double)
    case giveUp
}

/// Pure state machine for one supervised service. The supervisor owns the side effects.
public struct ServiceRuntime: Sendable {
    public var spec: ServiceSpec
    public private(set) var state: ServiceState = .stopped
    public private(set) var pid: Int32?
    public private(set) var lastLaunchAt: Date?
    public private(set) var lastExitAt: Date?
    public private(set) var lastCrashAt: Date?
    public private(set) var lastExitDescription: String?
    /// Total automatic restarts since the agent started.
    public private(set) var restartCount = 0
    public private(set) var consecutiveFailures = 0
    public private(set) var recentRestarts: [Date] = []
    public private(set) var nextRestartAt: Date?
    /// Set by a manual stop; suppresses automatic starts until a manual start.
    public private(set) var manuallyStopped = false
    public var note: String?

    public init(spec: ServiceSpec) {
        self.spec = spec
    }

    public var isActive: Bool { state == .starting || state == .running }

    public mutating func markLaunching(now: Date) {
        state = .starting
        lastLaunchAt = now
        nextRestartAt = nil
        note = nil
    }

    public mutating func markRunning(pid: Int32) {
        state = .running
        self.pid = pid
    }

    /// Adopt an already running instance (e.g. an `.app` still open after the agent restarted).
    public mutating func adopt(pid: Int32, now: Date) {
        state = .running
        self.pid = pid
        if lastLaunchAt == nil { lastLaunchAt = now }
        note = "Adopted running instance"
    }

    public mutating func markLaunchFailed(error: String, now: Date, random: () -> Double = { Double.random(in: 0..<1) }) -> ExitAction {
        pid = nil
        lastExitAt = now
        lastCrashAt = now
        lastExitDescription = "launch failed: \(error)"
        return scheduleRestartOrGiveUp(now: now, random: random)
    }

    public mutating func handleExit(_ info: ExitInfo, now: Date, random: () -> Double = { Double.random(in: 0..<1) }) -> ExitAction {
        pid = nil
        lastExitAt = now
        lastExitDescription = info.description

        if let launched = lastLaunchAt, now.timeIntervalSince(launched) >= spec.backoff.stableAfterSeconds {
            consecutiveFailures = 0
        }

        if info.requested {
            if state != .suspended { state = .stopped }
            nextRestartAt = nil
            return .none
        }

        if info.isCrash { lastCrashAt = now }

        let shouldRestart: Bool
        switch spec.restartPolicy {
        case .never: shouldRestart = false
        case .onCrash: shouldRestart = info.isCrash
        case .always: shouldRestart = true
        }

        guard shouldRestart, !manuallyStopped else {
            state = info.isCrash ? .crashed : .stopped
            nextRestartAt = nil
            return .none
        }
        return scheduleRestartOrGiveUp(now: now, random: random)
    }

    private mutating func scheduleRestartOrGiveUp(now: Date, random: () -> Double) -> ExitAction {
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < spec.backoff.windowSeconds }
        if recentRestarts.count >= spec.backoff.maxRestartsInWindow {
            state = .failed
            nextRestartAt = nil
            note = "Gave up after \(recentRestarts.count) restarts within \(Int(spec.backoff.windowSeconds)) s. Start it manually after fixing the cause."
            return .giveUp
        }
        consecutiveFailures += 1
        let delay = Backoff.delay(attempt: consecutiveFailures, settings: spec.backoff, random: random)
        recentRestarts.append(now)
        restartCount += 1
        state = .restarting
        nextRestartAt = now.addingTimeInterval(delay)
        return .restart(after: delay)
    }

    public mutating func markManualStop() {
        manuallyStopped = true
        nextRestartAt = nil
        if !isActive { state = .stopped }
    }

    public mutating func markManualStart() {
        manuallyStopped = false
        recentRestarts.removeAll()
        consecutiveFailures = 0
        note = nil
        if state == .failed || state == .crashed { state = .stopped }
    }

    public mutating func markSuspended(reason: String) {
        state = .suspended
        nextRestartAt = nil
        note = reason
    }

    public mutating func markWaitingForNetwork() {
        state = .waitingForNetwork
        note = "Waiting for network"
    }

    public mutating func markStoppedIfIdle() {
        if !isActive && state != .failed && state != .crashed { state = .stopped }
    }

    public mutating func cancelPendingRestart() {
        nextRestartAt = nil
        if state == .restarting { state = .stopped }
    }
}
