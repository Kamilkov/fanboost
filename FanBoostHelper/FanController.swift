// FanBoost helper — fan discovery and SMC writes. GPL-2.0.
// NOT thread-safe on its own: all access is serialized on the helper's
// single controller queue (see main.swift).
import Foundation

struct Fan {
    let index: Int
    let minRPM: Double
    let maxRPM: Double
}

/// Discovery outcome. `unavailable` (SMC open or FNum errored) is deliberately
/// distinct from `fanless` (FNum succeeded and reported zero fans) so a
/// transient failure is never reported as a permanent fanless Mac.
enum Discovery {
    case available
    case fanless
    case unavailable
}

final class FanController {
    /// FANBOOST_DRY_RUN=1: log every write instead of touching the SMC.
    let dryRun = ProcessInfo.processInfo.environment["FANBOOST_DRY_RUN"] == "1"
    private(set) var discovery: Discovery = .unavailable
    /// Fans the SMC enumerates (FNum) — restore must cover ALL of these…
    private(set) var fanCount = 0
    /// …while boost additionally needs a successfully read range per fan.
    private(set) var fans: [Fan] = []
    private(set) var boosting = false

    // Dry-run failure injection + counters for --dryrun-check.
    var simulatedResult: [String: Int] = [:]
    var simulatedOpenFail = false
    var simulatedFNumFail = false
    var simulatedFNumZero = false
    var simulatedIncomplete = false   // FNum ok, but a fan range fails to read
    var simulatedRestoreFail = false  // F{n}Md auto-mode writes fail
    private(set) var ftstWrites = 0

    /// True when we owe a successful return-to-auto that has not yet been
    /// confirmed (restore attempted while unavailable, or an auto write failed).
    /// The recovery timer retries until this clears.
    private(set) var pendingRestore = false

    init() { attemptDiscovery() }

    /// Enumerated fan count from FNum, retained even when ranges are
    /// incomplete so restore can still write auto to every index. Distinct
    /// from `fans`, which requires a successfully read range per fan.
    private(set) var enumeratedCount = 0

    /// Mark discovery failed: forget stale fan state so nothing downstream
    /// acts on data from a previous, now-invalid enumeration.
    private func markUnavailable(_ reason: String) {
        fanCount = 0; enumeratedCount = 0; fans = []; discovery = .unavailable
        log("\(reason) → unavailable")
    }

    /// (Re)enumerate fans. Safe to call repeatedly: closes any stale SMC
    /// handle before reopening so a half-open connection can't wedge recovery.
    func attemptDiscovery() {
        if dryRun {
            if simulatedOpenFail || simulatedFNumFail {
                markUnavailable("dry-run: simulated \(simulatedOpenFail ? "open" : "FNum") failure")
                return
            }
            if simulatedFNumZero {
                fanCount = 0; enumeratedCount = 0; fans = []; discovery = .fanless
                log("dry-run: simulated FNum=0 → fanless")
                return
            }
            if simulatedIncomplete {
                // FNum reports 2 but only one range reads: incomplete → retryable.
                enumeratedCount = 2; fanCount = 2; fans = []; discovery = .unavailable
                log("dry-run: simulated incomplete ranges (1/2) → unavailable")
                return
            }
            enumeratedCount = 2; fanCount = 2
            fans = [Fan(index: 0, minRPM: 1700, maxRPM: 5000),
                    Fan(index: 1, minRPM: 2160, maxRPM: 6800)]
            discovery = .available
            log("dry-run: simulating \(fanCount) fans")
            return
        }

        fb_smc_reset() // clear any stale handle before reopen
        guard fb_smc_open() == 0 else { markUnavailable("SMC open failed"); return }
        var count: UInt8 = 0
        guard fb_read_u8("FNum", &count) == 0 else { markUnavailable("FNum read failed"); return }
        enumeratedCount = Int(count)
        fanCount = Int(count)
        if count == 0 { fans = []; discovery = .fanless; log("discovered 0 fans → fanless"); return }
        let discovered: [Fan] = (0..<Int(count)).compactMap { i in
            var lo: Float = 0, hi: Float = 0
            guard fb_read_flt("F\(i)Mn", &lo) == 0,
                  fb_read_flt("F\(i)Mx", &hi) == 0,
                  hi > lo else { log("fan \(i): range read failed"); return nil }
            return Fan(index: i, minRPM: Double(lo), maxRPM: Double(hi))
        }
        if discovered.count == Int(count) {
            fans = discovered; discovery = .available
            log("discovered \(fans.count)/\(fanCount) fan(s): \(rangesDescription)")
        } else {
            // Incomplete: keep enumeratedCount/fanCount for restore, but treat
            // as unavailable (retryable) so we never boost on partial data.
            fans = []; discovery = .unavailable
            log("incomplete ranges (\(discovered.count)/\(count)) → unavailable, will retry")
        }
    }

    var rangesDescription: String {
        switch discovery {
        case .unavailable: return "fan state unknown"
        case .fanless: return "no fans (fanless Mac)"
        case .available:
            return fans.map { "fan \($0.index): \(Int($0.minRPM))–\(Int($0.maxRPM)) RPM" }
                       .joined(separator: ", ")
        }
    }

    /// Returns nil on success, else an error description. Refuses unavailable,
    /// fanless, AND incomplete discovery — boosting a fan whose range we could
    /// not read would mean guessing at safe RPM bounds.
    func boost(percent: Double) -> String? {
        switch discovery {
        case .unavailable: return "fan state unavailable — refusing to boost"
        case .fanless: return "no fans to control"
        case .available: break
        }
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

    /// Return every enumerated fan to automatic mode. A REAL checked
    /// operation: returns nil only when the restore is confirmed. If discovery
    /// is unavailable, or any `F{n}Md` auto write fails, `boosting` stays set,
    /// `pendingRestore` is set, and an error is returned so the caller/recovery
    /// timer retries. `boosting`/`pendingRestore` clear only on full success.
    @discardableResult
    func restoreAuto() -> String? {
        if discovery == .unavailable {
            pendingRestore = true
            return "fan state unavailable — restore deferred, will retry"
        }
        var failed = false
        for index in 0..<enumeratedCount where write("F\(index)Md", "00") != 0 {
            failed = true
        }
        if failed {
            pendingRestore = true
            return "auto-mode write failed for one or more fans — will retry"
        }
        boosting = false
        pendingRestore = false
        log("restored automatic fan control")
        return nil
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
            if simulatedRestoreFail, hex == "00" { // auto-mode write
                log("dry-run restore write \(key) forced-fail")
                return 0x50
            }
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
