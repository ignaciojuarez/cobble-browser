# Passwords and authentication

Cobble has no password vault. WebKit uses system AutoFill and passkeys when Apple grants the required entitlements. Chromium Apple Passwords integration is unbuilt. The approval paths are in [Apple browser approval](apple-browser.md); release gates remain in [ROADMAP.md](../../ROADMAP.md).

| Path | Current state | Remaining evidence |
| --- | --- | --- |
| WebKit passwords / third-party AutoFill | `BrowserEntitlements` checks `com.apple.developer.web-browser`; current builds lack the grant. | Add the granted key to the signed build; verify fill and save on real sites with Apple Passwords and third-party providers. P8e. |
| WebKit passkeys | `ApplePasskeys.prepareIfNeeded()` calls `ASAuthorizationWebBrowserPublicKeyCredentialManager` only when `com.apple.developer.web-browser.public-key-credential` is present. | Grant, signed build, real registration and assertion. P8e. |
| Chromium Apple Passwords / OTP | No client; general extension native messaging is unsupported. | Apple must allow the actual Full helper parent through its signed-browser list or passkeys entitlement. Then integrate and qualify the official extension/helper, pairing, fill, OTP, and profile isolation. C21/P8e. |
| Chromium WebAuthn / passkeys | A Debug Chromium Views sheet can abort in `AuthenticatorRequestDialogViewControllerViews`. | Host and qualify the native SDK dialog, including register, assert, cancel, and Touch ID. The Apple helper list does not fix this. C22/C34. |
| Sign in with Apple | WebKit uses its system flow. Chromium opens `appleid.apple.com/auth/authorize` in a nonmodal WKWebView window and returns URL callbacks; isolated cancellation and ownership tests pass. | Real-account/site qualification. Chromium POST callbacks remain unsupported. C22/P8e. |
| HTTP / proxy authentication | Owned, nonpersistent prompts and cancellation; focused Full HTTP/proxy checks passed. | Current matched Full and real-site qualification. P4/C22/C34. |
| TLS client certificates | WebKit chooser has focused tests. Chromium ABI 12 owns chooser requests and adapter-local credentials. | Matched Full TLS selection, cancellation, and failure checks. C34. |
| Cross-engine signed-in state | Separate, default-off cookie transfer passed an isolated 9/9 fixture. | Real-site acceptance; no universal login claim. See [login sharing](login-sharing.md). |

## Apple Passwords in Chromium

Apple's [browser distribution list](https://github.com/apple/password-manager-resources/blob/main/quirks/web-browser-extension-distribution-information.json) is packed into `PasswordManagerBrowserExtensionHelper` launch constraints during an OS update. The helper accepts a parent with the listed **code-signing identifier and Team ID**, or potentially the passkeys entitlement. The bundle ID alone is insufficient. Full's executable is `Cobble.app/Contents/MacOS/Chromium`; inspect the binary that actually starts the helper before filing the [Apple repository request](https://github.com/apple/password-manager-resources#how-apple-uses-web-browser-extension-distribution-information). The signed helper's live constraint is the final check. An entitlement or JSON merge alone does not prove working fill.

The extension's six-digit code is a **helper-session pairing PIN**, not Apple ID two-factor authentication. It may be required again after a helper or extension restart, browser quit, or lost native connection; there is no supported persistent pairing token. A healthy session should survive tab and window changes. Qualification must cover idle, last-window close/reopen, sleep/wake, profile switch, helper exit, and Quit. Never persist the PIN, session key, or passwords. Apple's [extension worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) and [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) docs explain why the connection matters.

WebKit has no public API for a custom picker over the live Apple vault; entitled WebKit uses the system picker. A custom Chromium picker would require an approved helper path and SDK-owned field filling. Cobble excludes JS/clipboard password fill, a copied vault, a spoofed extension ID, and a background sidecar. Password integration does not copy cookies.

## Implementation

| Code | Purpose |
| --- | --- |
| `App/BrowserEntitlements.swift`, `App/ApplePasskeys.swift` | Runtime entitlement probe and passkey preparation |
| `Domain/AppleSignIn.swift`, `Engine/WebKit/AppleSignInSession.swift` | Sign in with Apple URL rules and WKWebView window |
| `Engine/WebKit/WebKitPage.swift`, `Engine/Chromium/ChromiumPage.swift` | Engine authentication and sign-in handoff |
| `Tests/AppleWebAuthTests.swift`, `Tests/BrowserEntitlementsTests.swift` | Isolated sign-in ownership and unsigned entitlement behavior |

Local fixture results do not establish Apple approval, real-account behavior, or signed release readiness.
