// FanBoost — pure update/termination logic, shared by app and self-checks.
// GPL-2.0.
import Foundation

/// Startup reconciliation trigger: an absent or mismatched bundle-version
/// marker means the bundle changed underneath us (Sparkle update, manual
/// replacement, or first Sparkle-enabled run).
public func reconcileNeeded(lastRun: String?, current: String) -> Bool {
    lastRun != current
}

/// Outcome of the termination gate's single restoreAuto attempt.
public enum RestoreOutcome {
    case confirmed     // helper replied nil — fans automatic
    case failed        // helper replied an error
    case timedOut      // no reply within the bounded deadline
    case notAttempted  // no reachable helper to ask
}

/// Spec §5.1 fail-closed branching: graceful termination may proceed only
/// when this app owns no manual fan state (helper definitively not enabled
/// and not boosting) or the restore was CONFIRMED. Everything else — boosting,
/// or an expected-enabled helper without a confirmed restore — fails closed.
public func mayTerminate(helperEnabled: Bool, boosting: Bool, restore: RestoreOutcome) -> Bool {
    if case .confirmed = restore { return true }
    return !helperEnabled && !boosting
}

/// SMAppService state as reconciliation sees it.
public enum HelperState { case enabled, requiresApproval, unregistered }

/// What a reconciliation tick may do (spec §5.2 + B3 race fix).
public enum ReconcileAction: Equatable {
    case finish            // genuine first run, no helper installed: write marker
    case beginReplacement  // helper enabled, no replacement in flight: restore → async unregister → register
    case confirmOnly       // replacement pending and helper enabled: ONLY a fresh status round-trip
    case wait              // approval pending, or transient unregistered mid-replacement: never misclassify
}

/// Once a replacement has started (pendingReplacement persisted BEFORE
/// unregister), a transient unregistered/notFound state must never be taken
/// for first-run consent — that raced marker-write is exactly the bug this
/// encodes against.
public func reconcileAction(pendingReplacement: Bool, helper: HelperState) -> ReconcileAction {
    switch (pendingReplacement, helper) {
    case (false, .unregistered):    return .finish
    case (false, .enabled):         return .beginReplacement
    case (true, .enabled):          return .confirmOnly
    case (_, .requiresApproval),
         (true, .unregistered):     return .wait
    }
}

/// Smallest one-shot completion seam: the termination gate funnels both the
/// XPC restore reply and the timeout through one OneShot so AppKit's
/// reply(toApplicationShouldTerminate:) can never be called twice.
public final class OneShot {
    private let lock = NSLock()
    private var done = false
    public init() {}
    public func fire(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
