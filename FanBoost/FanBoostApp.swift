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
        // Refresh registration state every poll so approving the helper in
        // System Settings takes effect without relaunching the app.
        let previous = helperStatus
        refreshHelperStatus()
        if previous != .enabled, helperStatus == .enabled { refreshStatusFromHelper() }
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
        helperProxy()?.restoreAuto { _ in }
        phase = .idle
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
        helper.proxy { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
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
                if count == 0 { self?.phase = .fanless }
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
        MenuBarExtra("FanBoost", systemImage: state.iconName) {
            Text(state.statusLine)
            Text(state.fanInfo)

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

            if let err = state.lastError {
                Divider()
                Text("Last error: \(err)").font(.caption)
            }

            Divider()
            Button("Quit FanBoost") { state.quit() }
        }
    }
}
