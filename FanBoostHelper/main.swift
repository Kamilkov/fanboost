// FanBoost helper daemon — XPC listener, dead-man timer, startup restore.
// Runs as root via SMAppService. GPL-2.0.
//
// Concurrency model: every FanController / OwnerGate access (XPC calls,
// connection invalidation/interruption, dead-man timer, recovery timer,
// SIGTERM) runs on one serial queue; those types are not thread-safe.
import Foundation

// --dryrun-check: exercise discovery/boost/restore/Ftst/recovery/ownership
// against the simulated SMC and exit. Forces dry-run so it can never write
// hardware.
let dryRunCheck = CommandLine.arguments.contains("--dryrun-check")
if dryRunCheck { setenv("FANBOOST_DRY_RUN", "1", 1) }

let controllerQueue = DispatchQueue(label: "com.kamilkovac.FanBoostHelper.controller")
let controller = FanController()

// Startup restoration: manual SMC state can persist across a helper crash,
// so every start (including a launchd KeepAlive restart) returns to auto.
controllerQueue.sync { _ = controller.restoreAuto() }

if dryRunCheck {
    // Ownership gate — ObjectIdentifier value tokens stand in for the
    // NSXPCConnection identity used in production.
    let gate = OwnerGate()
    let objA = NSObject(), objB = NSObject()
    let a = ObjectIdentifier(objA), b = ObjectIdentifier(objB)
    precondition(gate.claim(a), "A should claim when unowned")
    precondition(!gate.claim(b), "B must not claim while A owns")
    precondition(gate.claim(a), "A re-boost while owning is allowed")
    precondition(gate.isOwner(a) && !gate.isOwner(b), "ownership identity wrong")
    precondition(gate.mayActUnowned(a), "owner may act")
    precondition(!gate.mayActUnowned(b), "non-owner may not act while owned")
    // Owner-loss semantics: a NON-owner invalidation is inert…
    precondition(!gate.releaseIfOwner(b), "non-owner invalidation must not release")
    precondition(gate.isOwner(a), "owner intact after non-owner invalidation")
    // …and the OWNER's invalidation releases immediately.
    precondition(gate.releaseIfOwner(a), "owner invalidation releases")
    precondition(!gate.isOwned, "unowned after owner release")
    precondition(gate.mayActUnowned(b), "any client may restore when unowned")

    // Discovery: default two fans, boost/restore, Ftst 0x82, non-0x82.
    precondition(controller.fans.count == 2, "dry-run should simulate 2 fans")
    precondition(controller.boost(percent: 75) == nil, "dry-run boost failed")
    precondition(controller.boosting, "not boosting after boost")
    controller.restoreAuto()
    precondition(!controller.boosting, "still boosting after restore")

    controller.simulatedResult = ["F0Md": 0x82]
    precondition(controller.boost(percent: 75) == nil, "0x82 should unlock via Ftst")
    precondition(controller.ftstWrites == 1, "expected exactly one Ftst write")
    controller.restoreAuto()
    controller.simulatedResult = ["F0Md": 0x50]
    precondition(controller.boost(percent: 75) != nil, "0x50 must fail the boost")
    precondition(controller.ftstWrites == 1, "non-0x82 failure must not write Ftst")
    controller.simulatedResult = [:]
    controller.restoreAuto()

    // §5 discovery states: FNum=0 is fanless; open/FNum error and incomplete
    // ranges are unavailable (NOT fanless); recovery re-discovers and restores.
    controller.simulatedFNumZero = true
    controller.attemptDiscovery()
    precondition(controller.discovery == .fanless, "FNum=0 must be fanless")
    precondition(controller.boost(percent: 75) == "no fans to control", "fanless boost msg")
    controller.simulatedFNumZero = false

    controller.simulatedOpenFail = true
    controller.attemptDiscovery()
    precondition(controller.discovery == .unavailable, "open fail must be unavailable")
    precondition(controller.fanCount == 0 && controller.fans.isEmpty, "stale state must be reset on open fail")
    precondition(controller.rangesDescription == "fan state unknown", "unavailable != fanless")
    precondition(controller.boost(percent: 75)?.contains("unavailable") == true, "unavailable refuses boost")
    controller.simulatedOpenFail = false

    controller.simulatedIncomplete = true
    controller.attemptDiscovery()
    precondition(controller.discovery == .unavailable, "incomplete ranges must be unavailable/retryable")
    precondition(controller.fans.isEmpty, "no usable fans while incomplete")
    precondition(controller.boost(percent: 75)?.contains("unavailable") == true, "incomplete refuses boost")
    controller.simulatedIncomplete = false

    controller.attemptDiscovery() // recovery
    precondition(controller.discovery == .available, "should recover to available")
    precondition(controller.boost(percent: 75) == nil, "boost works after recovery")
    precondition(controller.restoreAuto() == nil, "restore succeeds when writes ok")
    precondition(!controller.boosting && !controller.pendingRestore, "clean after successful restore")

    // Restore is a checked op: a failed auto write keeps boosting + pending;
    // a later successful restore clears both.
    precondition(controller.boost(percent: 75) == nil, "boost for restore-fail test")
    controller.simulatedRestoreFail = true
    precondition(controller.restoreAuto() != nil, "failed auto write returns error")
    precondition(controller.boosting, "still boosting after failed restore")
    precondition(controller.pendingRestore, "pendingRestore set after failed restore")
    controller.simulatedRestoreFail = false
    precondition(controller.restoreAuto() == nil, "retry restore succeeds")
    precondition(!controller.boosting && !controller.pendingRestore, "pending cleared after success")

    // Restore while unavailable errors and stays pending until recovery.
    controller.simulatedOpenFail = true
    controller.attemptDiscovery()
    precondition(controller.restoreAuto() != nil, "unavailable restore errors")
    precondition(controller.pendingRestore, "pending set while unavailable")
    controller.simulatedOpenFail = false
    controller.attemptDiscovery()
    precondition(controller.restoreAuto() == nil, "restore ok after recovery")
    precondition(!controller.pendingRestore, "pending cleared after recovery restore")

    // §6 key-length validator (reaches the real C copy_key guard).
    precondition(fb_key_is_valid("F0Md") == 1, "4-byte key must be accepted")
    precondition(fb_key_is_valid("F10Md") == 0, "5-byte key must be rejected")
    precondition(fb_key_is_valid("F0M") == 0, "3-byte key must be rejected")

    // §4 summary mapping (pure, synthetic results — no filesystem, no
    // production paths). ENOENT→absent reads as nothing-found; refused/failed
    // are surfaced and never masked; success is reported.
    precondition(LegacyCleanup.summarize([("x", .absent), ("y", .absent)])
        == ("no legacy root artifacts found", true), "all-absent summary")
    let sref = LegacyCleanup.summarize([("x", .refused("symlink")), ("y", .removed)])
    precondition(!sref.success && sref.summary.contains("refused"), "refusal surfaced")
    let sfail = LegacyCleanup.summarize([("x", .failed(EPERM)), ("y", .absent)])
    precondition(!sfail.success && sfail.summary.contains("cleanup errors"), "error surfaced")
    let sok = LegacyCleanup.summarize([("x", .removed), ("y", .removed)])
    precondition(sok.success && sok.summary.hasPrefix("removed: "), "success summary")

    // §4 SecureUnlink against a HARMLESS temp root (never production paths):
    // a safe regular file is removed; an intermediate directory symlink and a
    // final-component symlink are refused and their targets survive.
    do {
        let fm = FileManager.default
        // Atomically create a fresh, unpredictable, 0700 private root with
        // mkdtemp — no pre-delete of a predictable name, so another local
        // process cannot swap/symlink the test root out from under us.
        var tmpl = Array("/private/tmp/capture-fan.XXXXXX".utf8CString)
        let base: String = tmpl.withUnsafeMutableBufferPointer {
            precondition(mkdtemp($0.baseAddress) != nil, "mkdtemp failed")
            return String(cString: $0.baseAddress!)
        }
        defer { try? fm.removeItem(atPath: base) } // cleanup on normal exit
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try! fm.createDirectory(atPath: base + "/a/b", withIntermediateDirectories: true, attributes: attrs)
        let rootfd = open(base, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        precondition(rootfd >= 0, "temp root open")
        defer { close(rootfd) }
        let me = getuid()

        let safe = base + "/a/b/file"
        fm.createFile(atPath: safe, contents: Data("x".utf8))
        precondition(SecureUnlink.removeFile(startFd: rootfd, dirs: ["a", "b"], final: "file",
                                             requiredOwner: me) == .removed, "safe file removed")
        precondition(!fm.fileExists(atPath: safe), "safe file gone")

        // Intermediate directory symlink → refused; its target survives.
        try! fm.createDirectory(atPath: base + "/realdir", withIntermediateDirectories: true, attributes: attrs)
        fm.createFile(atPath: base + "/realdir/smc", contents: Data("keep".utf8))
        try! fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/realdir")
        if case .refused = SecureUnlink.removeFile(startFd: rootfd, dirs: ["link"], final: "smc",
                                                   requiredOwner: me) {} else {
            preconditionFailure("intermediate directory symlink must be refused")
        }
        precondition(fm.fileExists(atPath: base + "/realdir/smc"), "intermediate-symlink target survives")

        // Final-component symlink → refused; its target survives.
        try! fm.createDirectory(atPath: base + "/c", withIntermediateDirectories: true, attributes: attrs)
        fm.createFile(atPath: base + "/target", contents: Data("keep".utf8))
        try! fm.createSymbolicLink(atPath: base + "/c/flink", withDestinationPath: base + "/target")
        if case .refused = SecureUnlink.removeFile(startFd: rootfd, dirs: ["c"], final: "flink",
                                                   requiredOwner: me) {} else {
            preconditionFailure("final-component symlink must be refused")
        }
        precondition(fm.fileExists(atPath: base + "/target"), "final-symlink target survives")
        precondition(fm.fileExists(atPath: base + "/c/flink"), "symlink itself not removed")
        // rootfd close + base removal handled by the defers above.
    }

    print("dryrun-check OK: \(controller.rangesDescription)")
    exit(0)
}

// Per-config XPC requirement is built from values Xcode embeds in the helper's
// Info.plist section. Fail closed if team/identity-class are missing/malformed
// rather than serving with a permissive requirement.
guard let peer = PeerConfig.fromBundle() else {
    log("missing/malformed FBTeamID/FBIdentityClass in embedded Info.plist — refusing to start")
    exit(1)
}
let clientRequirement = peer.requirement(forBundleID: kAppBundleID)

let deadManInterval: TimeInterval = 60
let owner = OwnerGate()

final class HelperService: NSObject, FanBoostXPC {
    var lastPing = Date() // controllerQueue only

    func status(reply: @escaping (Int32, String, Bool) -> Void) {
        controllerQueue.async {
            reply(Int32(controller.fanCount), controller.rangesDescription, controller.boosting)
        }
    }

    func boost(percent: Double, reply: @escaping (String?) -> Void) {
        // Capture the caller identity synchronously — NSXPCConnection.current()
        // is only valid inside the exported method body. We store a VALUE token
        // (ObjectIdentifier), not the connection. Fail closed on nil caller.
        guard let conn = NSXPCConnection.current() else {
            reply("internal error: no caller identity"); return
        }
        let caller = ObjectIdentifier(conn)
        controllerQueue.async {
            guard owner.claim(caller) else {
                reply("busy: another client owns the fans"); return
            }
            let err = controller.boost(percent: percent)
            if err == nil {
                self.lastPing = Date()
            } else {
                owner.releaseIfOwner(caller) // don't hold ownership on failure
            }
            reply(err)
        }
    }

    func restoreAuto(reply: @escaping (String?) -> Void) {
        guard let conn = NSXPCConnection.current() else {
            reply("internal error: no caller identity"); return
        }
        let caller = ObjectIdentifier(conn)
        controllerQueue.async {
            // Owner may restore; when unowned, any authenticated client may
            // (idempotent return-to-auto). A non-owner while another owns is
            // rejected with an error, not a silent success.
            guard owner.mayActUnowned(caller) else {
                reply("busy: another client owns the fans"); return
            }
            let err = controller.restoreAuto()
            if err == nil { owner.releaseIfOwner(caller) } // release only on success
            reply(err)
        }
    }

    func ping() {
        guard let conn = NSXPCConnection.current() else { return }
        let caller = ObjectIdentifier(conn)
        controllerQueue.async {
            if owner.isOwner(caller) { self.lastPing = Date() }
        }
    }

    func cleanupLegacy(reply: @escaping (String) -> Void) {
        // No caller identity dependency (does not touch fan ownership), but
        // still serialized. Runs the real fixed-path removal.
        controllerQueue.async { reply(LegacyCleanup.run()) }
    }

    func connectionGone(_ caller: ObjectIdentifier) {
        controllerQueue.async {
            if owner.releaseIfOwner(caller), controller.boosting {
                log("owner connection lost while boosting — restoring auto")
                _ = controller.restoreAuto()
            }
        }
    }
}

let service = HelperService()

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Public macOS 13 API; only the same-config signed FanBoost app may
        // connect. No debug bypass. Requirement pins bundle id + Team OU +
        // identity-class leaf OID, so Debug and Release are not interchangeable.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: FanBoostXPC.self)
        connection.exportedObject = service
        // Capture ONLY the identity VALUE token — never the connection object
        // (weak or strong). The handler always fires on invalidation and can
        // clear ownership without a retain cycle or lifetime dependency.
        let cid = ObjectIdentifier(connection)
        connection.invalidationHandler = { service.connectionGone(cid) }
        connection.interruptionHandler = { service.connectionGone(cid) }
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachService)
listener.delegate = delegate
listener.resume()

// Dead-man: if the owner stops pinging while boosted, restore auto and clear
// ownership. On the controller queue like everything else.
let deadMan = DispatchSource.makeTimerSource(queue: controllerQueue)
deadMan.schedule(deadline: .now() + 15, repeating: 15)
deadMan.setEventHandler {
    if controller.boosting, Date().timeIntervalSince(service.lastPing) > deadManInterval {
        log("dead-man expired — restoring auto")
        controller.restoreAuto()
        owner.clear()
    }
}
deadMan.resume()

// Ongoing recovery: runs while discovery is unavailable OR a restore is still
// pending. Re-attempts discovery (indefinitely) and retries any failed/deferred
// restore until it truly succeeds, so manual state from a crashed or partly
// failed run never lingers.
let recovery = DispatchSource.makeTimerSource(queue: controllerQueue)
recovery.schedule(deadline: .now() + 10, repeating: 10)
recovery.setEventHandler {
    if controller.discovery == .unavailable {
        controller.attemptDiscovery()
    }
    if controller.pendingRestore {
        if controller.restoreAuto() == nil {
            log("pending restore succeeded on retry")
        }
    }
}
recovery.resume()

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
