// FanBoost helper — fan discovery and SMC writes. GPL-2.0.
// NOT thread-safe on its own: all access is serialized on the helper's
// single controller queue (see main.swift).
import Foundation

struct Fan {
    let index: Int
    let minRPM: Double
    let maxRPM: Double
}

final class FanController {
    /// FANBOOST_DRY_RUN=1: log every write instead of touching the SMC.
    let dryRun = ProcessInfo.processInfo.environment["FANBOOST_DRY_RUN"] == "1"
    /// Fans the SMC enumerates (FNum) — restore must cover ALL of these…
    private(set) var fanCount = 0
    /// …while boost additionally needs a successfully read range per fan.
    private(set) var fans: [Fan] = []
    private(set) var boosting = false

    // Dry-run failure injection + counters for --dryrun-check.
    var simulatedResult: [String: Int] = [:]
    private(set) var ftstWrites = 0

    init() {
        if dryRun {
            // Two unequal fake fans exercise multi-fan fan-out and clamping.
            fanCount = 2
            fans = [Fan(index: 0, minRPM: 1700, maxRPM: 5000),
                    Fan(index: 1, minRPM: 2160, maxRPM: 6800)]
            log("dry-run: simulating \(fanCount) fans")
            return
        }
        guard fb_smc_open() == 0 else { log("SMC open failed"); return }
        var count: UInt8 = 0
        guard fb_read_u8("FNum", &count) == 0 else { log("FNum read failed"); return }
        fanCount = Int(count)
        fans = (0..<fanCount).compactMap { i in
            var lo: Float = 0, hi: Float = 0
            guard fb_read_flt("F\(i)Mn", &lo) == 0,
                  fb_read_flt("F\(i)Mx", &hi) == 0,
                  hi > lo else { log("fan \(i): range read failed"); return nil }
            return Fan(index: i, minRPM: Double(lo), maxRPM: Double(hi))
        }
        log("discovered \(fans.count)/\(fanCount) fan(s): \(rangesDescription)")
    }

    var rangesDescription: String {
        if fanCount == 0 { return "no fans (fanless Mac)" }
        return fans.map { "fan \($0.index): \(Int($0.minRPM))–\(Int($0.maxRPM)) RPM" }
                   .joined(separator: ", ")
    }

    /// Returns nil on success, else an error description. Refuses fanless
    /// AND incomplete discovery — boosting a fan whose range we could not
    /// read would mean guessing at safe RPM bounds.
    func boost(percent: Double) -> String? {
        guard fanCount > 0 else { return "no fans to control" }
        guard fans.count == fanCount else {
            return "incomplete fan discovery (\(fans.count)/\(fanCount)) — refusing to boost"
        }
        for fan in fans {
            let rpm = targetRPM(percent: percent, min: fan.minRPM, max: fan.maxRPM)
            guard setMode(fan.index, forced: true) else {
                restoreAuto() // never leave a half-boosted mixed state
                return "F\(fan.index)Md write failed"
            }
            guard write("F\(fan.index)Tg", fltHex(rpm)) == 0 else {
                restoreAuto()
                return "F\(fan.index)Tg write failed"
            }
            log("fan \(fan.index) forced to \(Int(rpm)) RPM (\(Int(percent))%)")
        }
        boosting = true
        return nil
    }

    /// Writes auto mode to every ENUMERATED fan index, not just the ones with
    /// readable ranges — a fan we couldn't fully discover must still be
    /// returned to automatic control on startup/restore.
    func restoreAuto() {
        for index in 0..<fanCount { _ = write("F\(index)Md", "00") }
        if boosting || dryRun { log("restored automatic fan control") }
        boosting = false
    }

    private func setMode(_ index: Int, forced: Bool) -> Bool {
        let result = write("F\(index)Md", forced ? "01" : "00")
        if result == 0 { return true }
        // Only SMC status 0x82 means "manual mode locked" (M3+); any other
        // failure is not something Ftst can fix.
        guard forced, result == 0x82 else { return false }
        log("F\(index)Md rejected with 0x82 — trying Ftst unlock (M3+ path)")
        _ = write("Ftst", "01")
        if !dryRun { Thread.sleep(forTimeInterval: 3) }
        return write("F\(index)Md", "01") == 0
    }

    /// 0 = success, -1 = transport failure, else raw SMC status byte.
    private func write(_ key: String, _ hex: String) -> Int {
        if dryRun {
            if key == "Ftst" {
                ftstWrites += 1
                simulatedResult = [:] // simulate a successful unlock
            }
            let result = simulatedResult[key] ?? 0
            log("dry-run write \(key) = \(hex) -> \(result)")
            return result
        }
        return Int(fb_write_hex(key, hex))
    }
}

func log(_ message: String) {
    NSLog("FanBoostHelper: %@", message)
}
