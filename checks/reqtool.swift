// FanBoost check helper: print the XPC peer requirement the app/helper build
// at runtime, so verify-requirements.sh tests the REAL Swift builder rather
// than a shell duplicate. Compile with Shared/PeerRequirement.swift.
// GPL-2.0.
import Foundation

@main
struct ReqTool {
    static func main() {
        let a = CommandLine.arguments
        guard a.count == 4, let cls = IdentityClass(rawValue: a[3]) else {
            FileHandle.standardError.write(Data(
                "usage: reqtool <bundleID> <teamID> <apple-development|developer-id>\n".utf8))
            exit(2)
        }
        print(fanboostRequirement(bundleID: a[1], teamID: a[2], identityClass: cls))
    }
}
