// FanBoost — XPC client for the privileged helper. GPL-2.0.
import Foundation

final class HelperClient {
    private var connection: NSXPCConnection?

    /// Defense-in-depth, symmetric with the helper: pin the privileged helper's
    /// signature before use. Fails closed (returns nil) if this build's
    /// FBTeamID/FBIdentityClass are missing, so a squatted/replaced service is
    /// never trusted blindly.
    private func currentConnection() -> NSXPCConnection? {
        if let connection { return connection }
        guard let req = PeerConfig.fromBundle()?.requirement(forBundleID: kHelperBundleID) else {
            return nil
        }
        let c = NSXPCConnection(machServiceName: kHelperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanBoostXPC.self)
        c.setCodeSigningRequirement(req)
        // Clear the cache only if it still holds THIS connection: a stale
        // handler arriving after reconcile has already cached a fresh
        // connection to the new helper must not clear that fresh one.
        c.invalidationHandler = { [weak self, weak c] in
            DispatchQueue.main.async {
                if let self, let c, self.connection === c { self.connection = nil }
            }
        }
        c.resume()
        connection = c
        return c
    }

    /// Proxy whose calls fail over to `onError` if the helper is unreachable,
    /// or nil if the peer requirement can't be built (fail closed).
    func proxy(onError: @escaping (Error) -> Void) -> FanBoostXPC? {
        currentConnection()?.remoteObjectProxyWithErrorHandler(onError) as? FanBoostXPC
    }

    /// Drop the cached connection NOW. Reconciliation calls this between the
    /// old helper's confirmed restore and unregister/register, so the next
    /// proxy() connects fresh — to the new helper, never a stale peer. The
    /// invalidationHandler still runs and keeps its normal safety semantics.
    func invalidate() {
        connection?.invalidate()
        connection = nil
    }
}
