// FanBoost — XPC client for the privileged helper. GPL-2.0.
import Foundation

final class HelperClient {
    private var connection: NSXPCConnection?

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: kHelperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanBoostXPC.self)
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    /// Proxy whose calls fail over to `onError` if the helper is unreachable.
    func proxy(onError: @escaping (Error) -> Void) -> FanBoostXPC? {
        currentConnection().remoteObjectProxyWithErrorHandler(onError) as? FanBoostXPC
    }
}
