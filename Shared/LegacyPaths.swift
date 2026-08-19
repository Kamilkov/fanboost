// FanBoost — exact paths of the obsolete capture-fan prototype's artifacts.
// Shared so the app (detection + user LaunchAgent removal) and the helper
// (root sudoers/smc removal) agree on the same constants. GPL-2.0.
import Foundation

public enum LegacyPaths {
    public static let agentLabel = "com.kamilkovac.capture-fan"
    /// User LaunchAgent, absolute (resolved against the caller's home).
    public static var userAgent: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.kamilkovac.capture-fan.plist"
    }
    public static let sudoers = "/etc/sudoers.d/capture-fan"
    public static let smc = "/usr/local/libexec/capture-fan/smc"
    public static let smcDir = "/usr/local/libexec/capture-fan"
}
