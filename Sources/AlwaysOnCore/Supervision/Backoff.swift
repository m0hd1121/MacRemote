import Foundation

public enum Backoff {
    /// Delay before attempt number `attempt` (1-based): `min(base * multiplier^(attempt-1), max)`
    /// with ± `jitterFraction` jitter. `random` returns a value in 0..<1 (injectable for tests).
    public static func delay(attempt: Int, base: Double, max maxDelay: Double, multiplier: Double = 2,
                             jitterFraction: Double = 0, random: () -> Double = { Double.random(in: 0..<1) }) -> Double {
        let n = Swift.max(attempt, 1) - 1
        // Cap the exponent so pow() cannot overflow for very large attempt counts.
        let raw = base * pow(Swift.max(multiplier, 1), Double(Swift.min(n, 64)))
        let capped = Swift.min(raw, maxDelay)
        guard jitterFraction > 0 else { return capped }
        let jitter = (random() * 2 - 1) * jitterFraction * capped
        return Swift.max(0, Swift.min(capped + jitter, maxDelay * (1 + jitterFraction)))
    }

    public static func delay(attempt: Int, settings: BackoffSettings,
                             random: () -> Double = { Double.random(in: 0..<1) }) -> Double {
        delay(attempt: attempt, base: settings.baseSeconds, max: settings.maxSeconds,
              multiplier: settings.multiplier, jitterFraction: settings.jitterFraction, random: random)
    }
}

/// Exponential backoff tracker for recurring recovery work (Tailscale, network probes).
public struct BackoffTracker: Sendable {
    public let base: Double
    public let max: Double
    public private(set) var failures = 0

    public init(base: Double, max: Double) {
        self.base = base
        self.max = max
    }

    public mutating func recordFailure() -> Double {
        failures += 1
        return Backoff.delay(attempt: failures, base: base, max: max, multiplier: 2, jitterFraction: 0.1)
    }

    public mutating func reset() { failures = 0 }
}
