// FanBoost — menu-bar app: capture watcher + controls. GPL-2.0.
import SwiftUI
import ServiceManagement
import Sparkle

enum Phase: Equatable {
    case idle
    case boosting
    case probeUnavailable
    case fanless
}

@MainActor
final class AppState: ObservableObject {
    // Single instance shared with TerminationGate: an
    // @NSApplicationDelegateAdaptor delegate is created before the App's
    // @StateObject is readable, so both reach the same state through here.
    static let shared = AppState()

    @AppStorage("enabled") var enabled = true
    @AppStorage("boostPercent") var boostPercent = 65.0

    @Published var phase: Phase = .idle
    @Published var fanInfo = "querying helper…"
    @Published var helperStatus: SMAppService.Status = .notRegistered
    @Published var lastError: String?
    /// Bundle-version reconciliation done — polling/boosting stays gated
    /// off until true so a new app never drives an old helper.
    @Published var reconciled = false

    private let probe = CaptureProbe()
    private let helper = HelperClient()
    private let daemon = SMAppService.daemon(plistName: kHelperPlistName)
    private var pollTimer: Timer?
    private var pingTimer: Timer?
    private var reconciling = false
    private static let markerKey = "lastRunBundleVersion"
    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private init() {
        refreshHelperStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if reconcileNeeded(lastRun: UserDefaults.standard.string(forKey: Self.markerKey),
                           current: bundleVersion) {
            reconcile()
        } else {
            reconciled = true
            refreshStatusFromHelper()
        }
    }

    // MARK: bundle-version reconciliation (spec §5.2, consent-preserving)

    private static let pendingKey = "helperReplacementPending"
    private var pendingReplacement: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingKey) }
    }
    private var helperState: HelperState {
        switch helperStatus {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .unregistered
        }
    }

    /// Idempotent; re-run each tick until it resolves. Never auto-registers
    /// a helper the user hasn't installed. `pendingReplacement` is persisted
    /// BEFORE unregister so a transient notRegistered mid-replacement (or a
    /// crash/relaunch inside the window) can never be misread as first-run
    /// consent and write the marker without a fresh helper round-trip.
    private func reconcile() {
        guard !reconciled, !reconciling else { return }
        switch reconcileAction(pendingReplacement: pendingReplacement, helper: helperState) {
        case .finish: // genuine first run: no helper installed, none pending
            finishReconciliation() // registration stays with the Install button
        case .wait:
            break // approval UI, or mid-replacement transient — next tick retries;
                  // the user-driven Install button also recovers a failed register
        case .confirmOnly:
            // Replacement already ran (this launch or a previous one) and the
            // service is enabled: ONLY confirm with a fresh round-trip — never
            // restore/unregister again.
            reconciling = true
            helper.invalidate() // fresh connection, never a stale cached peer
            guard let proxy = helperProxy() else { reconciling = false; return }
            proxy.status { [weak self] _, _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.reconciling = false
                    self.finishReconciliation()
                }
            }
        case .beginReplacement:
            reconciling = true
            guard let proxy = helperProxy() else {
                reconciling = false
                lastError = "Update reconciliation: helper unreachable — will retry."
                return
            }
            proxy.restoreAuto { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    if let err {
                        self.reconciling = false
                        self.lastError = "Update reconciliation: restore failed (\(err)) — will retry."
                        return
                    }
                    // Mark the replacement in flight BEFORE unregister, then
                    // drop the cached connection to the OLD helper.
                    self.pendingReplacement = true
                    self.helper.invalidate()
                    // SMAppService.h: only after the unregister completion
                    // handler has been invoked is it safe to re-register.
                    // The synchronous back-to-back call raced launchd's
                    // removal (runtime-proven) — never register before this
                    // completion fires.
                    self.daemon.unregister { unregErr in
                        Task { @MainActor in
                            if let unregErr {
                                self.reconciling = false
                                self.refreshHelperStatus()
                                self.lastError = "Update reconciliation: unregister failed: \(unregErr.localizedDescription)"
                                return
                            }
                            do {
                                try self.daemon.register()
                            } catch {
                                self.reconciling = false
                                self.refreshHelperStatus()
                                self.lastError = "Update reconciliation: re-register failed: \(error.localizedDescription)"
                                return // pending stays set; Install button / next tick recover
                            }
                            self.refreshHelperStatus()
                            self.reconciling = false
                            guard self.helperStatus == .enabled else { return } // approval UI; pending stays
                            self.reconcile() // falls into .confirmOnly for the fresh round-trip
                        }
                    }
                }
            }
        }
    }

    private func finishReconciliation() {
        pendingReplacement = false
        UserDefaults.standard.set(bundleVersion, forKey: Self.markerKey)
        reconciled = true
        refreshStatusFromHelper()
    }

    // MARK: termination gate (spec §5.1) — called by TerminationGate

    /// One unconditional restoreAuto with a bounded timeout; the reply and
    /// the timeout funnel through one OneShot so AppKit gets exactly one
    /// reply. Fails closed whenever boosting/restoration is unconfirmed.
    func confirmRestoreForTermination(_ completion: @escaping (Bool) -> Void) {
        refreshHelperStatus()
        let enabledNow = helperStatus == .enabled
        let boosting = phase == .boosting
        if mayTerminate(helperEnabled: enabledNow, boosting: boosting, restore: .notAttempted) {
            completion(true) // no app-owned manual state possible
            return
        }
        guard let proxy = helperProxy() else {
            lastError = "Quit/update cancelled: fan restore not confirmed (helper unreachable)."
            completion(false)
            return
        }
        let shot = OneShot()
        let decide: (RestoreOutcome) -> Void = { [weak self] outcome in
            let ok = mayTerminate(helperEnabled: enabledNow, boosting: boosting, restore: outcome)
            if !ok { self?.lastError = "Quit/update cancelled: fan restore not confirmed." }
            completion(ok)
        }
        let timeout = DispatchWorkItem { shot.fire { decide(.timedOut) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        proxy.restoreAuto { err in
            Task { @MainActor in
                timeout.cancel()
                shot.fire { decide(err == nil ? .confirmed : .failed) }
            }
        }
    }

    // MARK: watcher loop (transitions only, mirrors the shell prototype)

    private func tick() {
        // Refresh registration state first, then let reconciliation progress
        // (requiresApproval resolves here) before anything may talk fan
        // state to a possibly-old helper. Once reconciled, refresh fanInfo
        // (live RPM) every poll so it stays fresh with boosting toggled off.
        refreshHelperStatus()
        guard reconciled else { reconcile(); return }
        refreshStatusFromHelper()
        guard enabled, helperStatus == .enabled else { return }
        switch probe.check() {
        case .capturing:
            if phase == .idle { startBoost() }
        case .idle:
            if phase == .boosting { stopBoost() }
            if phase == .probeUnavailable { phase = .idle }
        case .unavailable:
            // Fail safe: never stay boosted on a blind probe.
            if phase == .boosting { stopBoost() }
            phase = .probeUnavailable
        }
    }

    private func startBoost() {
        helperProxy()?.boost(percent: boostPercent) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error
                    if error.contains("no fans") { self.phase = .fanless }
                } else {
                    self.phase = .boosting
                    self.startPinging()
                }
            }
        }
    }

    private func stopBoost() {
        stopPinging()
        guard let proxy = helperProxy() else {
            // Keep phase == .boosting so the watcher retries next poll; do not
            // falsely claim automatic.
            lastError = "Restore request failed: helper unavailable — will retry."
            return
        }
        proxy.restoreAuto { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    // Restore not confirmed — stay "boosting" so tick() retries;
                    // the helper's own recovery/dead-man also keep trying.
                    self.lastError = "Restore not confirmed: \(err) — retrying."
                } else {
                    self.phase = .idle
                }
            }
        }
    }

    private func startPinging() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.helperProxy()?.ping() }
        }
    }

    private func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func helperProxy() -> FanBoostXPC? {
        guard let p = helper.proxy(onError: { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }) else {
            // Fail closed and make it visible: the requirement couldn't be
            // built (this build's FBTeamID/FBIdentityClass are missing).
            lastError = "Cannot verify helper identity — signing config (FBTeamID/FBIdentityClass) missing."
            return nil
        }
        return p
    }

    // MARK: helper + login item management

    func refreshHelperStatus() {
        helperStatus = daemon.status
    }

    func registerHelper() {
        do {
            try daemon.register()
        } catch {
            lastError = error.localizedDescription
        }
        refreshHelperStatus()
        if helperStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshStatusFromHelper()
    }

    func refreshStatusFromHelper() {
        guard helperStatus == .enabled else { return }
        helperProxy()?.status { [weak self] count, ranges, _ in
            Task { @MainActor in
                self?.fanInfo = ranges
                // Only a genuine fanless Mac (count 0 AND a fanless description)
                // disables the app; "fan state unknown" must not latch fanless.
                if count == 0, ranges.contains("fanless") { self?.phase = .fanless }
            }
        }
    }

    // MARK: uninstall + legacy migration

    /// Restore auto FIRST, then unregister — but ONLY inside a successful
    /// restore reply. If the helper proxy/config is unavailable, or restore
    /// errors, REFUSE to unregister and surface the reason. No blind
    /// try?-unregister fallback (that could strand manual fan state).
    func unregisterHelper() {
        stopPinging() // stop keep-alive; the restore call below IS the restore
        guard let proxy = helperProxy() else {
            lastError = "Uninstall refused: helper unavailable — daemon left registered."
            return
        }
        proxy.restoreAuto { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.lastError = "Uninstall refused: restore failed (\(err)) — daemon left registered."
                    return
                }
                do {
                    try self.daemon.unregister()
                    self.phase = .idle
                } catch {
                    self.lastError = "Restore ok, but unregister failed: \(error.localizedDescription)"
                }
                self.refreshHelperStatus()
            }
        }
    }

    /// lstat (not stat): reports a path that exists INCLUDING a dangling
    /// symlink, and does not follow it.
    private func legacyPathExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Show the cleanup affordance when any exact legacy artifact FILE is
    /// detectable — the user LaunchAgent, the sudoers file, or the smc file.
    /// The capture-fan directory is intentionally not removed by cleanup, so
    /// an empty smcDir is not a remaining privileged artifact and is ignored.
    var hasLegacyArtifacts: Bool {
        legacyPathExists(LegacyPaths.userAgent)
        || legacyPathExists(LegacyPaths.sudoers)
        || legacyPathExists(LegacyPaths.smc)
    }

    /// Remove the prototype's user LaunchAgent (exact path) directly, and its
    /// root-owned sudoers/smc artifacts through the helper. Reports bootout,
    /// unlink, and helper outcomes truthfully.
    func cleanupLegacy() {
        var report: [String] = []

        // bootout the user agent and WAIT for it to finish before unlinking,
        // so launchd isn't still referencing the file we remove.
        let boot = Process()
        boot.launchPath = "/bin/launchctl"
        boot.arguments = ["bootout", "gui/\(getuid())/\(LegacyPaths.agentLabel)"]
        do { try boot.run(); boot.waitUntilExit() }
        catch { report.append("bootout: \(error.localizedDescription)") }

        // unlink ONLY the exact path (removes the symlink itself if it is one).
        if legacyPathExists(LegacyPaths.userAgent) {
            if unlink(LegacyPaths.userAgent) == 0 { report.append("removed LaunchAgent") }
            else { report.append("LaunchAgent unlink failed: \(String(cString: strerror(errno)))") }
        }

        guard let proxy = helperProxy() else {
            report.append("helper unavailable — root artifacts not removed")
            lastError = "Legacy cleanup: " + report.joined(separator: "; ")
            return
        }
        proxy.cleanupLegacy { [weak self] summary in
            Task { @MainActor in
                report.append(summary)
                self?.lastError = "Legacy cleanup: " + report.joined(separator: "; ")
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { lastError = error.localizedDescription }
            objectWillChange.send()
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on, phase == .boosting { stopBoost() }
    }

    func quit() {
        // The applicationShouldTerminate gate performs and confirms the
        // restore (fail closed) before allowing termination.
        NSApp.terminate(nil)
    }

    var statusLine: String {
        // Until reconciliation confirms the current helper, never claim
        // automatic — the last error (if any) is shown by the existing row.
        if !reconciled { return "Verifying fan helper after update — fan state unconfirmed" }
        if helperStatus != .enabled { return "Helper not active" }
        switch phase {
        case .idle: return "Idle — fans automatic"
        case .boosting: return "Screen capture detected — boosting"
        case .probeUnavailable: return "Capture detection unavailable (macOS update?) — fans automatic"
        case .fanless: return "This Mac is fanless — nothing to do"
        }
    }

    var iconName: String {
        if !reconciled { return "exclamationmark.triangle" } // unconfirmed state
        switch phase {
        case .boosting: return "fan.fill"
        case .probeUnavailable, .fanless: return "exclamationmark.triangle" // warning states
        case .idle: return helperStatus == .enabled ? "fan" : "fan.slash"
        }
    }
}

/// Sole graceful-termination safety gate (spec §5.1): ordinary Quit and
/// every Sparkle install mode all terminate through here.
final class TerminationGate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            AppState.shared.confirmRestoreForTermination { ok in
                sender.reply(toApplicationShouldTerminate: ok)
            }
        }
        return .terminateLater
    }
}

/// Sparkle's documented SwiftUI pattern for the menu item's enabled state.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

@main
struct FanBoostApp: App {
    @NSApplicationDelegateAdaptor(TerminationGate.self) private var gate
    @StateObject private var state = AppState.shared
    @StateObject private var checkVM: CheckForUpdatesViewModel
    private let updaterController: SPUStandardUpdaterController

    init() {
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        updaterController = controller
        _checkVM = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: controller.updater))
    }

    var body: some Scene {
        MenuBarExtra {
            Text(state.statusLine)
            // A Button (not Text) so the row renders in primary color instead
            // of the dimmed disabled style; clicking refreshes immediately.
            Button(state.fanInfo) { state.refreshStatusFromHelper() }

            Divider()

            if state.helperStatus != .enabled {
                Button("Install Fan Helper…") { state.registerHelper() }
                Text("FanBoost needs a root helper to set fan speeds. Approve it in System Settings → Login Items.")
                    .font(.caption)
            } else if state.phase != .fanless {
                Toggle("Boost on screen capture", isOn: Binding(
                    get: { state.enabled },
                    set: { state.setEnabled($0) }))
                Picker("Boost speed", selection: $state.boostPercent) {
                    Text("Medium (50%)").tag(50.0)
                    Text("High (65%)").tag(65.0)
                    Text("Very high (80%)").tag(80.0)
                    Text("Maximum").tag(100.0)
                }
            }

            Toggle("Launch at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.launchAtLogin = $0 }))

            Button("Check for Updates…") { updaterController.updater.checkForUpdates() }
                .disabled(!checkVM.canCheckForUpdates)

            if state.helperStatus == .enabled {
                Button("Uninstall Fan Helper") { state.unregisterHelper() }
            }
            if state.hasLegacyArtifacts {
                Button("Remove old capture-fan") { state.cleanupLegacy() }
            }

            if let err = state.lastError {
                Divider()
                Text("Last error: \(err)").font(.caption)
            }

            Divider()
            Button("Quit FanBoost") { state.quit() }
        } label: {
            // Persistent menu-bar label: fan icon plus compact live RPM,
            // updated by the 5 s status refresh; icon-only when no live reading.
            if let rpm = compactRPM(fromStatus: state.fanInfo) {
                Text("\(Image(systemName: state.iconName)) \(rpm) RPM")
            } else {
                Image(systemName: state.iconName)
            }
        }
    }
}
