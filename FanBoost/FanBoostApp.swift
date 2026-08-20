// FanBoost — menu-bar app: capture watcher + controls. GPL-2.0.
import SwiftUI
import ServiceManagement

enum Phase: Equatable {
    case idle
    case boosting
    case probeUnavailable
    case fanless
}

@MainActor
final class AppState: ObservableObject {
    @AppStorage("enabled") var enabled = true
    @AppStorage("boostPercent") var boostPercent = 65.0

    @Published var phase: Phase = .idle
    @Published var fanInfo = "querying helper…"
    @Published var helperStatus: SMAppService.Status = .notRegistered
    @Published var lastError: String?

    private let probe = CaptureProbe()
    private let helper = HelperClient()
    private let daemon = SMAppService.daemon(plistName: kHelperPlistName)
    private var pollTimer: Timer?
    private var pingTimer: Timer?

    init() {
        refreshHelperStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshStatusFromHelper()
    }

    // MARK: watcher loop (transitions only, mirrors the shell prototype)

    private func tick() {
        // Refresh registration state and fanInfo (live RPM) every poll — before
        // the boost-enabled guard so they stay fresh with boosting toggled off.
        refreshHelperStatus()
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
        if phase == .boosting { stopBoost() }
        // The helper's dead-man and connection-invalidation paths also cover
        // an abrupt exit; this is just the polite path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    var statusLine: String {
        if helperStatus != .enabled { return "Helper not active" }
        switch phase {
        case .idle: return "Idle — fans automatic"
        case .boosting: return "Screen capture detected — boosting"
        case .probeUnavailable: return "Capture detection unavailable (macOS update?) — fans automatic"
        case .fanless: return "This Mac is fanless — nothing to do"
        }
    }

    var iconName: String {
        switch phase {
        case .boosting: return "fan.fill"
        case .probeUnavailable, .fanless: return "fan.badge.exclamationmark" // warning states
        case .idle: return helperStatus == .enabled ? "fan" : "fan.slash"
        }
    }
}

@main
struct FanBoostApp: App {
    @StateObject private var state = AppState()

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
