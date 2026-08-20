// FanBoost self-check: pure fan math. GPL-2.0.
// Run: swiftc Shared/FanMath.swift checks/main.swift -o build/selfcheck && ./build/selfcheck

// Clamping onto a single fan's range (the prototype Mac mini's real range).
assert(targetRPM(percent: 0, min: 1700, max: 5000) == 1700)
assert(targetRPM(percent: 100, min: 1700, max: 5000) == 5000)
assert(targetRPM(percent: 150, min: 1700, max: 5000) == 5000, "over-100 clamps to max")
assert(targetRPM(percent: -5, min: 1700, max: 5000) == 1700, "negative clamps to min")
let mid = targetRPM(percent: 50, min: 1700, max: 5000)
assert(mid == 3350, "midpoint of 1700–5000, got \(mid)")

// SMC flt wire encoding — cross-checked against live SMC reads on the M2 Pro
// (F0Mn=1700 read back as bytes 00 80 d4 44; prototype wrote 3800 as 00806d45).
assert(fltHex(3800) == "00806d45")
assert(fltHex(1700) == "0080d444")
assert(fltHex(5000) == "00409c45")

// Multi-fan fan-out: each fan clamps within its own range.
let plan = boostPlan(percent: 80, ranges: [(1700, 5000), (2160, 6800)])
assert(plan.count == 2)
assert(plan[0] == 1700 + 0.8 * 3300)
assert(plan[1] == 2160 + 0.8 * 4640)

// Fanless: empty plan, nothing to write.
assert(boostPlan(percent: 80, ranges: []).isEmpty)

// Menu-bar compact RPM parsing: highest live reading wins; range-only
// fallback, unknown, and querying strings yield nil (icon-only label).
assert(compactRPM(fromStatus: "fan 0: 1701 RPM (1700–5000)") == 1701)
assert(compactRPM(fromStatus: "fan 0: 1701 RPM (1700–5000), fan 1: 3000 RPM (2160–6800)") == 3000)
assert(compactRPM(fromStatus: "fan 0: 1700–5000 RPM, fan 1: 2160–6800 RPM") == nil)
assert(compactRPM(fromStatus: "fan state unknown") == nil)

print("selfcheck OK (13 assertions)")
