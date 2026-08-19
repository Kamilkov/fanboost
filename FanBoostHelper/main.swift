// FanBoost helper daemon — XPC listener, dead-man timer, startup restore.
// Runs as root via SMAppService. GPL-2.0.
//
// Concurrency model: every FanController access (XPC calls, connection
// invalidation/interruption, dead-man timer, SIGTERM) runs on one serial
// queue; the controller itself is not thread-safe.
import Foundation

// --dryrun-check: exercise discovery → boost → restore → Ftst-unlock paths
// against the simulated SMC and exit. Forces dry-run so it can never write
// hardware.
let dryRunCheck = CommandLine.arguments.contains("--dryrun-check")
if dryRunCheck { setenv("FANBOOST_DRY_RUN", "1", 1) }

let controllerQueue = DispatchQueue(label: "com.kamilkovac.FanBoostHelper.controller")
let controller = FanController()

// Startup restoration: manual SMC state can persist across a helper crash,
// so every start (including a launchd KeepAlive restart) returns to auto.
controllerQueue.sync { controller.restoreAuto() }

if dryRunCheck {
    precondition(controller.fans.count == 2, "dry-run should simulate 2 fans")
    precondition(controller.boost(percent: 75) == nil, "dry-run boost failed")
    precondition(controller.boosting, "not boosting after boost")
    controller.restoreAuto()
    precondition(!controller.boosting, "still boosting after restore")

    // SMC status 0x82 must trigger exactly one Ftst unlock, then succeed.
    controller.simulatedResult = ["F0Md": 0x82]
    precondition(controller.boost(percent: 75) == nil, "0x82 should unlock via Ftst")
    precondition(controller.ftstWrites == 1, "expected exactly one Ftst write")
    controller.restoreAuto()

    // Any other failure must NOT attempt Ftst and must fail the boost.
    controller.simulatedResult = ["F0Md": 0x50]
    precondition(controller.boost(percent: 75) != nil, "0x50 must fail the boost")
    precondition(controller.ftstWrites == 1, "non-0x82 failure must not write Ftst")
    controller.simulatedResult = [:]
    controller.restoreAuto()

    print("dryrun-check OK: \(controller.rangesDescription)")
    exit(0)
}

// The XPC code-signing requirement is built from values Xcode embeds in the
// helper's Info.plist section; refuse to serve without them rather than run
// with a malformed requirement.
guard !BuildConfig.appBundleID.isEmpty, !BuildConfig.teamID.isEmpty else {
    log("missing FBAppBundleID/FBTeamID in embedded Info.plist — refusing to start")
    exit(1)
}

let deadManInterval: TimeInterval = 60

final class HelperService: NSObject, FanBoostXPC {
    var lastPing = Date() // controllerQueue only

    func status(reply: @escaping (Int32, String, Bool) -> Void) {
        controllerQueue.async {
            reply(Int32(controller.fanCount), controller.rangesDescription, controller.boosting)
        }
    }

    func boost(percent: Double, reply: @escaping (String?) -> Void) {
        controllerQueue.async {
            self.lastPing = Date()
            reply(controller.boost(percent: percent))
        }
    }

    func restoreAuto(reply: @escaping (String?) -> Void) {
        controllerQueue.async {
            controller.restoreAuto()
            reply(nil)
        }
    }

    func ping() {
        controllerQueue.async { self.lastPing = Date() }
    }

    func clientGone() {
        controllerQueue.async {
            if controller.boosting {
                log("client connection lost while boosting — restoring auto")
                controller.restoreAuto()
            }
        }
    }
}

let service = HelperService()

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Public macOS 13 API; only the signed FanBoost app may connect.
        // No debug bypass — Debug builds are Apple Development-signed with
        // the Debug Team ID, so the requirement holds there too.
        connection.setCodeSigningRequirement(
            "anchor apple generic and identifier \"\(BuildConfig.appBundleID)\"" +
            " and certificate leaf[subject.OU] = \"\(BuildConfig.teamID)\"")
        connection.exportedInterface = NSXPCInterface(with: FanBoostXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.clientGone() }
        connection.interruptionHandler = { service.clientGone() }
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachService)
listener.delegate = delegate
listener.resume()

// Dead-man: if the app stops pinging while boosted, restore auto.
// DispatchSourceTimer on the controller queue — same serialization as
// everything else that touches the controller.
let deadMan = DispatchSource.makeTimerSource(queue: controllerQueue)
deadMan.schedule(deadline: .now() + 15, repeating: 15)
deadMan.setEventHandler {
    if controller.boosting, Date().timeIntervalSince(service.lastPing) > deadManInterval {
        log("dead-man expired — restoring auto")
        controller.restoreAuto()
    }
}
deadMan.resume()

// Graceful termination (launchd unload sends SIGTERM): restore via a
// DispatchSource on the controller queue — no SMC work inside a raw signal
// handler, and no race with in-flight XPC calls.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: controllerQueue)
sigterm.setEventHandler {
    controller.restoreAuto()
    exit(0)
}
sigterm.resume()

log("listening on \(kHelperMachService)")
RunLoop.main.run()
