// FanBoost — pure fan math, shared by app, helper, and self-checks. GPL-2.0.
import Foundation

/// Clamp percent to 0–100 and map it onto [min, max] RPM.
public func targetRPM(percent: Double, min lo: Double, max hi: Double) -> Double {
    let p = Swift.min(100.0, Swift.max(0.0, percent)) / 100.0
    let rpm = lo + p * (hi - lo)
    return Swift.min(hi, Swift.max(lo, rpm))
}

/// One clamped target per fan; empty input (fanless) yields an empty plan.
public func boostPlan(percent: Double, ranges: [(min: Double, max: Double)]) -> [Double] {
    ranges.map { targetRPM(percent: percent, min: $0.min, max: $0.max) }
}

/// Encode an RPM as the SMC `flt` wire format: IEEE-754 single precision,
/// little-endian, as a hex string (what SMCWriteSimple expects).
public func fltHex(_ rpm: Double) -> String {
    withUnsafeBytes(of: Float(rpm).bitPattern.littleEndian) { raw in
        raw.map { String(format: "%02x", $0) }.joined()
    }
}
