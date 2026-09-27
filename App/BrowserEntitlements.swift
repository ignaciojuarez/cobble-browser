import Foundation
import Security

enum BrowserEntitlements {
    static let webBrowser = "com.apple.developer.web-browser"
    static let passkeys = "com.apple.developer.web-browser.public-key-credential"

    static var hasWebBrowser: Bool { has(webBrowser) }
    static var hasPasskeys: Bool { has(passkeys) }

    /// Restricted Apple entitlements are false until a signed, approved profile
    /// includes them. Do not add them to `Cobble.entitlements` before that.
    static func has(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        guard let value = SecTaskCopyValueForEntitlement(task, name as CFString, &error) else {
            return false
        }
        return (value as? Bool) == true
    }
}
