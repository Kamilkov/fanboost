// FanBoost helper — single-active-client ownership. GPL-2.0.
//
// Ownership is by connection identity, stored as a VALUE token
// (ObjectIdentifier) rather than a reference to the NSXPCConnection. This lets
// invalidation/interruption handlers carry only the token — never the
// connection object (weak or strong) — so owner-loss is detected reliably
// without a retain cycle and without depending on object lifetime.
//
// All access is serialized on the controller queue (see main.swift); this
// type is not itself thread-safe.
import Foundation

final class OwnerGate {
    private var owner: ObjectIdentifier?

    var isOwned: Bool { owner != nil }

    /// Claim ownership for `id`. Succeeds when unowned (claims it) or when
    /// `id` already owns (re-boost). Fails if a different client owns.
    func claim(_ id: ObjectIdentifier) -> Bool {
        if owner == nil { owner = id; return true }
        return owner == id
    }

    func isOwner(_ id: ObjectIdentifier) -> Bool { owner == id }

    /// True when `id` may restore/keepalive: it owns, or nothing is owned
    /// (an unowned restore is an idempotent return-to-auto any client may do).
    func mayActUnowned(_ id: ObjectIdentifier) -> Bool { owner == nil || owner == id }

    /// Release ownership if `id` is the owner. Returns whether it was.
    @discardableResult
    func releaseIfOwner(_ id: ObjectIdentifier) -> Bool {
        if owner == id { owner = nil; return true }
        return false
    }

    /// Unconditional clear (dead-man expiry).
    func clear() { owner = nil }
}
