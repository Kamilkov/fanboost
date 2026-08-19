# FanBoost v1 — Implementation Plan

**Goal:** smallest safe, distributable macOS 13+ menu-bar app that forces fan
speed up while the screen is captured/shared and restores automatic control
after — generalized from the working single-machine `capture-fan` prototype
in this repo (verified end-to-end on a Mac mini M2 Pro, 2026-08-19).

**Scope discipline (Ponytail/YAGNI):** this slice contains NO GitHub Actions,
no DMG tooling, no Homebrew cask, no update framework (Sparkle etc.), no
localization, and no hardware-abstraction layers beyond what the listed
requirements force. Release signing + notarization is a separate closeout
gate (§8), not part of the build slice.

---

## 1. License decision (resolved)

**Project license: GPL-2.0.** The smallest legally coherent route is to reuse
the vendored `smc.c`/`smc.h` (GPL-2.0, already in `vendor/`, already proven
against this SMC) as the helper's SMC I/O layer, compiled into the helper
target with its `main()` replaced by a small exported API
(`smc_open/read/write/close`). The user has explicitly chosen open source, so
GPL's copyleft is acceptable, and this avoids rewriting and re-validating
~700 lines of IOKit key-encoding code.

Rejected alternative (recorded for the future): a from-scratch Swift/IOKit
SMC client (~200 lines, references: `agoodkind/macos-smc-fan`,
`raminsharifi/MacFanControl`) would allow MIT but adds new untested hardware
I/O code to a root daemon for zero v1 user benefit. Revisit only if a
non-GPL license ever becomes a requirement.

New code (Swift app + helper glue, M3+ unlock) is authored by us and simply
licensed GPL-2.0 with the project.

## 2. Targets & repo layout

One Xcode project `FanBoost.xcodeproj`, two targets, added to THIS repo
(prototype files stay until v1 is verified, then are retired in a follow-up):

```
FanBoost/                     # menu-bar app target (SwiftUI, macOS 13+)
  FanBoostApp.swift           # MenuBarExtra + watcher loop
  CaptureProbe.swift          # dlsym(SLSIsScreenWatcherPresent) wrapper
  HelperClient.swift          # XPC proxy + ping timer
FanBoostHelper/               # root daemon target (Swift + C)
  main.swift                  # XPC listener, dead-man timer
  FanController.swift         # discovery, clamping, boost/restore, M3+ unlock
  smc.c / smc.h               # adapted from vendor/ (GPL-2.0), main() removed
Shared/
  FanBoostXPC.swift           # @objc protocol: status / boost / restoreAuto / ping
docs/implementation-plan.md
```

## 3. Helper daemon (FanBoostHelper)

- **Packaging (current SMAppService model, macOS 13+):**
  - Helper executable embedded via an Xcode **Copy Files phase on the app
    target, destination "Wrapper", subpath `Contents/MacOS`** →
    `FanBoost.app/Contents/MacOS/FanBoostHelper`.
  - Daemon plist embedded via a **Copy Files phase, destination "Wrapper",
    subpath `Contents/Library/LaunchDaemons`** →
    `FanBoost.app/Contents/Library/LaunchDaemons/com.kamilkovac.FanBoostHelper.plist`,
    containing `Label`, `BundleProgram = Contents/MacOS/FanBoostHelper`
    (relative to the app bundle, per Apple's SMAppService docs),
    `MachServices = { com.kamilkovac.FanBoostHelper.xpc: true }`, and
    `KeepAlive = true` so launchd restarts a crashed helper (whose startup
    then restores auto — see restore triggers below).
  - Registered from the app via `SMAppService.daemon(plistName:)` → user
    approves once in System Settings → Login Items. App must run from
    `/Applications`. The app connects with
    `NSXPCConnection(machServiceName:options:.privileged)`.
- **Fan discovery at startup:** `FNum` → per-fan `F{n}Mn`/`F{n}Mx` floats.
  `FNum == 0` → report "fanless" over XPC and do nothing else. No hardware
  database, no model tables — the SMC itself is the source of truth.
- **Boost semantics:** XPC takes `percent` (0–100 of each fan's own
  min→max range); helper computes and **clamps per fan**, writes
  `F{n}Md = 1` then `F{n}Tg = rpm` for **every** fan. Restore writes
  `F{n}Md = 0` for every fan.
- **Restore triggers (manual SMC state can persist across app/helper crashes
  and sleep — restoration must be explicit, never assumed):**
  1. App XPC connection invalidated or interrupted while boosted.
  2. Dead-man expiry: app must `ping()` every ≤15 s while boosted; helper
     restores auto after 60 s without a ping.
  3. Normal helper termination path (graceful shutdown restore).
  4. **Helper startup always writes `F{n}Md = 0`** — combined with launchd
     `KeepAlive` restart, a helper crash leads to restart → startup
     restoration. No SMC work in signal handlers (not async-signal-safe);
     crash recovery is the restart path, not a handler.
- **M3+ unlock:** on `F{n}Md` write failure (SMC result 0x82), write
  `Ftst = 1`, wait ~3 s, retry once. Verified M1/M2 path needs none of this;
  code is one guarded retry, not an abstraction.
- **XPC client validation:** in `listener(_:shouldAcceptNewConnection:)` the
  helper calls the public macOS 13 API
  `NSXPCConnection.setCodeSigningRequirement(_:)` on each accepted
  connection (Apple's recommended mechanism) with a requirement string
  parameterized per build configuration from the exact app identifier and
  signing Team ID: `anchor apple generic and identifier
  "$(APP_BUNDLE_ID)" and certificate leaf[subject.OU] = "$(DEVELOPMENT_TEAM)"`,
  where `DEVELOPMENT_TEAM` is `JXGJ4K9KR9` for both configs (both installed
  identities carry that OU; the parenthesized id in an Apple Development
  cert's CN is a personal id, not the team) and both values
  reach the helper through its Info.plist embedded in the binary
  (`CREATE_INFOPLIST_SECTION_IN_BINARY`), read via `Bundle.main` — no
  generated source files, clean-clone-safe.
  **No DEBUG security bypass** — dev builds are signed with the installed
  Apple Development identity, so the same requirement holds in development.

## 4. Menu-bar app (FanBoost)

- `MenuBarExtra`, no Dock icon (`LSUIElement`).
- Watcher loop = prototype logic ported: poll probe every 5 s, transitions
  only → `boost(percent)` / `restoreAuto()`.
- **Capture probe:** `dlopen` SkyLight → `SLSIsScreenWatcherPresent` (fallback
  symbol `CGSIsScreenWatcherPresent`), identical to `iscaptured.c`. Missing
  symbol → **fail safe**: restore auto, show persistent "detection
  unavailable" state in the menu. Private API — acceptable for Developer ID
  distribution, documented in README.
- UI (whole surface): status icon (idle / boosting / warning), Enable
  toggle, boost slider (percent of fan range; default = the prototype's
  proven point, ~68% on the mini), fan status line ("1 fan, 1700–5000 RPM" /
  "This Mac is fanless — nothing to do"), **launch at login** toggle
  (`SMAppService.mainApp`), Quit (quits after restore).
- First-run: explain root helper in one sentence → register daemon → deep-link
  to Login Items if approval pending.

## 5. Build & test verification (on this Mac)

1. `xcodebuild build` both targets, signed with the installed
   **Apple Development** identity (not ad-hoc; the XPC code-signing
   requirement must hold in dev) — must compile clean.
2. Unit-ish check (no frameworks): `FanController` dry-run mode
  (`FANBOOST_DRY_RUN=1` logs instead of SMC writes) exercised by a small
  `swift test`/assert runner covering clamping, percent→RPM math, multi-fan
  fan-out, fanless short-circuit.
3. Live install verification (this Mac, M2 Pro): stop the prototype
  LaunchAgent first (`launchctl bootout`, it would fight the app), copy app
  to `/Applications`, approve helper, then re-run the prototype's proven
  acceptance test: `screencapture -v` 20 s → RPM climbs to target → restore
  auto; menu states change accordingly; then two crash drills mid-boost:
  **kill -9 the app** → helper restores auto within 60 s (dead-man proof),
  and **kill -9 the helper** → launchd restarts it and its startup
  restoration returns the fan to auto.
4. Re-enable or retire the prototype agent afterwards (user's call at gate).

## 6. Cannot be verified on this Mac / without credentials

- **M3/M4 `Ftst` unlock path** (this machine is M2) — code review + community
  testing only; the guarded-retry design is inert on M1/M2.
- **Multi-fan hardware** (mini has 1 fan) — fan-out covered by dry-run tests
  only.
- **Fanless behavior** on real hardware — dry-run test only.
- **Notarized-app Gatekeeper behavior on a second Mac** — needs a friend's
  machine at closeout. (Signing itself is NOT a blocker: this Mac has both
  an Apple Development identity — used throughout the build slice — and a
  **Developer ID Application: Kamil Kovac (JXGJ4K9KR9)** identity for the
  release gate; only notarization + second-machine testing remain later.)

## 7. Explicit non-goals (v1)

App Store (sandbox forbids SMC + daemons), Intel Macs, temperature rules,
CI/CD, DMG/Homebrew packaging, auto-update, localization.

## 8. Closeout gate (separate slice, after v1 verified locally)

Developer ID Application certificate on this Mac → sign both targets with
hardened runtime → enable the production XPC code-signing requirement →
`notarytool submit` + staple → zip → test on one non-development Mac →
tag release + publish repo with GPL-2.0 LICENSE and honest
tested-hardware README.
