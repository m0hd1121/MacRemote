import Foundation

/// What the power policy decided the system should currently do.
public enum EffectiveMode: String, Codable, Sendable {
    /// Always-On switched off by the user (or for this power source).
    case off
    /// Strongest supported behaviour on AC.
    case fullAC
    /// Always-On on battery.
    case fullBattery
    /// Networking kept alive, essential services only, no lid-closed override.
    case batterySaver
    /// Battery / thermal limit reached: normal macOS sleep behaviour.
    case relaxed
}

public struct PolicyDecision: Codable, Equatable, Sendable {
    public var mode: EffectiveMode
    public var preventIdleSleep: Bool
    /// `PreventSystemSleep` is only honoured by macOS on AC; the policy never asks for it on battery.
    public var preventSystemSleep: Bool
    public var preventDisplaySleep: Bool
    /// Ask the root helper to keep the Mac awake with the lid closed (`pmset disablesleep 1`).
    public var lidClosedOverride: Bool
    public var allowedPriorities: [ServicePriority]
    /// Plain-language explanation of each choice, shown in the UI and logs.
    public var reasons: [String]

    public init(mode: EffectiveMode, preventIdleSleep: Bool, preventSystemSleep: Bool, preventDisplaySleep: Bool,
                lidClosedOverride: Bool, allowedPriorities: [ServicePriority], reasons: [String]) {
        self.mode = mode
        self.preventIdleSleep = preventIdleSleep
        self.preventSystemSleep = preventSystemSleep
        self.preventDisplaySleep = preventDisplaySleep
        self.lidClosedOverride = lidClosedOverride
        self.allowedPriorities = allowedPriorities
        self.reasons = reasons
    }

    public static let inactive = PolicyDecision(
        mode: .off, preventIdleSleep: false, preventSystemSleep: false, preventDisplaySleep: false,
        lidClosedOverride: false, allowedPriorities: ServicePriority.allCases, reasons: ["Not evaluated yet."]
    )

    public func allows(_ priority: ServicePriority) -> Bool { allowedPriorities.contains(priority) }
}

public struct PolicyInputs: Equatable, Sendable {
    public var source: PowerSourceKind
    public var batteryPercent: Int?
    public var thermal: ThermalLevel
    /// Consecutive samples with system CPU above the configured limit.
    public var highCPUStreak: Int
    /// Whether the privileged helper is installed and reachable.
    public var helperAvailable: Bool

    public init(source: PowerSourceKind, batteryPercent: Int?, thermal: ThermalLevel = .nominal,
                highCPUStreak: Int = 0, helperAvailable: Bool = false) {
        self.source = source
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.highCPUStreak = highCPUStreak
        self.helperAvailable = helperAvailable
    }
}

/// State the policy carries between evaluations (hysteresis and latches).
public struct PolicyMemory: Codable, Equatable, Sendable {
    /// Battery dropped below the threshold and has not yet recovered past threshold + hysteresis.
    public var belowThreshold = false
    /// `disableAtThreshold` latched off; cleared when AC returns.
    public var latchedOffUntilAC = false

    public init() {}
}

public enum PowerPolicy {
    public static let highCPUStreakLimit = 3

    public static func evaluate(_ inputs: PolicyInputs, settings: PowerSettings, memory: inout PolicyMemory) -> PolicyDecision {
        var reasons: [String] = []
        let everything = ServicePriority.allCases
        let withoutIntensive: [ServicePriority] = [.essential, .normal]
        let essentialOnly: [ServicePriority] = [.essential]

        // Battery hysteresis is tracked whatever the mode, so switching modes never flaps.
        let onBattery = inputs.source == .battery
        if onBattery, let pct = inputs.batteryPercent {
            if memory.belowThreshold {
                if pct >= settings.batteryThresholdPercent + settings.hysteresisPercent { memory.belowThreshold = false }
            } else if pct < settings.batteryThresholdPercent {
                memory.belowThreshold = true
            }
        } else if !onBattery {
            memory.belowThreshold = false
            memory.latchedOffUntilAC = false
        }

        func lowBatteryPriorities() -> [ServicePriority] {
            settings.stopNonEssentialOnLowBattery ? essentialOnly : everything
        }

        func relaxed(_ why: String, priorities: [ServicePriority]) -> PolicyDecision {
            reasons.append(why)
            reasons.append("macOS may sleep normally; remote access is unavailable while the Mac sleeps.")
            return PolicyDecision(mode: .relaxed, preventIdleSleep: false, preventSystemSleep: false,
                                  preventDisplaySleep: false, lidClosedOverride: false,
                                  allowedPriorities: priorities, reasons: reasons)
        }

        if inputs.thermal == .critical {
            return relaxed("Thermal state is critical: Always-On is suspended to let the Mac cool down.",
                           priorities: essentialOnly)
        }

        guard settings.alwaysOnEnabled else {
            reasons.append("Always-On is turned off.")
            let priorities = onBattery && memory.belowThreshold ? lowBatteryPriorities() : everything
            if priorities != everything {
                reasons.append("Battery is below \(settings.batteryThresholdPercent)%: non-essential services stopped.")
            }
            return PolicyDecision(mode: .off, preventIdleSleep: false, preventSystemSleep: false,
                                  preventDisplaySleep: false, lidClosedOverride: false,
                                  allowedPriorities: priorities, reasons: reasons)
        }

        let thermalLimited = inputs.thermal >= settings.maxThermalLevel
        if thermalLimited {
            reasons.append("Thermal state is \(inputs.thermal.rawValue): intensive services are stopped.")
        }

        switch inputs.source {
        case .ac, .ups, .unknown:
            if inputs.source == .unknown {
                reasons.append("Power source unknown; treating as AC (desktop Mac or no battery information).")
            }
            guard settings.acModeEnabled else {
                reasons.append("Always-On is disabled for AC power.")
                return PolicyDecision(mode: .off, preventIdleSleep: false, preventSystemSleep: false,
                                      preventDisplaySleep: false, lidClosedOverride: false,
                                      allowedPriorities: everything, reasons: reasons)
            }
            reasons.append("On AC power: preventing idle sleep and system sleep.")
            let lid = lidOverride(settings: settings, inputs: inputs, onBattery: false, reasons: &reasons)
            return PolicyDecision(mode: .fullAC, preventIdleSleep: true, preventSystemSleep: true,
                                  preventDisplaySleep: settings.preventDisplaySleep, lidClosedOverride: lid,
                                  allowedPriorities: thermalLimited ? withoutIntensive : everything, reasons: reasons)

        case .battery:
            guard settings.batteryModeEnabled else {
                return relaxed("Always-On is disabled on battery.", priorities: memory.belowThreshold ? lowBatteryPriorities() : everything)
            }
            let pctText = inputs.batteryPercent.map { "\($0)%" } ?? "unknown"
            if inputs.batteryPercent == nil {
                reasons.append("Battery percentage unavailable; threshold rules cannot be applied.")
            }

            var mode = settings.batteryMode
            switch settings.batteryMode {
            case .alwaysOn:
                if memory.belowThreshold {
                    reasons.append("Battery \(pctText) is below \(settings.batteryThresholdPercent)%: switching from Always On to Battery Saver.")
                    mode = .batterySaver
                }
            case .batterySaver:
                if memory.belowThreshold {
                    return relaxed("Battery \(pctText) is below \(settings.batteryThresholdPercent)% in Battery Saver.",
                                   priorities: lowBatteryPriorities())
                }
            case .disableBelowThreshold:
                if memory.belowThreshold {
                    return relaxed("Battery \(pctText) is below \(settings.batteryThresholdPercent)%: Always-On disabled until it recovers to \(settings.batteryThresholdPercent + settings.hysteresisPercent)%.",
                                   priorities: lowBatteryPriorities())
                }
            case .disableAtThreshold:
                if let pct = inputs.batteryPercent, pct <= settings.batteryThresholdPercent {
                    memory.latchedOffUntilAC = true
                }
                if memory.latchedOffUntilAC {
                    return relaxed("Battery reached \(settings.batteryThresholdPercent)%: Always-On disabled until AC power returns.",
                                   priorities: lowBatteryPriorities())
                }
            }

            let cpuLimited = inputs.highCPUStreak >= highCPUStreakLimit
            if cpuLimited {
                reasons.append("System CPU above \(settings.maxCPUPercentOnBattery)% on battery: intensive services are stopped.")
            }
            let limited = thermalLimited || cpuLimited

            if mode == .batterySaver {
                reasons.append("Battery Saver on battery (\(pctText)): networking kept alive, essential services only, no lid-closed override.")
                return PolicyDecision(mode: .batterySaver, preventIdleSleep: true, preventSystemSleep: false,
                                      preventDisplaySleep: false, lidClosedOverride: false,
                                      allowedPriorities: essentialOnly, reasons: reasons)
            }

            reasons.append("On battery (\(pctText)): preventing idle sleep. macOS ignores system-sleep assertions on battery.")
            let lid = lidOverride(settings: settings, inputs: inputs, onBattery: true, reasons: &reasons)
            return PolicyDecision(mode: .fullBattery, preventIdleSleep: true, preventSystemSleep: false,
                                  preventDisplaySleep: settings.preventDisplaySleep, lidClosedOverride: lid,
                                  allowedPriorities: limited ? withoutIntensive : everything, reasons: reasons)
        }
    }

    private static func lidOverride(settings: PowerSettings, inputs: PolicyInputs, onBattery: Bool,
                                    reasons: inout [String]) -> Bool {
        guard settings.lidClosedOperation else { return false }
        guard inputs.helperAvailable else {
            reasons.append("Lid-closed operation is enabled but the privileged helper is not installed; closing the lid without an external display will sleep the Mac.")
            return false
        }
        if onBattery {
            guard settings.lidClosedOnBattery else {
                reasons.append("Lid-closed operation is not allowed on battery (setting); closing the lid will sleep the Mac.")
                return false
            }
            if let pct = inputs.batteryPercent, pct <= settings.helperBatteryFloorPercent {
                reasons.append("Battery \(pct)% is at or below the lid-closed floor of \(settings.helperBatteryFloorPercent)%.")
                return false
            }
            if inputs.batteryPercent == nil {
                reasons.append("Battery percentage unknown: lid-closed operation on battery withheld for safety.")
                return false
            }
            if inputs.thermal >= settings.maxThermalLevel {
                reasons.append("Thermal state \(inputs.thermal.rawValue): lid-closed operation on battery withheld.")
                return false
            }
        }
        reasons.append("Lid-closed operation active via privileged helper (pmset disablesleep).")
        return true
    }
}
