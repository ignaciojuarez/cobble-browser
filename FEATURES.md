# Features and capability contract

Native macOS 26+ browser with Arc-like organization. System `WKWebView` remains the default; Full includes the separate native Chromium SDK; Fast and Full share one Cobble identity and workspace; release qualification remains in development; no AI chrome. Implemented means the stated mechanism exists; Partial means part of the stated capability is absent. Planned and Excluded describe absent work and intentional omissions. Implementation status records code presence; it does not imply that manual compatibility or release gates have passed. `ROADMAP.md` records completion evidence.

| Label | Meaning |
| --- | --- |
| **v1** | Required for the public-v1 gate; partial source does not satisfy the requirement |
| **Qualified** | Commit only to verified behavior on the supported OS, using public APIs except for explicitly approved exceptions recorded in `DECISIONS.md`; document a clear unsupported outcome otherwise |
| **Later** | Explicit post-v1 increment or separate feasibility study |
| **Never** | Outside the product direction; change the decision explicitly before adding |

Implementation and qualification are separate. Automated checks use isolated local fixtures; real-site compatibility, accessibility, daily use, and distribution remain release gates in [ROADMAP.md](ROADMAP.md).

## Windows and native application

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| New/close/multiple windows, traffic lights, resize, fullscreen | v1 | Implemented | P1; independent live tabs, selection, and address focus |
| Native menus and focused-window shortcuts | v1 | Implemented | P1/P3; one searchable command catalog, Spaces/Tabs/History menus, ⌘1–⌘9 reserved for the first nine spaces of the focused window, shortcut recording/clearing/reset, conflict checks, immediate native menu updates; standard macOS editing/application shortcuts remain reserved |
| Geometry and session restoration | v1 | Implemented | P2; valid frames constrained to current displays |
| Default browser and external HTTP/HTTPS links | v1 | Implemented | P4/P7; `http`/`https` URL types (Editor), HTML/XHTML document types, and `NSUserActivityTypeBrowsingWeb` are declared. Settings registers http then https (`SettingsView.defaultBrowserSchemes`) and reports scheme failures. Incoming web links open in a normal window; `.html`/`.xhtml` files use the authorized local-file path. System Settings listing still needs signed-app qualification. macOS default browser does **not** wait on `com.apple.developer.web-browser` — that key is AutoFill. Inventory: `docs/features/apple-browser.md` |
| Settings for supported behavior | v1 | Implemented | P4–P5; engines, site rules, website data, blockers, permissions, history, downloads, shortcuts, design, diagnostics; no placeholder engine/permission controls |
| English and Spanish native UI | v1 | Implemented | Catalog-backed SwiftUI/AppKit labels and formatted messages; user names, URLs, paths, origins, IDs, and version values remain verbatim. Hosted 820-point Settings captures check bundle and layout behavior; manual accessibility and release qualification remain open. |
| Unified app identity and storage | v1 | Implemented | Fast/Full and Debug/Release use `com.ignacio.cobble`; no macOS App Sandbox; Chromium child sandbox retained; no legacy migration |
| Web Inspector | v1 | Implemented | P4/P8d; disabled by default, user opt-in exposes individual WebKit pages in Safari’s Develop menu |
| Developer ID, notarization, stapling | v1 | Planned | P7; required before external release |
| Manual beta updates | v1 | Planned | P7 initial distribution |
| Tested signed public update path | v1 | Planned | P7; Sparkle before public v1; verify update integrity and recovery |
| Merge windows, two-pane split | Later | Planned | P8b; explicit ownership, focus, and restoration |
| Optional iCloud sync | Requested increment | Implemented | Same iCloud account; categories selected per Mac. See `docs/features/sync.md`; signed two-device qualification pending |
| Bounded AppleScript tab commands | Requested increment | Implemented | Normal-window list/open/select/close by stable IDs, native dictionary and typed Apple-event fixtures; no private/file/JavaScript access |

## Tabs, sidebar, and Arc-style organization

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| Sidebar-first tabs, no top tab strip | v1 | Implemented | P3 |
| Browser themes | Requested increment | Implemented; visual qualification pending | Native liquid-glass, pixel-compatible Legacy, and square terminal-style Retro templates. Theme, browser font, and one accent are user-facing; changing font/accent creates a Custom variant. See `docs/features/themes.md`. |
| Create/close/select/reorder/duplicate/reopen tabs | v1 | Implemented | P1/P3; bounded in-memory closed-tab history |
| One retained live page per opened tab | v1 | Implemented | P1; background restore remains lazy |
| Title, favicon, loading/selection state | v1 | Implemented | P1/P3; page WebKit fetch of document icon or /favicon.ico, persisted 32×32 icons, outline-globe fallback; visual/site coverage remains |
| Empty page surface and new-tab command entry | v1 | Implemented | P1/P3; no remote new-tab feed |
| Spaces | v1 | Implemented | P3; shared website data within the default profile; optional one-grapheme emoji; create/edit sheet edits name and emoji together |
| Profile-wide favorites | v1 | Implemented | P3; saved destinations available in every space of that profile |
| Space pins | v1 | Implemented | P3; saved/home URL distinct from current navigation; reset/update-home remain commands with organization undo; hover minus unloads, unloaded × removes the pin; context menu is copy/share/duplicate/move/rename/remove |
| Nested folders for pins | v1 | Implemented | P3; deleting a folder preserves pins at space root; optional one-grapheme emoji; create/edit sheet edits name and emoji together |
| Temporary tabs | v1 | Implemented | P3; survive restart, no automatic archive |
| Multi-selected temporary-tab move/close | v1 | Implemented | Command-click toggles and Shift-click ranges in one window/space; saved rows retain their existing single-item controls |
| Rename/move/remove/reorder and organization undo | v1 | Implemented | P3; context/keyboard alternatives to dragging; space picker chips drag-reorder with a live insertion gap |
| Sidebar collapse/reopen and gesture interaction | v1 | Implemented | P3; reduced-motion-aware transitions; unpinned sidebar hides chrome and peeks as a leading-edge overlay without shifting the page; horizontal sidebar trackpad gestures track one-to-one and switch spaces at 25% of sidebar width, with live neighboring-space previews and reversible page selection; release settles the panels; no haptic feedback; stop at the first/last space; no gesture setting; physical trackpad feel remains an acceptance check |
| Command overlay and local open-tab search | v1 | Implemented | P3; navigation/search and searchable command catalog; open-tab suggestions stay within the current space; stale results revalidated on activation |
| Media activity and tab audio mute | Qualified | Implemented with capture restriction | P3/P4; native output mute preserves playback and page audio controls, including extension requests. Source-audio activity is separate from output mute. Runtime-checked private WebKit bridge is explicitly scoped; changed mute values are refused after capture history, including unmute (fresh tab required). The pinned Chromium ABI 16 includes native output mute. See W18 in `ROADMAP.md` |
| Close other temporary tabs | v1 | Implemented | P3; preserves saved items and other spaces/windows and uses native close requests |
| Directional close, numbered tabs and tab behavior | Requested increment | Implemented; September 8 isolated checks pass | Close above/below preserves saved items and other spaces; unassigned numbered commands follow sidebar order; optional adjacent insertion and full MRU cycling preserve existing defaults |
| Recording indicators | Qualified v1 | Implemented | P3/P4; favicon stays; red recording dot while camera is live, else a smaller mic glyph; muted glyphs and accessible status; unload clears the indicator; tab mute control is hidden while capture is active or blocked |
| Sidebar width adjustment | v1 | Implemented | P3; native 20-point target spans both sides of the boundary, persistent cursor, hover indicator, bounded drag, double-click reset and accessibility adjustments |
| Multiple profile management UI | Qualified increment | Implemented; isolation qualification pending | P8a; local create/rename/open/delete, stable named WebKit stores, default-store preservation and profile-scoped organization/library/permissions/windows |
| Move live tab to a new window | v1 | Implemented | Normal WebKit tabs retain native page state; guarded during pending edits/actions; private and unavailable adapters excluded |
| Nested folders | Requested increment | Implemented | P8d; same-space acyclic parents, subtree moves, promotion on deletion, nested sidebar labels, optional emoji, and idempotent geometry tracking |
| Peek and Little Arc-style small window | Later | Planned | P8c |
| Optional archive | Later | Planned | P8c; opt-in, searchable, recoverable |
| Boosts, easels, notes, theme store | Never | Excluded | No unrelated productivity platform |

## Navigation and page workflows

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| Address entry and configurable search | v1 + requested increment | Implemented; September 8 isolated checks pass | DuckDuckGo default; selectable built-ins, editable custom HTTP(S) search templates, local bangs and suggestions; no partial-query network requests |
| Back/forward/reload/stop | v1 | Implemented | P1; explicit commands, observed state never triggers duplicate navigation; stop replaces reload while loading |
| Load errors and certificate failures | v1 | Implemented | P1; visible failure, system trust validation |
| Cmd-click/middle-click/new-tab links | v1 | Implemented | P4 |
| Copy current URL | v1 | Implemented | P4; address-bar link button, site control and Navigate menu; Command-Shift-C default, explicit custom/cleared bindings preserved |
| Share current URL | v1 | Implemented | P4; native system sharing picker, explicit user destination, normal/private windows; no automatic send |
| Context-menu open/copy/save link/image | v1 | Implemented | P4; WebKit’s default macOS page menu covers Copy Link, Open Link, and Save/Download Image; `WKUIDelegate` context-menu hooks are iOS-only (`UIContextMenuConfiguration`). No custom replacement |
| Hover destination | v1 | Implemented | P4; bottom-leading status on the page for http(s) link URLs |
| Page identity and site control | v1 | Implemented | P4; trailing address control without capture glyphs, compact action tiles, remembered permissions, live capture mute/stop in the site popover and tab rows, connection footer; based on the supplied reference, without an extension strip |
| User-triggered popups/opener and unsolicited popup blocking | v1 | Implemented | P4; WebKit click-gesture `window.open`; site Ask/Allow/Deny; child keeps opener space/engine and is rejected after opener close begins |
| JavaScript alert/confirm/prompt | v1 | Implemented | P4; originating-window presentation and completion on closure |
| Before-unload/form-loss protection | Qualified | API-gated | P4; `WKWebView`/`WKUIDelegate` have no public before-unload or close-confirmation API (`requestClose()` stays true). Legacy `WebView` `runBeforeUnloadConfirmPanelWithMessage:` is not WKWebView. No JS injection |
| HTTP authentication | v1 | Implemented | P4; prompt without credential persistence |
| mailto/tel and external application handoff | v1 | Implemented | P1/P4; explicit user confirmation for clicks, form/JS navigations, and HTTP redirects, including post-login return-to-app schemes; no silent launches; policy-cancelled loads stay on the previous page |
| Upload/file picker | v1 | Implemented | P4; native authorized selection and multiple files where requested |
| Find next/previous | v1 | Implemented | P4; ⌘G / ⇧⌘G, window-local query, repeated focus and Escape, stale-result protection; WebKit match/no-match feedback only, no invented total |
| Zoom in/out/reset | v1 | Implemented | P4 |
| Print and system PDF viewing | v1 | Implemented | P4; `printOperation` for print; responses WebKit cannot show (`canShowMIMEType` false), including some PDFs, become downloads. Inline PDF is whatever the deployed WebKit renders |
| Content fullscreen and picture in picture | Qualified | API-gated | P4; public API and site/OS availability |
| Reload from Origin and per-site zoom | Qualified increment | Implemented | P8d; ⌥⌘R uses native revalidation and keeps unsafe-replay confirmation; WebKit zoom is exact-origin/engine/profile, private zoom stays page-local; reset preserves permissions |
| Per-site mobile browser identity | Qualified increment | Implemented; qualification pending | Site Rules saves Android phone/tablet and iPhone/iPad presets per exact origin/profile. WebKit changes HTTP/JavaScript user agent without resizing; Chromium ABI 16 supplies native user-agent/metadata overrides. Local navigation fixtures pass; real-site behavior needs manual qualification. |
| General local-file browsing | Requested increment | Implemented; qualification pending | P8d; explicit single-file panels, exact read access and security-scoped restoration for normal tabs; workspace interchange strips authorization and requires reselecting local files; private paths/bookmarks stay in memory only; file upload is separate |
| Visible-page screenshot | Qualified increment | Implemented | P8d; public WebKit viewport snapshot, explicit PNG Save panel, cancellation/errors and page identity guards; no full-page or video capture |
| Save page and source | Requested increment | Implemented; qualification pending | P8d; WebKit `.webarchive` saves the live page; “View Current Page DOM” shows script-mutated DOM, never claims original response source |
| Reader and translation | Never | Excluded | No built-in reader/translation subsystem |

## Browser data and privacy

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| WebKit cookies/cache/site storage | v1 | Implemented | `WKWebsiteDataStore` exclusively; no second HTTP cache |
| Preserve existing default-profile login data | v1 | Implemented | P2; explicit `legacyDefault` binding |
| Versioned session/backup/recovery | v1 | Implemented | P2; windows, tabs, organization, selection, sidebar, geometry |
| Bounded process-death recovery | v1 | Implemented | P2; safe reload or visible retry, no unsafe replay loop |
| Local history record/search/delete | v1 | Implemented | P5; History menu (recent library visits, recently closed tabs, clear-all confirm); separate history/bookmark views and removal, last-visit time-range clearing, profile-scoped retention (90 days by default; 7/30/90/365 days or until cleared); bookmarks preserved |
| Bookmarks and local omnibox completion | v1 | Implemented | P5; title/URL editing with history-preserving collision checks; schema 3 separates saved/history titles; Cmd-L offers local current-tab completion and keyboard selection; private queries do not read the normal library |
| Clear supported browser/site data | v1 | Implemented | P5; per-profile: Remove site = all `WKWebsiteDataStore` types for that registrable domain; Clear Cache = HTTP memory+disk cache only (cookies/storage kept); History time-range clearing is LibraryStore and preserves bookmarks; Forget permissions unloads pages. Private stores are not listed. WebKit does not offer a reliable per-category time wipe for cookies |
| Private windows | v1 | Implemented | P5; ephemeral store, no durable private browsing records; downloaded files remain |
| Bookmark import/export | v1 | Implemented | P5; user-provided files, imported/updated and skipped counts, transaction rollback and explicit errors; failed queries cannot export empty/partial output over the destination |
| Workspace export/import | v1 | Implemented | P5; versioned organization and recovery-safe import |
| Content blockers and site exceptions | v1 | Implemented | P5; `WKContentRuleList`, original limited three-host third-party baseline on first normal page, manual HTTPS native-JSON updates, no redirects, last-good rollback and per-profile exceptions |
| Profile data separation | Qualified increment | Implemented; isolation qualification pending | P8a; persistent named stores and profile-scoped organization/library/permissions/windows; complete observable isolation remains the gate |
| Safari/browser data import beyond supported exports | Qualified | API-gated | P5/P8; user-authorized supported access, no private-database scraping |
| System Apple Passwords / AutoFill | Qualified | Partial | WKWebView system AutoFill needs approved `com.apple.developer.web-browser` on a signed build (Account Holder form). Chromium helper path is in scope, not built; it needs the helper JSON list and/or the passkeys entitlement as parent. No JS fill or Cobble vault. See `docs/features/apple-browser.md` and `docs/features/passwords.md` |
| System passkeys / WebAuthn | Qualified / Later | Partial | `ApplePasskeys` requests `ASAuthorizationWebBrowserPublicKeyCredentialManager` when `com.apple.developer.web-browser.public-key-credential` is present. Unsigned builds skip the request. No JS polyfill. Chromium Views sheets are SDK (C22), not this entitlement. See `docs/features/apple-browser.md` and `docs/features/passwords.md` |
| Sign in with Apple (Touch ID sheet) | Qualified | Partial | WebKit uses system SIWA. Chromium authorize URLs load in a WKWebView sheet (`AppleSignInSession`) and return the site callback to the Chromium page. Not an Apple entitlement request. See `docs/features/passwords.md` |
| Cobble password vault and built-in save/fill | Never | Excluded | No Cobble vault; system Apple Passwords is the only password path |
| Payment-card autofill | Never | Excluded | No sensitive autofill subsystem |
| Telemetry, automatic remote diagnostics | Never | Excluded | Local redacted diagnostics only, explicitly exported by the user |

Private windows isolate browsing state, not every intentional user action. Files saved by a download remain, and shared saved-organization changes need explicit understandable behavior. Private mode is not anonymity or forensic erasure. Browser records and WebKit data have different deletion APIs; do not promise a broader wipe than verified.

## Downloads, permissions, and site capabilities

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| Downloads folder destination and independent download lifetime | v1 | Implemented | P4; tab closure does not cancel a transfer accidentally |
| Download progress/list/open/Reveal/cancel/failure | v1 | Implemented | P4; UTF-8-byte-bounded names/collisions; destination-volume staging supports external disks; quit warns, then cancels unfinished transfers; finished files stay |
| Native Save panel destination choice | v1 | Implemented | P4; defaults to Downloads and asks before replacement |
| Configurable default download folder | v1 | Implemented | Authorized folder bookmark seeds the native Save panel; unavailable folders fall back visibly to Downloads |
| Explicit retry of eligible failed downloads | v1 | Implemented | New transfer and destination choice for bodyless HTTP(S) GET requests, retaining the originating browsing context |
| Download pause/resume | Qualified | Implemented | One qualified pause/resume cycle for eligible bodyless HTTP(S) GET transfers; missing native resume data is an explicit failure. Resume retains the approved staging destination; the native fixture observed a Range continuation, but full-request fallback is not observable |
| Camera and microphone | Qualified v1 | Implemented | P4; anchored origin popover plus macOS TCC; capture indicators and mute/stop including private tabs; explicit Remember+Allow, request-only Not Now; site menus edit allow/deny/ask. Native grant/TCC qualification remains open |
| Remember/revoke supported site permissions | Qualified v1 | Implemented | P4/P5; exact origin/profile scope; a failed write is surfaced and does not unload live pages |
| Screen sharing and geolocation | Qualified | API-gated | Capability study and real workflow tests before a commitment |
| Web notifications | Qualified | API-gated | Do not equate Safari's notification support with a public embedded-browser API |
| Passkeys / WebAuthn | Qualified v1 | Partial | P7/P8e; `ApplePasskeys` requests access when `com.apple.developer.web-browser.public-key-credential` is present. Settings states this unsigned build cannot use them; no JS polyfill or Cobble vault. Chromium sheets are C22. See `docs/features/apple-browser.md` |
| Protected streaming / DRM / codecs | Qualified | API-gated | Test actual services and OS support; no universal playback promise |
| `WKWebExtension` | Qualified | Implemented | Copied resource folders, ZIP archives, and app-extension bundles; per-profile site grants, optional API permission consent/revocation, optional private access, and native action popups. Fixtures verify injection, revocation, popup content, ZIP reload, permission persistence, and explicit private opt-in. Native messaging and old Safari App Extensions unsupported; third-party compatibility requires individual checks |
| WebUSB/HID/Serial/Bluetooth/filesystem/GPU web APIs | Qualified engine capability only | API-gated | Whatever the shipping WebKit publicly supports; no fabricated bridge or parity claim |
| Native Chromium extensions | Qualified, requested | Experimental SDK and adapter implementation | ABI16 registry fixture passes 10/10, including themes blocked. Shared extension contract/UI with WebKit; native managers remain separate. Explicit unpacked installation and site grants; Store SDK consent/registry hooks exist but the Store entry stays hidden pending live consent, restart and updater qualification. Action popups and private access remain unsupported. General extension native messaging stays unsupported; the Apple Passwords system helper is a separate product path (`docs/features/passwords.md`) |
| Chrome-extension API emulation on WebKit | Never | Excluded | WebKit WebExtensions use Apple's public APIs; no broad Chrome API emulation promise |
| FTP, RSS, Cast | Never | Excluded | Outside current browser direction |

For every qualified capability, record the tested OS/SDK/API, requesting site/fixture, expected behavior, actual result, required entitlement, and supported fallback. A capability may remain unsupported; its UI and release notes must say so instead of silently implying support. macOS user permission and website permission are separate decisions.

## Reliability and distribution

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| Atomic serial saves, backup, corrupt/newer-data preservation | v1 | Implemented | P2; quit cancellation on final-save failure, profile-deletion rollback before cleanup, private-window backup stability, visible failures and migration tests |
| Retain live page state on ordinary tab switches | v1 | Implemented | P1; does not promise page memory after discard/process death |
| Lazy restored tabs and measured resource use | v1 | Partial | P2/P6; test 1/20/100 tabs, live and unloaded separately |
| Manual tab discard | v1 | Implemented | P6; visible state-loss boundary and explicit reload |
| Automatic memory discard | Later | Planned | Only if safe conditions and measured need can be established |
| Keyboard, VoiceOver, IME, contrast/reduced motion | v1 | Partial | P3/P6; native UI accessibility is a release requirement |
| Seven consecutive personal daily-use days | v1 | Planned | P6; measured budgets and no data-loss/isolation defects |
| Clean install, upgrade, signed update, rollback | v1 | Planned | P7; oldest supported and latest stable macOS |
| Local redacted diagnostics and retained symbols | v1 | Implemented | P6/P7; Settings General Save panel; no automatic upload |
| Exact unsaved forms/DOM/history recovery after death | Not promised | Not promised | Website and engine memory cannot be reconstructed from URL snapshots |

## Engine direction

| Capability | Scope | Implementation | Stage / acceptance |
| --- | --- | --- | --- |
| System `WKWebView` default | v1 and ongoing | Implemented | No WebKit fork or custom renderer |
| Native Chromium SDK | Requested, in development | Separate repository | P9a; pinned full Chrome source, opaque native ABI and launcher/client harness; full runtime and isolated Cobble smoke passed; production sandbox/storage, resource/security and release gates remain open |
| Engine routing / exact-host rules | Foundation and settings | Implemented | Default, exact-host routing and tab overrides; one reload confirmation per open-tab switch; P9b gates another adapter |
| Automatic engine detection or silent fallback | Never | Excluded | Failure and redirects do not silently switch engines |
| User-selected default engine | Requested | Settings implemented for registered engines | WebKit is the shipping default; alternatives require P9 gates |
| Experimental cross-engine login sharing | Qualified | Implemented; isolated cookie checks pass | Default-off switch-time sharing of supported HTTPS site cookies in one normal profile; requires ABI 14 Full. Real-site compatibility remains unqualified. See `docs/features/login-sharing.md` |
| Credential/unsaved-state migration between engines | Never | Excluded | No password, passkey, JavaScript-memory or form-state transfer |
| Engine-neutral contracts | Requested foundation | Implemented | Engine/context/page, transfer and service contracts; verified WebKit and experimental Chromium adapter; fake-engine regression checks |

New Tab is a command-bar action, not a closable placeholder. An empty window/space or an unloaded selection displays an empty page surface. A tab record is created when a destination is submitted; site-created popup pages retain their originating engine and context.
