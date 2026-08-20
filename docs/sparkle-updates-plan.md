# Plan: Sparkle 2 implementation sequence (executes docs/sparkle-updates-spec.md)

Order is check-first: each step lands its failing check, then the smallest
fix. No step edits helper safety logic; everything reuses `AppState`,
`helperProxy()`, `daemon.register()/unregister()`, `stopBoost` semantics.

## Step 1 — pure logic + red selfcheck

- New `Shared/UpdateLogic.swift` (only new file; justified: pure functions
  must be compilable by the swiftc selfcheck harness, which cannot import
  SwiftUI/Sparkle):
  - `public func reconcileNeeded(lastRun: String?, current: String) -> Bool`
    (nil or mismatch → true).
  - `public enum RestoreOutcome { case confirmed, failed, timedOut, notAttempted }`
  - `public func mayTerminate(helperEnabled: Bool, boosting: Bool, restore: RestoreOutcome) -> Bool`
    — true only for (a) `!helperEnabled && !boosting` (no app-owned manual
    state) or (b) `restore == .confirmed`. Encodes spec §5.1 fail-closed
    branching.
  - `public final class OneShot` — the smallest runnable one-shot
    completion seam (NSLock + `done` flag; `fire(_:)` runs its closure at
    most once). Termination code routes BOTH the XPC restore reply and the
    10 s timeout through one `OneShot`, so they can never both reply to
    AppKit. No framework, no generic abstraction — one tiny class.
- `checks/main.swift`: add asserts FIRST (harness goes red until the file
  exists, green after): mismatch/nil/equal marker cases; the 8
  `mayTerminate` combinations incl. boosting+timeout → false; `OneShot`
  asserts (two sequential `fire` calls run the closure exactly once; a
  counter proves the second is ignored).
- Command: `swiftc Shared/FanMath.swift Shared/UpdateLogic.swift checks/main.swift -o build/selfcheck && ./build/selfcheck`
  (update the run comment in checks/main.swift). Evidence: new assertion
  count printed.

## Step 2 — project.yml: SPM, versions, Info keys

- `packages:` → `Sparkle: {url: https://github.com/sparkle-project/Sparkle, from: <current stable 2.x, pinned at implementation time from the GitHub releases page>}`.
- FanBoost target only: `dependencies: - package: Sparkle` (XcodeGen embeds
  & signs SPM framework products for app targets; verify in Step 7's
  embedding check — helper target untouched, gains no Sparkle linkage).
- `settings.base`: `MARKETING_VERSION: 1.1.0`, `CURRENT_PROJECT_VERSION: 2`;
  both targets' `info.properties`: `CFBundleShortVersionString: $(MARKETING_VERSION)`,
  `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` (spec §2: app+helper carry
  the same pair).
- App `info.properties`: `SUFeedURL: https://raw.githubusercontent.com/Kamilkov/fanboost/main/appcast.xml`;
  `SUPublicEDKey` deliberately ABSENT until Step 5 (missing key must fail
  the release checklist, not ship a placeholder).
- Commands: `xcodegen generate` then `git diff FanBoost.xcodeproj` reviewed;
  Debug build resolves the package. Evidence: build log shows Sparkle
  package resolution; `verify-requirements.sh` still passes.

## Step 3 — app wiring (one seam, no lifecycle bugs)

All in `FanBoost/FanBoostApp.swift`:
- `AppState`: add `static let shared = AppState()` and make `init` private;
  `FanBoostApp` uses `@StateObject private var state = AppState.shared`.
  This is the bridge that avoids the classic adaptor bug: an
  `@NSApplicationDelegateAdaptor` delegate is instantiated by SwiftUI
  before the App's `@StateObject` is readable, so the delegate reaches the
  SAME state via `AppState.shared`, never via a second instance.
- `final class TerminationGate: NSObject, NSApplicationDelegate` with
  `applicationShouldTerminate(_:) -> .terminateLater`, then
  `AppState.shared.confirmRestoreForTermination { ok in NSApp.reply(toApplicationShouldTerminate: ok) }`.
  App declares `@NSApplicationDelegateAdaptor(TerminationGate.self) var gate`.
- `AppState.confirmRestoreForTermination(_ completion: @escaping (Bool) -> Void)`:
  computes `RestoreOutcome` (reusing `helperProxy()`, one `restoreAuto`,
  a 10 s `DispatchWorkItem` timeout), with the restore reply and the
  timeout both funneled through one `OneShot` so exactly one
  `mayTerminate` decision reaches `completion` (and thence AppKit's
  `reply(toApplicationShouldTerminate:)`); sets `lastError` on false. `quit()` drops its own
  `stopBoost` + delayed `NSApp.terminate` dance and becomes just
  `NSApp.terminate(nil)` — the gate now does the restore (deletes the old
  0.3 s race).
- Reconciliation: `@Published var reconciled = false`;
  `tick()` and `startBoost` paths gain `guard reconciled` (polling/boost
  disabled until done). `init` runs `reconcile()` when
  `reconcileNeeded(lastRun: defaults, current: bundleVersion)` else sets
  `reconciled = true`. `reconcile()` implements spec §5.2's consent-
  preserving state flow, switching on `daemon.status`:
  - `.notRegistered`/`.notFound` → write marker, `reconciled = true`,
    helper-inactive UI stands; NO auto-register — `registerHelper()` stays
    the only registration path and remains user-button-driven.
  - `.enabled` → `restoreAuto` (via `helperProxy()`) → persist
    `helperReplacementPending` → async `daemon.unregister(completionHandler:)`
    → (in the completion only — SMAppService.h says re-register is safe
    only after it fires; synchronous back-to-back was runtime-disproven) →
    `daemon.register()` → confirm `.enabled` + FRESH `status` round-trip →
    clear pending, write marker, `reconciled = true`. While pending, a
    transient notRegistered must never hit the first-run branch (pure
    `reconcileAction` encodes this, selfcheck-asserted). Any failure:
    marker unwritten, pending kept, `lastError` surfaced, next tick or the
    Install button recovers.
  - `.requiresApproval` → no register loop; existing approval UI drives
    it. `tick()`'s existing status refresh re-runs `reconcile()`'s cheap
    switch each poll until it resolves to one of the two cases above
    (user approves → `.enabled` branch confirms current helper → marker;
    user uninstalls → `.notRegistered` branch → marker).
- Sparkle UI: `let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`
  stored in `FanBoostApp`; Sparkle's documented SwiftUI pattern
  (`CheckForUpdatesViewModel` observing `updater.canCheckForUpdates`) backs
  `Button("Check for Updates…")`, disabled while false.
- Evidence: Debug build + `--dryrun-check` + selfcheck green;
  `git diff --check`.

## Step 4 — generalized nested signing verifier

- Extend `checks/verify-hardened.sh`: after existing app/helper checks,
  walk the bundle (`find "$APP/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \)`
  plus Mach-O files under Frameworks/) and for EVERY nested code item run
  `codesign --verify --strict` + `codesign -dv` assertions: valid
  signature, hardened-runtime flag, no get-task-allow; secure timestamp
  required only for Developer ID identities (existing script already
  branches Debug/Apple Development vs Release — reuse that branch, so
  Debug stays green). TeamID must be JXGJ4K9KR9 unless the item is in an
  explicit inline allowlist naming its signer (starts empty; Embed & Sign
  re-signs Sparkle with our team, so any allowlist entry is a loud,
  reviewed exception — no blind third-party trust).
- Red-capable proof, not just green runs: copy a built Sparkle-embedded
  bundle to scratchpad, ad-hoc re-sign ONE nested Sparkle executable
  (`codesign -s - --force <copy>/Contents/Frameworks/Sparkle.framework/...`)
  and prove the extended verifier FAILS on the tampered copy (wrong
  team/ad-hoc), while the untouched Debug and Release builds both pass.
  Evidence: failing output naming the tampered item + passing runs on both
  configs.

## Step 5 — EdDSA key (explicit, gated)

- Run Sparkle's `generate_keys` once on this Mac (private key → login
  Keychain only). Terminal output shows ONLY the public key; paste it into
  `project.yml` `SUPublicEDKey`, regenerate, commit. NEVER run with `-x`
  in this step, never echo/print/copy the private key into repo, logs, or
  reports. Encrypted offline backup (`generate_keys -x` to a user-chosen
  encrypted location) and any publishing are DEFERRED to a user-approved
  release gate.
- Evidence: `SUPublicEDKey` present in built Info.plist; no new files in
  repo besides project.yml/pbxproj.

## Step 6 — bootstrap appcast

- `appcast.xml` at repo root as a valid EMPTY RSS channel (correct rss/
  channel/namespace skeleton, zero `<item>`) — never blank
  signature/length or a dead enclosure. The 1.1.0 item is added only at
  the release gate once a real signed asset exists (spec §6 order).
- Checks: `xmllint --noout appcast.xml`; drill Phase B additionally serves
  the empty channel first and confirms Sparkle reports "no update found"
  (parser accepts it) — if it errors instead, keep the feed unpublished
  until the first real item (spec §3 fallback). Local builds proceed
  regardless; shipping/pushing update-enabled builds waits until
  `SUFeedURL` serves the valid feed. Evidence: xmllint exit 0 + drill log.

## Step 7 — build/stability battery

- `xcodegen generate` twice → no drift (diff-hash method); `git diff --check`.
- Debug + Release builds to scratchpad; embedding check:
  `ls Release/FanBoost.app/Contents/Frameworks/Sparkle.framework` exists,
  `otool -L` of FanBoostHelper shows NO Sparkle; extended verify-hardened
  (Step 4) passes both configs; `verify-requirements.sh` passes;
  `--dryrun-check` + selfcheck green.

## Step 8 — acceptance drills (spec §7, local only)

- Two-phase drill (installed 1.0 has no Sparkle and cannot update itself):
  - Phase A — manual baseline migration: with 1.0 + its registered helper
    live, manually replace the bundle (safe-replacement procedure) with
    the Sparkle-enabled baseline; verify reconciliation over the OLD
    registered helper: restore → unregister → register → confirmed →
    marker written; new helper PID serves status.
  - Phase B — Sparkle N→N+1: build drill-only N and signed N+1 from a
    TEMPORARY, uncommitted feed override (scratch project.yml edit setting
    `SUFeedURL http://localhost:8000/appcast.xml` + ATS local exception
    only if required; `git status` must show the override never enters
    tracked files — production SUFeedURL/ATS unweakened). Serve empty
    channel first ("no update found"), then the signed N+1 zip + appcast
    (`sign_update`) via `python3 -m http.server 8000`; Check for Updates
    on N → install → relaunched CFBundleVersion == N+1's, reconciliation
    ran (marker only after confirmed registration), new helper serves
    status, menu RPM live.
- Tamper: flip 1 byte in a copy of the drill zip, re-serve without
  re-signing → Sparkle refuses; old app intact.
- One-gate coverage: Quit-while-boosted (restore confirmed then exit),
  install paths, and the veto (helper unreachable while boosted → decline,
  `lastError` visible).
- Finals after every drill: `F0Md=0` via the read-only SMC reader; no
  orphaned old-bundle helper process.

Out of this plan (later, user-approved release gate): notarization of
1.1.0, GitHub tag/Release/asset upload, appcast publish, key backup.
