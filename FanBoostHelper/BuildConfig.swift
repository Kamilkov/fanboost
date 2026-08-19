// FanBoost helper — build configuration read from the Info.plist section
// embedded in the helper binary (values expanded from build settings by
// Xcode, so a clean clone builds without any generated files). GPL-2.0.
import Foundation

enum BuildConfig {
    static let appBundleID = Bundle.main.infoDictionary?["FBAppBundleID"] as? String ?? ""
    static let teamID = Bundle.main.infoDictionary?["FBTeamID"] as? String ?? ""
}
