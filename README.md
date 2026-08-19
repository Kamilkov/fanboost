# FanBoost

macOS menu-bar app that forces the fan(s) up to a chosen speed while the
screen is being captured or shared (Snagit, Teams, Zoom, QuickTime, …) and
hands control back to macOS automatic fan management the moment capture
ends. For Macs that overheat exactly when you start presenting.

License: **GPL-2.0** (see `LICENSE`) — the SMC I/O layer is adapted from
[smcFanControl](https://github.com/hholtmann/smcFanControl) (GPL-2.0,
notices preserved in `FanBoostHelper/SMC/`).

## How it works

- **Capture detection** uses a private SkyLight API
  (`SLSIsScreenWatcherPresent`) — the state behind the menu-bar capture
  indicator. If a macOS update removes it, FanBoost fails safe: fans return
  to automatic and the menu shows "detection unavailable".
- **Fan control** happens in a **root helper daemon** (`FanBoostHelper`)
  installed via `SMAppService` — you approve it once in System Settings →
  Login Items. Fan speeds are set through SMC keys (`F{n}Md`/`F{n}Tg`);
  the boost speed is a percent of each fan's own min–max range, clamped
  per fan, so it is portable across models. Fanless Macs are detected and
  the app disables itself.
- **XPC security:** the helper only accepts connections from the FanBoost
  app, enforced with `NSXPCConnection.setCodeSigningRequirement` pinning
  the app's bundle ID and signing Team ID. No debug bypass exists.

## Safety behavior

Manual fan state must never outlive its reason. The helper restores
automatic control on: capture end, app disable/quit, XPC connection loss,
a 60 s dead-man timeout if the app stops pinging, graceful termination
(SIGTERM via dispatch source), and **its own startup** — combined with
launchd `KeepAlive`, even a helper crash leads to restart → restore.

## Build & run

Requires Xcode 15+ on macOS 13+. `FanBoost.xcodeproj` is committed; if you
change `project.yml`, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`xcodegen generate`).

```sh
xcodebuild -project FanBoost.xcodeproj -scheme FanBoost -configuration Release build
```

Signing: Debug uses your Apple Development identity, Release the Developer
ID Application identity — both under Team `JXGJ4K9KR9`, set in
`project.yml`, which also feeds the helper's XPC client requirement via its
embedded Info.plist. To run: copy `FanBoost.app` to `/Applications`, launch,
click "Install Fan Helper…", approve in System Settings → Login Items.

Self-checks (no root, no hardware writes):

```sh
swiftc Shared/FanMath.swift checks/main.swift -o build/selfcheck && ./build/selfcheck
FANBOOST_DRY_RUN=1 <built FanBoostHelper> --dryrun-check
```

## Supported / unverified hardware

- **Verified:** Mac mini M2 Pro (single fan, 1700–5000 RPM) — the shell
  prototype this app grew from ran its full acceptance test there.
- **Expected, unverified:** other M1/M2 Macs; multi-fan MacBook Pro;
  M3/M4 (extra `Ftst` unlock implemented but untested); fanless Airs
  (graceful no-op). Reports welcome.
- **Out of scope for v1:** Intel Macs, App Store distribution (sandbox
  forbids SMC access and privileged helpers).

## Repo history

The original single-machine shell prototype (`watcher.sh`, `iscaptured.c`,
`install.sh`, sudoers approach) is kept at the repo root until the app
fully replaces it; `docs/implementation-plan.md` records the v1 plan.
Release signing (Developer ID) + notarization are a separate closeout step.
