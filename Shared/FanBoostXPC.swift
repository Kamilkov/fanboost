// FanBoost — XPC contract between the menu-bar app and the root helper.
// GPL-2.0.
import Foundation

public let kHelperMachService = "com.kamilkovac.FanBoostHelper.xpc"
public let kHelperPlistName = "com.kamilkovac.FanBoostHelper.plist"

@objc public protocol FanBoostXPC {
    /// reply(fanCount, humanReadableRanges, currentlyBoosting)
    func status(reply: @escaping (Int32, String, Bool) -> Void)
    /// percent of each fan's own min→max range; reply(nil) on success,
    /// reply(errorDescription) on failure.
    func boost(percent: Double, reply: @escaping (String?) -> Void)
    func restoreAuto(reply: @escaping (String?) -> Void)
    /// Dead-man keep-alive; the app calls this every ≤15 s while boosted.
    func ping()
}
