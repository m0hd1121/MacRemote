#if os(macOS)
import AppKit

enum NSRunningApplicationLookup {
    static func running(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }
}
#endif
