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
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
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
}
