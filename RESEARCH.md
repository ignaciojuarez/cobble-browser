# Research

Current source findings and evidence limits. [`ROADMAP.md`](ROADMAP.md) owns
commitments and gates; feature documents own current behavior.

## Public-use audit

The September 25 source audit found ten data, permission, auth, sync, UI and
build issues. All ten received code fixes, including safe portable restore,
cross-window camera/microphone revocation, download-owned authentication,
validated tab-sync URLs, private undo, HTTP+HTTPS default registration, honest
mixed-content wording, and WebKit same-document History visits. The hosted
suite passed 564/564 after those fixes, with 8/8 Chromium adapter tests. These
were isolated tests on macOS 27/Xcode 27, not a signed-release or real-browser
acceptance gate.

The remaining material boundaries are:

| Area | Current evidence limit |
| --- | --- |
| Distribution | Development signatures and local assembly do not establish Developer ID, notarization, stapling, update/rollback or clean-Mac Gatekeeper behavior. |
| Authentication | Synthetic challenge/cookie fixtures do not qualify real WebKit client-certificate selection, Apple Passwords/passkeys, Chromium helper/WebAuthn, or real-site sign-in. See [`passwords.md`](docs/features/passwords.md). |
| Capture | Revocation stops capture across normal windows in a profile. Chromium only exposes stop-all; native failure retires the page. Real TCC/hardware and document-change signals remain open. |
| Sync | URL validation excludes known secret query keys, but unknown site-specific secrets cannot be detected generically. Two signed devices, account changes and recovery need qualification. |
| Downloads | Basic/Digest and synthetic client-certificate cases pass. Browser mTLS, quarantine/Gatekeeper, replacement and external-volume failures need artifact tests. |
| Daily use | VoiceOver, keyboard/IME, window and dialog focus, macOS 26 minimum, sustained use, site compatibility and resource budgets are not established by the hosted suite. |

Apple references: [hardened runtime](https://developer.apple.com/documentation/security/hardened-runtime),
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[download authentication](https://developer.apple.com/documentation/webkit/wkdownloaddelegate/download%28_%3Adidreceive%3Acompletionhandler%3A%29).

## Chromium service and storage boundaries

An isolated ordinary ABI 13 launch ran for 80 seconds with fresh and reused
unmanaged profiles and no broad network-suppression flags. Both observed zero
ListAccounts, AIM, GCM check-in or registration requests after targeted startup
changes. Component-update POSTs remained, and network-time traffic occurred in
the fresh profile. This supports only the measured unmanaged startup path;
managed policy, explicit sign-in, network changes and the current ABI 16 package
need separate captures. Safe Browsing being compiled/default-on is not proof
of active protection. Keep security updates while reviewing background traffic.

Website-data scopes differ by engine. WebKit supports record-based deletion or
global time-based removal, not their intersection. Chromium's domain filter
does not promise removal of every renderer/GPU cache and may affect cookies at
domain scope; its site inventory does not enumerate ordinary HTTP cache
entries. The UI must describe actual category/scope limits and report partial
failure. Sources in Chromium 153:
`content/browser/browsing_data/browsing_data_remover_impl.cc`,
`content/browser/storage_partition_impl.cc`,
`chrome/browser/browsing_data/chrome_browsing_data_remover_delegate.cc`.

The reviewed Chromium build has `USE_PROPRIETARY_CODECS=0` and Widevine disabled.
Native child Seatbelt inspection covered renderers, GPU, network and storage,
but not every utility service. `CHROMIUM.md` records the current pin and runtime
evidence; a later runtime must be checked again.

## Cross-engine authentication

WebKit and Chromium use separate website stores. A host-scoped, default-off
cookie transfer can help ordinary cookie sessions across an explicit engine
switch; it cannot establish universal login. Cookies may be incomplete,
rotated, partitioned or tied to device keys and server risk checks. Empty source
preserves destination state; conflicting destination cookies require explicit
replacement. The local 9/9 fixture uses synthetic accounts, and real-site
acceptance requires manual review. See [`login-sharing.md`](docs/features/login-sharing.md).

An identity-provider login can instead create a **new** destination-engine
session through the site's own authorization flow. That is a separate future
feature: state, nonce, PKCE, issuer, redirect, page lifetime and callback
consumption must stay bound to one request. GET redirects are only a potential
starting scope; POST callbacks, opener messages, silent iframes and FedCM need
other handling. Apple
[`ASWebAuthenticationSession`](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
does not export browser cookies. Google also documents
[embedded-user-agent restrictions](https://developers.google.com/identity/protocols/oauth2/policies).

## Product choices still requiring evidence

- WebKit's native content-rule lists and Chromium's Declarative Net Request
  are different blockers. Bundled rules, site exceptions, private scope and
  extension grants must be qualified per engine; do not promise universal
  Chrome-extension compatibility on WebKit. [Chromium DNR API](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest).
- Chromium's selected-file path intentionally denies sibling access and file
  subresources. Broad file access would require a new security design; see
  `CHROMIUM.md` and P9 in `ROADMAP.md`.
- The current Chromium runtime starts with zero Chromium tabs. Compare
  WebKit-only, mixed and Chromium-default use on equivalent workloads before
  deciding whether delayed startup is needed. Existing three-snapshot raw RSS
  diagnostics double-count shared memory and do not qualify a per-tab cost.
- Default-browser registration is a Launch Services choice. Apple Passwords,
  passkeys and the Chromium system helper are distinct approval paths; see
  [`apple-browser.md`](docs/features/apple-browser.md).
