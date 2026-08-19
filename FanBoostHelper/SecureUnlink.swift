// FanBoost helper — fail-closed, descriptor-relative file removal. GPL-2.0.
//
// Walks a fixed directory chain from a caller-provided start fd using openat
// with O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC (no symlink is ever followed), refuses
// any component that is not owned by `requiredOwner` or is group/other
// writable, and unlinks the final component only after an fstatat
// (AT_SYMLINK_NOFOLLOW) confirms a regular file owned by `requiredOwner`.
// This removes the path-traversal / directory-symlink race in a root context.
//
// `startFd` is injectable (production opens "/", the test opens a temp root)
// so the exact same code path is exercised without touching real system paths.
import Foundation

enum SecureUnlink {
    enum Result: Equatable {
        case removed
        case absent
        case refused(String)
        case failed(Int32)
    }

    private static func checkDir(_ fd: Int32, _ label: String, _ owner: uid_t) -> String? {
        var st = stat()
        if fstat(fd, &st) != 0 { return "fstat failed" }
        if st.st_uid != owner { return "\(label): not owned by uid \(owner)" }
        if (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 { return "\(label): group/other-writable" }
        return nil
    }

    /// Remove `final` inside `dirs...` under `startFd`. Never follows a symlink
    /// at any component. Refuses non-root (non-`requiredOwner`) or writable
    /// components, and a final node that is a symlink / non-regular / wrong
    /// owner. Does not remove or rmdir any directory.
    static func removeFile(startFd: Int32, dirs: [String], final: String,
                           requiredOwner: uid_t) -> Result {
        if let why = checkDir(startFd, "start", requiredOwner) { return .refused(why) }

        var cur = startFd
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }

        for d in dirs {
            let next = openat(cur, d, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let e = errno
                if e == ENOENT { return .absent }
                if e == ELOOP || e == ENOTDIR { return .refused("\(d): symlink or not a directory") }
                return .failed(e)
            }
            opened.append(next)
            cur = next
            if let why = checkDir(cur, d, requiredOwner) { return .refused(why) }
        }

        var fst = stat()
        if fstatat(cur, final, &fst, AT_SYMLINK_NOFOLLOW) != 0 {
            let e = errno
            return e == ENOENT ? .absent : .failed(e)
        }
        if (fst.st_mode & S_IFMT) != S_IFREG { return .refused("\(final): not a regular file") }
        if fst.st_uid != requiredOwner { return .refused("\(final): not owned by uid \(requiredOwner)") }

        if unlinkat(cur, final, 0) != 0 {
            let e = errno
            return e == ENOENT ? .absent : .failed(e)
        }
        return .removed
    }
}
