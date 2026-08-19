# FanBoost — Red-Team Remediation Plan (v1.1)

Source: `red-team-review.canvas.tsx` (2026-08-19). This plan covers the
**smallest safe fix set** for the six accepted items only. Each fix names a
failing check to write **first**, the exact files, and install/runtime
acceptance. No implementation happens under this gate.

## Scope & explicit non-goals

Per the review gate, this plan deliberately **excludes** (do not implement):
root-side SkyLight capture duplication (canvas fix #3's "duplicate the probe
as root"), CDHash/anchor-hash pinning, XPC rate limiting, shortening the
dead-man window, and any capture-oracle change. Notarization is a **deferred
release gate**, not a code fix (see §7).

**Unproven claim, treated as such (`user-writable-daemon`, P2):** Apple
documents SMAppService helpers running from `Contents/MacOS` inside the
signed app bundle. The existing embedded helper **and** the outer bundle
already pass `codesign --verify --deep --strict` (the helper is signed in
place and sealed inside the app), so the "user-writable-bundle RCE" is **not
accepted as a real vuln**. Therefore **skip the Copy Files / `CodeSignOnCopy`
spike entirely** — the raw `cp` embed stays. The only thing that would
reopen it is a **new** signed-verification check (added in §1) actually
failing on the current embedding; unless that check fails, no packaging
change is made. Not a P0.

Ordering: the two P1 fixes (§1 hardened runtime, §2 symmetric per-config
requirement) close the confused-deputy chain and come first; §3–§6 are P2/P3
hardening.

---

## 1. Hardened Runtime on app + helper (P1 `confused-deputy`, `unsigned-release`)

**Why:** without Hardened Runtime the app honors `DYLD_INSERT_LIBRARIES`, so
local code injects into the pinned identity and speaks XPC as the app. HR
brings library validation (only same-Team/platform dylibs load), which breaks
that injection with **no** DYLD/library-validation exception entitlements.

**Check first:** a shell acceptance check `checks/verify-hardened.sh` that
builds both targets signed and asserts, for **each** of `FanBoost.app` and the
embedded `FanBoostHelper`:
`codesign -d --entitlements - --verbose=4` shows the runtime flag
(`flags=0x10000(runtime)` via `codesign -dvvv`), and that
`com.apple.security.cs.allow-dyld-environment-variables`,
`disable-library-validation`, and `allow-unsigned-executable-memory` are
**absent**. Written to fail before the setting exists.

**Files:** `project.yml` — add to the shared `base` settings
`ENABLE_HARDENED_RUNTIME: YES`; confirm no target adds the three exception
entitlements. Regenerate `FanBoost.xcodeproj`.

**Embedding stays as-is (see scope note):** the current `cp` embed already
yields an app+helper that pass `codesign --verify --deep --strict`. `§1`'s
acceptance re-runs that verification on the **hardened** signed build; only
if it now fails does the Copy Files / `CodeSignOnCopy` alternative get
revisited. No speculative spike.

**Acceptance:** signed Debug build passes `verify-hardened.sh`; `codesign
--verify --deep --strict FanBoost.app` still passes on the hardened build
(this is also the gate that would reopen the embedding question if it
failed); app still launches, registers helper, boosts and restores on a real
capture.

## 2. Symmetric, config-specific XPC peer requirements (P1 `coarse-csreq`, P2 `no-client-pin`)

**Why:** today only the helper pins the client, with one requirement string
(identifier + Team OU) that **both** Apple Development and Developer ID
satisfy. Make the requirement **config-specific** and **mutual**.

**Design (smallest correct):** carry a per-config *identity-class* token
alongside the existing `FBAppBundleID`/`FBTeamID` in each binary's embedded
Info.plist, expanded from build settings:
- Debug → require Apple Development leaf
  (`certificate leaf[field.1.2.840.113635.100.6.1.12] exists`)
- Release → require Developer ID Application leaf
  (`certificate leaf[field.1.2.840.113635.100.6.1.13] exists`)
Both requirements also keep `identifier "<bundle id>"` **and**
`certificate leaf[subject.OU] = "<team>"`. The helper builds its client
requirement from its own embedded token; the **app** builds the symmetric
helper requirement and calls `setCodeSigningRequirement` on its
`NSXPCConnection` (closes `no-client-pin`). No CDHash pinning (excluded).

**Fail closed:** if `FBAppBundleID`, `FBTeamID`, or the new `FBIdentityClass`
is missing or malformed, **both** sides abort — the helper refuses to serve
(exit non-zero, as it already does for the first two keys) and the app
refuses to connect / build a requirement (surface an error, never fall back
to an unpinned or default-permissive requirement).

**Check first:** extend `checks/` with a `requirement-match` test that
evaluates the **constructed** requirement strings with
`codesign -R "<constructed req>" --verify <product>` against **separately
preserved** signed Debug and Release products (copy both signed `.app`s aside
before the test, since they share a path per config). Assert: Debug product
**passes** `-R <Debug req>` and **fails** `-R <Release req>`; Release product
the reverse. Inspecting the designated requirement (`codesign -dr -`) is not
sufficient — the test must actually run the constructed requirement via `-R`.
This is the failing test that today's single-string code cannot pass.

**Files:** `Shared/FanBoostXPC.swift` (or a new `Shared/PeerRequirement.swift`)
for the requirement-builder used by both sides; `FanBoostHelper/BuildConfig.swift`
+ `FanBoost`-side equivalent to read the new plist key; `project.yml` per-config
`info.properties` (`FBIdentityClass: apple-development` / `developer-id`) and
the helper Info.plist; `FanBoost/HelperClient.swift` to set the client-side
requirement before `resume()`; `FanBoostHelper/main.swift` requirement string.

**Acceptance:** signed Debug app ↔ Debug helper connect and boost; a Release
helper refuses a Debug client and the reverse (verified with the two signed
products via `codesign -R`); a build with a stripped `FB*` plist key fails
closed on both sides; `requirement-match` check passes.

## 3. Remove shared cross-connection liveness (P3 `shared-service`)

**Why:** `lastPing`/`boosting` are global on one shared exported object, so a
second accepted client can feed the dead-man or force `restoreAuto` under a
legitimate boost.

**Design (smallest):** **single-active-client** with an `owner`
(`NSXPCConnection?`) held on `controllerQueue`. Critical mechanics:
`NSXPCConnection.current()` is only valid **synchronously inside the exported
method body** — so each exported method captures the caller connection into a
local **before** dispatching onto `controllerQueue`, and the queued work
compares that captured value against `owner` (never calls `.current()` from
inside the async block, where it returns nil).

Exact owner semantics:
- **boost**: claims ownership **only when `owner == nil`**; if already owned
  by a different connection, reject (no write). Re-boost by the current owner
  is allowed and refreshes liveness.
- **ping / restoreAuto while owned**: honored **only** if the captured caller
  `=== owner`; other callers' `ping`/`restoreAuto` are no-ops.
- **restoreAuto while unowned (`owner == nil`)**: any authenticated client may
  call it (idempotent return-to-auto), and it stays a no-op if nothing is
  boosted.
- **invalidation/interruption**: restores auto and clears `owner` **only if**
  the invalidated connection `=== owner`; invalidation of a non-owner
  connection does nothing to the boost.
- dead-man refresh is keyed off the owner's pings only.

One exported object is fine (ownership is by connection identity, not object
graph). Less code than minting a per-connection service.

**Check first:** a `--dryrun-check` two-connection scenario using stand-in
connection tokens: A boosts and owns; B's `ping`/`restoreAuto` are no-ops
while A owns; B's `boost` is rejected while owned; unowned `restoreAuto` from
any client is accepted; A-invalidation restores+clears owner while
B-invalidation under A's boost is inert. Assert `ftstWrites`/`boosting`/`owner`
transitions. Fails today because any caller mutates global state.

**Files:** `FanBoostHelper/main.swift` (owner tracking in `HelperService`,
`clientGone` clears ownership), possibly a 2-line helper in `FanController`.

**Acceptance:** dry-run two-owner scenario passes; real single-client capture
boost/restore unchanged.

## 4. Retire prototype from the supported tree + migration cleanup + in-app uninstall (P1 `sudoers`, P3 `no-uninstall`)

**Why:** the shipped `install.sh` can leave `/etc/sudoers.d/capture-fan` and a
root-owned `/usr/local/libexec/capture-fan/smc` granting passwordless SMC
writes; and the app can register the root daemon but never unregister it.

**4a. Delete the prototype from the current tree (no history rewrite):**
`git rm` `watcher.sh`, `iscaptured.c`, `install.sh`, and
`com.kamilkovac.capture-fan.plist` — remove them outright, do **not** relocate
to `legacy/`. The prototype remains in earlier history/the public repo; the
goal is that the current tree contains only the app. Update `README.md` to
drop the prototype install path. No behavior of the app changes.

**4b. Migration cleanup — EXPLICIT UI, idempotent:** decision:
**explicit, user-initiated**, not automatic-on-launch (silently mutating root
files under a user who may not have the prototype is worse than a one-click
action). Surface a menu item "Remove old capture-fan" that is shown only when
at least one exact legacy artifact is detected. It removes **only** these
exact artifacts, idempotently (no-op if absent):
- user LaunchAgent: same-user, unlink **only** the exact path
  `~/Library/LaunchAgents/com.kamilkovac.capture-fan.plist` (the link itself if
  a symlink — never follow/rmtree), preceded by `launchctl bootout
  gui/$UID/com.kamilkovac.capture-fan` (awaited).
- root sudoers: remove **only** the exact file, real path
  `/private/etc/sudoers.d/capture-fan` (not the `/etc` symlink).
- root smc: remove **only** the exact file
  `/usr/local/libexec/capture-fan/smc`. The `capture-fan` **directory is NOT
  removed** — dropping the rmdir eliminates the directory-removal race; an
  empty dir is harmless and is not treated as a remaining artifact.

The two root removals run **through the existing helper** via one
narrowly-scoped XPC verb `cleanupLegacy()` (no path parameter). Each removal
uses a fail-closed, **descriptor-relative** walk (`SecureUnlink`): open each
directory component from `/` with `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`,
`fstat` it and refuse unless root-owned and not group/other writable, then
`fstatat(AT_SYMLINK_NOFOLLOW)` the final node and `unlinkat` it only if it is a
root-owned **regular file**. No symlink is followed at any component. Idempotent
(absent = no-op); refusals/errors are reported truthfully.

**4c. In-app helper uninstall (`no-uninstall`):** add `unregisterHelper()`
that **restores auto first** (`restoreAuto` over XPC) and calls
`SMAppService.daemon.unregister()` **only inside a successful restore reply**.
It stops the keep-alive ping, requests restore, and unregisters solely on the
`nil`-error reply. If the helper proxy/config is unavailable or restore
returns an error, it **refuses to unregister** and surfaces the reason — there
is no blind `try? unregister()` fallback that could strand manual fan state.
No artificial `uninstallSteps` enum or unit harness: the ordering is the
explicit restore-reply→unregister callback in `AppState`, verified by focused
review and runtime acceptance (the kill/uninstall drills below).

**Check first:** (i) `checks/` static assertion that the current tree's
`README` install steps reference the app, not `install.sh`, and that the four
prototype files are gone (grep/`test -e`, fails today); (ii) helper
`--dryrun-check` tests `LegacyCleanup.summarize` on synthetic results
(absent→nothing-found, refused/failed surfaced, success reported) AND exercises
the real `SecureUnlink` against a **harmless temp root** (never production
paths): a safe regular file is removed while an intermediate directory symlink
and a final-component symlink are refused and their targets survive. It never
calls the real `LegacyCleanup.run()`.

**Files:** `git rm` the four prototype files; `README.md`;
`Shared/FanBoostXPC.swift` (+`cleanupLegacy`); `Shared/LegacyPaths.swift`
(exact-path constants shared by app + helper); `FanBoostHelper/main.swift` +
`FanBoostHelper/LegacyCleanup.swift` (constant paths, injectable ops);
`FanBoost/FanBoostApp.swift` (menu items, explicit restore-reply→unregister
ordering, XPC calls).

**Acceptance (install-time, on this Mac, explicit and reversible):** with the
prototype currently installed, the app's cleanup removes exactly the
LaunchAgent, sudoers file, and libexec dir, verified by their absence and
`sudo -n .../smc ...` no longer being permitted; `unregisterHelper` leaves
fans in auto and `SMAppService.daemon.status == .notRegistered`.

## 5. Make transient SMC open/FNum failure explicit; retry restoration (P2 `restore-fail-open`)

**Why:** if `fb_smc_open()`/`FNum` fails, `fanCount` stays 0, `restoreAuto`
writes nothing, and the helper misreports **fanless** permanently while prior
manual fan state persists.

**Design (smallest):** three explicit discovery states — `available`
(FNum read, N≥0 fans), **genuine `fanless` (FNum succeeded == 0)**, and
`unavailable` (open or FNum errored). Only a *successful* FNum of 0 is
reported fanless; an errored probe is `unavailable`, never fanless.

Recovery is **not bounded-only**:
- **Startup:** attempt discovery immediately; if `unavailable`, keep retrying.
- **Ongoing periodic recovery:** while state is `unavailable`, a timer on
  `controllerQueue` re-attempts discovery periodically (indefinitely, at a
  modest interval) — not a fixed small N that gives up.
- **Safe reopen:** before each re-attempt, close/reset any stale SMC
  connection (`fb_smc_close`, clear `g_conn`) so a half-open handle can't wedge
  reopen; then `fb_smc_open` + FNum afresh.
- **Restore on recovery:** the instant discovery transitions to `available`,
  immediately `restoreAuto` across the real fan indices (prior manual state
  from a crashed run must not linger).
- `status` reports "unknown" while `unavailable`; boost still refuses unless
  `available` with complete ranges. No dead-man/capture change.

**Check first:** `--dryrun-check` gains `simulatedOpenFail`/`simulatedFNumFail`
toggles and a `simulatedFNumZero` toggle asserting: (a) `FNumZero` → state
`fanless`; (b) open/FNum error → state `unavailable`, status "unknown" (**not**
fanless); (c) periodic recovery keeps attempting and a recover-on-attempt-k
path performs a safe close-before-reopen and then `restoreAuto` across real
indices. Fails today (open failure silently yields fanless, no retry).

**Files:** `FanBoostHelper/FanController.swift` (state + retry), `main.swift`
(startup retry loop on the controller queue), `smc_bridge`/dry-run plumbing
for the fault injection.

**Acceptance:** on hardware, normal path unchanged (fans discovered, restore
runs); fault-injected build shows retry logs and never prints fanless.

## 6. Reject non-4-byte SMC keys instead of truncating (P3 `key-truncation`)

**Why:** `copy_key` `strncpy(dst, key, 4)` silently truncates: a hypothetical
`F10Md` becomes `F10M` (wrong key). Latent (consumer Macs are F0–F9) but a
correctness/format-smell.

**Design (smallest):** make `copy_key` **validate**: require the key be
exactly 4 bytes; on any other length return a failure that the bridge surfaces
as `-1` (no write attempted). Callers already handle `-1`. Since fan index is
formatted as `F\(index)Md`, also cap enumeration so a two-digit index can
never silently form a 5-char key — refuse (log) rather than write. No change
to the vendored `smc.c` write internals beyond what §is already patched.

**Check first:** a tiny C/Swift assertion (extend `checks/`) that a 5-char key
is rejected (bridge returns failure, no SMC call) and a 4-char key is accepted
in dry-run. Fails today (truncates and proceeds).

**Files:** `FanBoostHelper/SMC/smc_bridge.c` (`copy_key` → validating,
signature returns success/fail), its `.h`, and the three call sites already
check the return.

---

## 7. Deferred to the release gate (NOT this slice)

Notarization + stapling of the Developer ID Release build, and the
second-Mac Gatekeeper acceptance, remain the separate closeout gate. §1 only
adds the **hardened-runtime build flag** (a code/build change) — it does not
perform notarization here.

## 8. Verification summary (all pre-implementation checks land failing first)

| Fix | Failing check to write first | Acceptance |
|-----|------------------------------|-----------|
| §1 | `verify-hardened.sh` (runtime flag present, no exception entitlements) | signed build passes; `--deep --strict` ok; live boost/restore |
| §2 | `requirement-match`: `codesign -R "<constructed req>"` vs preserved signed Debug/Release products | Debug↔Debug ok, cross-config rejected via `-R`; client pins helper; stripped `FB*` plist fails closed both sides |
| §3 | two-owner `--dryrun-check` | single-client capture unchanged |
| §4 | prototype files gone + README grep; `summarize` synthetic + `SecureUnlink` temp-root dry-run (safe file removed, intermediate/final symlinks refused); explicit restore-reply→unregister ordering by review | two exact files removed via fail-closed descriptor-relative walk (no symlink followed, dir left in place); unregister only after confirmed restore |
| §5 | open/FNum/FNum=0 fault-injection dry-run (safe reopen + ongoing recovery) | `unavailable`≠`fanless`; periodic retry; restore on recovery; hardware path unchanged |
| §6 | 5-char-key rejection dry-run | wrong-length keys refused; F0–F9 unaffected |

Cross-cutting, every slice re-runs: `xcodegen generate` (no drift), FanMath
selfcheck, both helper `--dryrun-check`s, unsigned Debug **and** Release
builds. Signed-product checks (§1, §2) require keychain access (the known
prompt) and are the install/runtime acceptance, kept distinct from
notarization.
