import AuthenticationServices

enum ApplePasskeys {
    enum Status: Equatable { case unentitled, notDetermined, denied, notConfigured, ready }

    @MainActor private static var requested = false

    /// System Settings → Privacy & Security → Passkeys Access for Web Browsers.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_PasskeyAccess")!

    /// Entitled browsers must ask before WebKit/Chromium can use iCloud Keychain passkeys.
    @MainActor static func prepareIfNeeded() {
        guard !requested, BrowserEntitlements.hasPasskeys else { return }
        requested = true
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        guard manager.authorizationStateForPlatformCredentials == .notDetermined else { return }
        manager.requestAuthorizationForPublicKeyCredentials { _ in }
    }

    @MainActor static var status: Status {
        guard BrowserEntitlements.hasPasskeys else { return .unentitled }
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        default: break
        }
        if #available(macOS 26.2, *), !ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys {
            return .notConfigured
        }
        return .ready
    }
}
