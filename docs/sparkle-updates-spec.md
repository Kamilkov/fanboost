# Spec: Sparkle 2 auto-updates for FanBoost

Slice scope: current stable Sparkle 2 via SPM, standard Sparkle UI, one
"Check for Updates…" menu item, GitHub-hosted releases, manual release
workflow. Sources: sparkle-project.org/documentation (setup, publishing),
Apple SMAppService docs. The vendored `vendor/smcFanControl/Sparkle.framework`
(Sparkle 1, GPL-era copy) is reference-only and MUST NOT be linked.

## 1. Integration (app target only)

- SPM dependency `https://github.com/sparkle-project/Sparkle` (Sparkle 2,
  "up to next major" from current stable), declared in `project.yml`
  (XcodeGen `packages:` + app target dependency), product `Sparkle`,
  Embed & Sign. The helper target gets NO Sparkle linkage.
- `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: …,
  userDriverDelegate: nil)` owned by `FanBoostApp`/`AppState`; menu item
  `Button("Check for Updates…") { updaterController.checkForUpdates(nil) }`
  disabled while `canCheckForUpdates` is false (Sparkle's published property).
- Info.plist (via project.yml `info.properties`):
  - `SUFeedURL` = appcast URL (§3)
  - `SUPublicEDKey` = EdDSA public key (base64, from `generate_keys`)
  - Automatic checks: leave Sparkle default prompt behavior (standard UI).
- App is not sandboxed → no installer XPC service keys needed.

## 2. Versioning (monotonic)

- `CFBundleShortVersionString` = marketing `X.Y.Z` (starts 1.1.0).
- `CFBundleVersion` = plain integer, +1 every release, never reused
  (Sparkle compares `sparkle:version` = CFBundleVersion). Both set once in
  `project.yml` and inherited by app AND helper targets so the pair always
  carries the same version.
- Release tag `vX.Y.Z` == the commit the archive was built from.

## 3. Hosting (HTTPS, this GitHub repo)

- Archives: GitHub Releases assets —
  `https://github.com/Kamilkov/fanboost/releases/download/vX.Y.Z/FanBoost-X.Y.Z.zip`.
- Appcast: `appcast.xml` committed on `main`, served at
  `https://raw.githubusercontent.com/Kamilkov/fanboost/main/appcast.xml`
  (HTTPS, ATS-clean; Sparkle parses regardless of text/plain content type).
  Smallest scheme with no extra infrastructure; GitHub Pages is the fallback
  if raw ever misbehaves.
- Appcast entries carry `sparkle:version`, `sparkle:shortVersionString`,
  `sparkle:minimumSystemVersion` (13.0), enclosure URL + `length` +
  `sparkle:edSignature`.
- **Bootstrap feed state**: before ANY update-enabled build ships, a valid
  `appcast.xml` must already be live at `SUFeedURL`. Bootstrap form: a
  valid EMPTY RSS channel (no `<item>`) if Sparkle's parser accepts it —
  verified in the local drill (empty feed must yield "no update found",
  not an error); otherwise defer publishing any item until a real signed
  asset exists. Never commit an item with blank `sparkle:edSignature`/
  `length` or an enclosure URL that does not resolve. Local code/build may
  proceed before the feed is live, but nothing ships/pushes update-enabled
  builds until `SUFeedURL` serves the valid feed.

## 4. Signing chain & key handling

Order per release: Developer ID build → notarize (`fanboost-notary`
profile) → staple → `ditto -c -k --sequesterRsrc --keepParent` zip →
EdDSA-sign the zip. Both signatures verified in acceptance (§7).

- One-time: `generate_keys` on the release Mac; private key lives ONLY in
  that Mac's login Keychain (never in repo, env, or CI); public key into
  `SUPublicEDKey`. Backup once via `generate_keys -x <file>` stored
  encrypted offline; `-f` re-imports. Key rotation is out of scope.
- Per release: `sign_update FanBoost-X.Y.Z.zip` (or `generate_appcast` over
  the archives folder) produces `sparkle:edSignature`/`length`.

## 5. Fail-safe update lifecycle for the SMAppService helper

Invariant: manual fan mode never survives an update, and stale helper code
never serves a newer app.

1. **One graceful-termination safety gate — `applicationShouldTerminate`**:
   the app's `NSApplicationDelegate.applicationShouldTerminate(_:)` is the
   SOLE gate for every graceful exit: ordinary Quit AND every Sparkle
   termination mode (interactive "Install and Relaunch" and silent
   install-on-quit), because Sparkle installs by terminating the app —
   installation waits for application termination, so gating termination
   gates the install. No Sparkle delegate is needed for safety:
   `updaterDelegate` is nil; the standard controller + menu item stand.
   Gate behavior (documented AppKit semantics): return `.terminateLater`,
   send one unconditional `restoreAuto` over XPC, and complete via
   `NSApplication.reply(toApplicationShouldTerminate:)`:
   - confirmed nil (success) reply → `reply(true)` → termination proceeds
     (Quit exits; a pending Sparkle install runs).
   - error reply or one bounded 10 s timeout → `reply(false)` → the app
     stays running, `lastError` shows "quit/update cancelled: fan restore
     not confirmed", and the user may retry Quit or Check for Updates.
     Nothing falsely proceeds and no update session is stalled — Sparkle
     simply sees termination declined.
   **Fail-closed branching** (consistent with current `stopBoost`
   semantics, which keeps `phase == .boosting` until restore is
   confirmed):
   - helper definitively not enabled (`daemon.status != .enabled`) AND
     `phase != .boosting` → this app owns no manual state → `reply(true)`.
   - `phase == .boosting`, OR helper is expected enabled but the proxy is
     unavailable / the restore reply errors or times out → `reply(false)`,
     stay running, preserve the unconfirmed state (never clear `phase`),
     surface `lastError`.
   Force-quit/crash paths remain covered by the
   existing owner-connection invalidation, 60 s dead-man, SIGTERM, and
   helper-startup restoration. There is NO pre-install unregister.
   Primary docs: applicationShouldTerminate / NSApplication.TerminateReply
   (.terminateLater + reply(toApplicationShouldTerminate:)) —
   https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:) ;
   Sparkle 2 (installation proceeds on application termination; standard
   updater) — https://sparkle-project.org/documentation/
2. **Startup helper reconciliation — the only helper-replacement path**:
   after atomic bundle replacement an OLD helper may remain registered and
   idle, but it can never serve or boost for the newer app: on any
   bundle-version marker mismatch, reconciliation must complete BEFORE
   polling/boosting can begin. This also covers the first Sparkle-enabled
   baseline (today's app writes no marker) and manual bundle replacements.
   On launch, if `UserDefaults` "lastRunBundleVersion" != current
   CFBundleVersion (or is absent), reconcile idempotently BY REGISTRATION
   STATE — first-run consent is preserved: reconciliation never
   auto-registers a privileged helper that was not already registered.
   - `daemon.status == .notRegistered` (or .notFound): no helper is
     installed → write the marker immediately, enable normal operation in
     the helper-inactive UI ("Install Fan Helper…" remains the only, user-
     driven path to registration).
   - `daemon.status == .enabled` (consent already given): `restoreAuto`
     via XPC → persist a `helperReplacementPending` flag → **asynchronous**
     `unregister(completionHandler:)` (SMAppService.h: only after the
     completion handler has been invoked is it safe to re-register; the
     synchronous back-to-back call was runtime-disproven — launchd removal
     was still in progress when register ran) → in the completion,
     `daemon.register()` for the CURRENT bundle's helper → require
     `.enabled` AND a successful FRESH `status` XPC round-trip; **only
     then clear the pending flag, write the marker, and enable normal
     operation** (the poll/boost loop stays gated off until then).
     While the pending flag is set, a transient notRegistered/notFound —
     including across a crash/relaunch — must NEVER take the first-run
     branch; it waits, and the user-driven Install button recovers a
     failed register. A pending replacement that finds the service
     enabled only re-attempts the fresh confirmation — never another
     restore/unregister.
   - `daemon.status == .requiresApproval`: drive the EXISTING approval UI
     (status line + Login Items); no repeated `register()` loop — register
     fires only from the user's button. The marker is written once the
     current bundle's helper is confirmed (`.enabled` + round-trip), or
     once the user intentionally ends unregistered (status returns to
     .notRegistered), which collapses to the first case.
   Ordinary same-version launches (marker matches) skip reconciliation
   entirely. Any failure leaves the marker unwritten so the next launch
   retries the same idempotent sequence, and the failure is visible.
   A reconciliation failure must NOT be reported as "fans automatic"
   unless the `restoreAuto` step actually confirmed (nil reply): if
   restore was unconfirmed, the app only guarantees that polling/boosting
   stays gated off, while the layered helper recovery (startup restore,
   recovery timer, dead-man, SIGTERM) remains responsible for returning
   the hardware to automatic.
3. **Registration/approval failure leaves fans automatic and visible**:
   restore ran BEFORE unregister; on any register error the existing
   `lastError` + "Helper not active" status line + `fan.slash` icon show
   it, and no boost can start (`guard helperStatus == .enabled`). If macOS
   demands re-approval, `status == .requiresApproval` drives the existing
   Login Items UI.
4. **Protocol compatibility, no speculative abstraction**: app and helper
   ship as one bundle; an old helper may survive replacement only idle,
   and reconciliation (2) replaces it before the new app polls or boosts —
   the only cross-version XPC calls are reconciliation's
   `restoreAuto`/`status` (existing stable methods). Policy:
   `FanBoostXPC` methods are additive-only — never remove, rename, or
   change signatures of existing methods. No version handshake is added
   until an incompatible change is actually needed.

## 6. Manual release workflow (pre-CI)

All local verification precedes anything public; the asset is published
before the appcast that points at it.

1. **Local**: bump `CFBundleShortVersionString`/`CFBundleVersion` in
   project.yml, `xcodegen generate`, commit locally (no push yet).
2. **Local**: clean Release build → selfcheck, helper `--dryrun-check`,
   `checks/verify-hardened.sh` (incl. nested code, §7), deep/strict,
   `verify-requirements.sh`.
3. **Local**: notarize + staple + spctl/stapler verification (existing
   gate flow).
4. **Local**: `ditto` zip → `sign_update` → verify the archive: EdDSA
   signature verifies against `SUPublicEDKey`, byte `length` recorded,
   unzipped copy still passes stapler/spctl/deep-strict.
5. **Publish asset**: tag `vX.Y.Z`, push commit + tag, create GitHub
   Release `vX.Y.Z`, upload the zip, verify the download URL serves the
   exact byte length/hash of the local archive.
6. **Publish appcast last**: append the `<item>` pointing at the verified
   asset URL, commit + push appcast.xml, fetch it from `SUFeedURL` and
   confirm it parses and matches signature/length.

## 7. Acceptance tests

- **Signing chain**: installed candidate passes stapler validate, spctl
  "Notarized Developer ID", codesign deep/strict, verify-hardened;
  **nested-code coverage**: verification enumerates ALL nested executable
  code in the bundle (Sparkle.framework, its Autoupdate/Updater.app and
  any XPC services, plus any future embedded code — discovered by walking
  Contents/, not hardcoded) and requires each item: valid signature,
  hardened runtime, secure timestamp, no get-task-allow. Components we
  embed-and-sign carry Team JXGJ4K9KR9; a third-party-signed component is
  acceptable only if explicitly listed with its signer — no silent
  exceptions;
  `sign_update --verify` (or a fresh `sign_update` equality check) accepts
  the published zip + appcast signature; appcast URL fetches over HTTPS.
- **Two-phase local drill** (before first real publish; today's installed
  1.0 has no Sparkle and cannot update itself):
  - Phase A — manual baseline migration: with 1.0 + its registered helper
    installed, manually replace the bundle with the Sparkle-enabled
    baseline (safe-replacement procedure) and verify startup
    reconciliation over the OLD registered helper: restore → unregister →
    register → confirmed → marker; new helper serves status.
  - Phase B — Sparkle update: install a drill-only Sparkle-enabled build N
    whose feed is an explicit temporary override pointing at a local
    server (uncommitted drill-only build config — production `SUFeedURL`
    and ATS are never weakened in tracked files); serve a signed N+1
    zip+appcast locally; Check for Updates on N → standard UI offers N+1
    → install → relaunched app is N+1 (CFBundleVersion check),
    reconciliation ran, BTM enabled, NEW helper PID serves status, menu
    RPM live, `F0Md=0` throughout (polled like the smoke gate).
- **One-gate termination coverage**: all three graceful exits pass through
  the single `applicationShouldTerminate` gate — (a) ordinary Quit while
  boosted: restore confirmed then exit, `F0Md=0`; (b) interactive
  "Install and Relaunch": restore confirmed, then install proceeds;
  (c) install-on-quit: quitting with a downloaded update restores first,
  then installs. Plus the veto: with the helper made unreachable while
  boosted (drill only), Quit/update is declined, app stays running,
  `lastError` visible.
- **Rollback/error paths**: appcast unreachable → check fails with
  Sparkle's standard error, app fully functional; EdDSA signature mismatch
  (tamper 1 byte in a drill zip) → Sparkle refuses install, old app+helper
  intact; register() failure after update (simulate by declining approval
  if prompted) → fans automatic, error visible, re-register possible from
  the menu.
- **Final state after any pass or failure**: `F0Md=0` via read-only SMC
  reader; no orphaned helper process from the old bundle.

## 8. Explicitly rejected for this slice

Custom updater UI, delta updates, update channels/beta feeds,
profiles/system-info reporting, analytics, background CI release pipeline,
Sparkle for the helper alone (it updates only inside the app bundle), and
any XPC version-negotiation layer — none is forced by a hard requirement.
