# Source and binary releases

Cobble and its Chromium SDK are separate source repositories. Original project
code is licensed under GPLv3; upstream materials retain their own terms.

| Repository | Contents |
| --- | --- |
| [Cobble](https://github.com/ignaciojuarez/cobble-browser) | Native browser, WebKit/Chromium adapters, UI, persistence and tests |
| [Chrome SDK](https://github.com/ignaciojuarez/chrome-sdk) | Swift API, native bridge, Chromium patches, build tools and harness |

The app’s Xcode project builds WebKit independently. Full combines the app with
a matching SDK/runtime built from the pinned Chromium source. See
[CHROMIUM.md](../../CHROMIUM.md) for that build boundary.

## Binary release checklist

Source publication does not imply a ready-to-install release. Before publishing
an app download:

- [ ] Build from the published source pins; record toolchain, architecture and artifact hashes.
- [ ] Include applicable licenses/notices and corresponding source for the exact shipped components.
- [ ] Verify complete framework/helper signing, hardened runtime and Chromium child sandboxing.
- [ ] Notarize and staple the app; qualify Gatekeeper and first launch on a clean Mac.
- [ ] Test upgrade, existing logins, interrupted installation and rollback.
- [ ] State supported capabilities, known limitations and security-update ownership.

[ROADMAP.md](../../ROADMAP.md) owns the remaining release gates. Authentication
requirements are tracked in [passwords.md](passwords.md) and
[apple-browser.md](apple-browser.md).
