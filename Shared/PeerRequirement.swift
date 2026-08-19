// FanBoost — XPC peer code-signing requirement, built per build configuration
// from values embedded in THIS binary's Info.plist. Shared by app and helper.
// GPL-2.0.
import Foundation

public let kAppBundleID = "com.kamilkovac.FanBoost"
public let kHelperBundleID = "com.kamilkovac.FanBoostHelper"

/// Which signing identity class a build is expected to carry. Debug is signed
/// with an Apple Development leaf, Release with a Developer ID Application
/// leaf — pinning the class makes the two configs non-interchangeable even
/// though they share a Team OU.
public enum IdentityClass: String {
    case appleDevelopment = "apple-development"
    case developerID = "developer-id"

    /// Apple's marker OIDs for the leaf certificate of each identity class.
    var leafOID: String {
        switch self {
        case .appleDevelopment: return "field.1.2.840.113635.100.6.1.12"
        case .developerID:      return "field.1.2.840.113635.100.6.1.13"
        }
    }
}

/// Team + identity class read from THIS binary's Info.plist. `nil` when either
/// key is missing or malformed — callers MUST fail closed (helper refuses to
/// serve, app refuses to connect), never fall back to a permissive default.
public struct PeerConfig {
    public let teamID: String
    public let identityClass: IdentityClass

    public static func fromBundle() -> PeerConfig? {
        guard let team = Bundle.main.infoDictionary?["FBTeamID"] as? String, !team.isEmpty,
              let raw = Bundle.main.infoDictionary?["FBIdentityClass"] as? String,
              let identity = IdentityClass(rawValue: raw)
        else { return nil }
        return PeerConfig(teamID: team, identityClass: identity)
    }

    /// Requirement pinning a peer with the given bundle id, this config's Team
    /// OU, and this config's signing identity class.
    public func requirement(forBundleID bundleID: String) -> String {
        fanboostRequirement(bundleID: bundleID, teamID: teamID, identityClass: identityClass)
    }
}

/// The single source of truth for the XPC peer requirement string. Used by
/// PeerConfig at runtime and by the checks/reqtool executable so the
/// verification script tests the exact string the app/helper construct.
public func fanboostRequirement(bundleID: String, teamID: String,
                                identityClass: IdentityClass) -> String {
    "anchor apple generic"
    + " and identifier \"\(bundleID)\""
    + " and certificate leaf[subject.OU] = \"\(teamID)\""
    + " and certificate leaf[\(identityClass.leafOID)] exists"
}
