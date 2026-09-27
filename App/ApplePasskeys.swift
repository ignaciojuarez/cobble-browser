import AuthenticationServices

enum ApplePasskeys {
    @MainActor private static var requested = false

    /// Entitled browsers must ask before WebKit/Chromium can use iCloud Keychain passkeys.
    @MainActor static func prepareIfNeeded() {
        guard !requested, BrowserEntitlements.hasPasskeys else { return }
        requested = true
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        guard manager.authorizationStateForPlatformCredentials == .notDetermined else { return }
        manager.requestAuthorizationForPublicKeyCredentials { _ in }
    }
}
