# Decisions

Current product and engineering choices. Update a decision in place when it changes; keep status and evidence in `ROADMAP.md` and feature details in `docs/features/`.

## Product

- **Native macOS 26+ browser, Swift 6.** AppKit owns windows and commands; SwiftUI renders browser chrome. Sidebar favorites, pins, spaces, folders, and keyboard navigation are core. Prefer native feel, modest resource use, and recoverable state over feature count.
- **No AI chrome, telemetry, or Cobble password vault.** Optional iCloud sync covers selected browser records only, never cookies, passwords, private tabs, or engine stores. Apple Passwords and passkeys require Apple's browser entitlements; Chromium may use Apple's system helper. Sign in with Apple uses a WebKit authorization sheet. Default-browser registration uses Launch Services. See `docs/features/apple-browser.md`, `docs/features/passwords.md`, and `docs/features/sync.md`.
- **Release gates are independent.** Automated checks, manual compatibility, seven-day use, signing, notarization, and clean-install validation each need their own evidence. A successful build does not close another gate.

## Interface and organization

- **AppKit owns each window; SwiftUI owns its presentation.** Persist geometry and close/quit behavior through native window controllers. Keep navigation and address entry in the sidebar; its pinning and hover behavior must not shift the webpage. The command overlay searches destinations and current-space tabs, and is not an assistant.
- **Settings use a native toolbar and reusable page/group/row layout.** Preferences store semantic choices; SwiftUI maps them to browser chrome, not webpage content. Show only supported controls.
- **Saved organization is shared; browsing is window-local.** Favorites belong to a profile, pins to a space, and temporary tabs to one window. A saved item may have a separate live tab in multiple windows; no native page is shared between windows. Unloading preserves the saved destination but discards page memory.
- **Spaces organize; profiles isolate.** A space belongs to one profile. Same-profile spaces share website storage. Folder parents stay within their space and cannot cycle. Deleting a folder promotes its immediate contents; never delete the last space.
- **History and bookmarks are distinct.** History defaults to 90 days and records committed normal visits; bookmark titles are independent of page titles. Clearing one does not silently delete the other. Temporary tabs survive restart, while new windows and empty spaces start without tab records. There is no automatic archive.
- **Use native editing and bounded metadata.** One shortcut catalog drives menus and settings; preserve standard macOS shortcuts. Favicons come from loaded pages through their engine store, are stored as bounded origin-scoped PNGs, and never come from private pages.

## Engines and website data

- **WebKit is the default.** A separate Chromium SDK packages the same native UI for Full builds. Keep rendering SDK types in adapters behind `Engine/Contracts/`; no CEF, Electron, dynamic plugin framework, or WebKit fork. Preserve Chromium's launcher, helper signing, child sandbox, and server-trust validation. Engine updates require source review, tests, and matched artifacts.
- **One Cobble identity and workspace.** Fast and Full use `com.ignacio.cobble` and the same normal records. Chromium storage stays separate. If Chromium is absent, assigned tabs temporarily use WebKit without rewriting saved engine choices; unknown engine IDs fail explicitly. Explicit engine switches require reload confirmation; redirects and popup chains keep their engine.
- **WebKit owns its website data.** The default profile remains `legacyDefault` on `WKWebsiteDataStore.default()` so existing logins survive. Other profiles use stable named stores. Never copy private WebKit databases or change `HOME` to move data. Profile deletion waits for a durable session write, retires affected pages, and removes only the named store; active downloads block it.
- **Cookie sharing is an opt-in experiment.** A normal profile may copy login cookies between engines during a switch, with explicit replacement of conflicts. Empty sources preserve destination state. It does not migrate credentials, private data, live state, or database files. See `docs/features/login-sharing.md`.
- **Compatibility follows measured failures.** Use public APIs and narrow site rules; a user-agent string cannot add missing browser capabilities. Validate notifications, passkeys, DRM, capture, fullscreen, PiP, and extensions in real workflows before claiming support. WebKit WebExtensions require explicit site grants and private access opt-in; native messaging is denied.
- **Tab mute changes native output only.** Keep the runtime-checked private WebKit bridge confined to `Engine/WebKit/WebKitAudioMute.swift`. Refuse mute changes after capture permission or control has been used on that page; playback suspension and element-volume changes are not substitutes. See W18 in `ROADMAP.md`.

## Reliability and privacy

- **One live page per tab, created lazily.** Route callbacks by tab and host generation. Recovery stores URLs and organization, not DOM state, unsaved forms, or full page history. Avoid replaying unsafe requests.
- **Persistence failures are visible.** Validate versioned records, migrate safely, write atomically, retain recoverable backups, and preserve corrupt or newer data rather than overwriting it. Commit destructive intent before deleting external state; failed final writes stop quit or profile deletion.
- **Private windows use nonpersistent stores.** Their tabs do not enter durable sessions or history. Private mode is not anonymity. Downloads and deliberate saved-organization edits must have explicit behavior.
- **Keep trust and permissions tied to the actual request.** Never bypass TLS. Prompts identify the requesting site and window; stale, ambiguous, or dismissed requests resolve safely once. Only explicit remembered grants persist, and private or embedded requests do not inherit normal grants.
- **Diagnostics stay local and redacted.** Do not upload browsing data. Debug-only private WebKit process getters are adapter-local, runtime-checked, and absent from Release; missing counters remain unknown rather than invented.
