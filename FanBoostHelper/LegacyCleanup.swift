// FanBoost helper — removal of the obsolete capture-fan prototype's
// root-owned artifacts. GPL-2.0.
//
// Two FILES only, each removed with the fail-closed, descriptor-relative
// SecureUnlink walk (no symlink followed at any component, every directory
// must be root-owned and not group/other writable):
//   /private/etc/sudoers.d/capture-fan   (note: real path, not the /etc symlink)
//   /usr/local/libexec/capture-fan/smc
// The capture-fan directory is intentionally NOT rmdir'd — that removes the
// directory-removal race and leaves an empty dir, which is harmless.
//
// No caller-supplied path: the chains are compile-time constants.
import Foundation

enum LegacyCleanup {
    // /private/etc/sudoers.d/capture-fan
    static let sudoersDirs = ["private", "etc", "sudoers.d"]
    static let sudoersFinal = "capture-fan"
    static let sudoersLabel = "/private/etc/sudoers.d/capture-fan"
    // /usr/local/libexec/capture-fan/smc
    static let smcDirs = ["usr", "local", "libexec", "capture-fan"]
    static let smcFinal = "smc"
    static let smcLabel = "/usr/local/libexec/capture-fan/smc"

    /// Pure mapping of removal results → truthful summary. `success` is false
    /// if any removal genuinely failed or was refused. Tested directly with
    /// synthetic results (no filesystem, no production paths).
    static func summarize(_ steps: [(String, SecureUnlink.Result)]) -> (summary: String, success: Bool) {
        var removed: [String] = []
        var errors: [String] = []
        for (label, r) in steps {
            switch r {
            case .removed: removed.append(label)
            case .absent: break
            case .refused(let why): errors.append("\(label): refused (\(why))")
            case .failed(let e): errors.append("\(label): \(String(cString: strerror(e)))")
            }
        }
        let summary: String
        if !errors.isEmpty {
            summary = "cleanup errors: " + errors.joined(separator: "; ")
                + (removed.isEmpty ? "" : " (removed: \(removed.joined(separator: ", ")))")
        } else if removed.isEmpty {
            summary = "no legacy root artifacts found"
        } else {
            summary = "removed: \(removed.joined(separator: ", "))"
        }
        return (summary, errors.isEmpty)
    }

    @discardableResult
    static func run() -> String {
        let root = open("/", O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0 { let s = "cleanup error: cannot open /"; log("cleanupLegacy: \(s)"); return s }
        defer { close(root) }
        let steps: [(String, SecureUnlink.Result)] = [
            (sudoersLabel, SecureUnlink.removeFile(startFd: root, dirs: sudoersDirs,
                                                   final: sudoersFinal, requiredOwner: 0)),
            (smcLabel, SecureUnlink.removeFile(startFd: root, dirs: smcDirs,
                                               final: smcFinal, requiredOwner: 0)),
        ]
        let (summary, _) = summarize(steps)
        log("cleanupLegacy: \(summary)")
        return summary
    }
}
