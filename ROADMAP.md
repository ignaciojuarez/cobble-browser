# Roadmap

Cobble is a macOS 26+ browser with WebKit and an optional Chromium runtime.
**Source publication is separate from release qualification.** No daily-use or
public-v1 gate is complete. Implemented capabilities live in [FEATURES.md](FEATURES.md);
engine build details live in [CHROMIUM.md](CHROMIUM.md).

## Acceptance gates

Unchecked items require evidence even when their implementation already exists.
Do not infer native interaction, hardware, signing, or seven-day use from a build.

| Gate | Required evidence |
| --- | --- |
| P0 — Baseline | Reproducible builds/tests, capability inventory, representative manual website review |
| P1 — Windows and navigation | Independent multiwindow state, native commands/focus, popup ownership, navigation and page lifecycle |
| P2 — Recovery | Migration/corruption/write-failure checks, interrupted-process restoration, private-record exclusion |
| P3 — Organization | Keyboard/pointer editing and undo, restart persistence, native gestures, accessibility |
| P4 — Browsing | Sign-in, forms, uploads/downloads, PDF/print, permissions and default-browser workflows |
| P5 — Data and privacy | Profile/private isolation, import/export, actual deletion scopes, blocker/grant enforcement |
| P6 — Daily use | Measured resource budgets, accessibility/IME, seven consecutive days without data-loss/isolation defects |
| P7 — Distribution | Developer ID signing, notarization/stapling, clean install, upgrade, signed updates and rollback |
| P8 — Advanced features | Individual ownership, isolation, persistence and native interaction checks |
| P9 — Chromium | Matched SDK/runtime, security maintenance, native capabilities and complete distribution qualification |

## Core browser qualification — P0–P5

- [ ] Finish representative manual workflows on the oldest supported and latest stable macOS; automated regressions use isolated local fixtures.
- [ ] Verify independent windows, focused commands, address drafts, rapid tab switching/closing, native focus and external URL routing. A live page must have exactly one owner.
- [ ] Verify URL resolution, redirects, same-document history, TLS errors, popup/opener relationships, dialogs and cancellation. Reject stale callbacks and unsafe automatic request replay.
- [ ] Exercise corrupt/newer records, backup recovery, migration, failed writes and interrupted termination. Preserve existing `legacyDefault` WebKit logins; restore URLs/organization, not unsaved DOM or forms.
- [ ] Verify saved/home versus live URLs, nested folder movement/cycle/deletion rules, multiwindow organization undo, keyboard alternatives, physical sidebar gestures and restart behavior.
- [ ] Qualify uploads, download destinations/collisions, tab-independent transfers, quit/cancel, eligible resume/retry, PDF/print and filesystem failures. Never turn unsupported request replay into GET.
- [ ] Qualify HTTP/proxy/client-certificate authentication, external-app confirmation and default-browser registration using signed builds. See [authentication](docs/features/passwords.md).
- [ ] Verify private tabs/history/recently-closed state never enter durable snapshots, backups, diagnostics or sync. Downloads and intentional organization edits have separate persistence semantics.
- [ ] Verify profile isolation/deletion, history/bookmark semantics, import/export rollback, blockers and permission revocation against live stores. Data-deletion UI must match each engine’s actual scope.

### W17 — Media permission UI

Owned media prompts and capture indicators are implemented. Native camera/mic
success, TCC denial/retry, cross-origin frames, background tabs, revocation and
navigation/close cancellation still need hardware qualification.

### W18 — WebKit audio mute

Native output mute keeps playback running. Its runtime-checked private bridge
refuses changed mute values after capture use for that page’s lifetime, including
unmute; a fresh tab may be required. Speaker-level listening and capture-safe
native mutation remain open. Do not replace output mute with playback suspension.
Chromium uses its native output-mute operation (C11).

## Reliability and distribution — P6/P7

- [ ] Measure startup, foreground readiness, tab switching, memory, CPU and background processes for 1/20/100 tabs; distinguish live pages from unloaded restoration records. Record hardware, OS, configuration and sampling method before setting budgets.
- [ ] Qualify sleep/wake, display/network changes, offline recovery, low memory, large sessions and repeated lifecycle transitions.
- [ ] Complete keyboard-only, VoiceOver, contrast, reduced motion, text-size and IME checks in browser chrome and embedded pages.
- [ ] Complete seven consecutive daily-use days; restart the gate after fixing a data-loss or isolation defect.
- [ ] Produce Developer ID-signed, notarized and stapled app artifacts with stable identity, complete helper/framework signing, licenses/notices and retained symbols.
- [ ] Verify fresh download, quarantine/Gatekeeper, relocation, default-browser choice and external links on a clean Mac.
- [ ] Verify upgrade, login continuity, migration, interrupted update and rollback without overwriting newer-schema records. Use manual beta replacement initially; qualify a signed update mechanism before public v1.
- [ ] Verify every advertised architecture and supported OS. Development/ad-hoc signing and cross-compilation do not qualify distribution.

## Advanced capabilities — P8

- [ ] **P8a profiles:** native create/rename/delete workflows, active downloads, restart, separate accounts/storage/permissions and default-profile continuity.
- [ ] **P8b windows:** live detachment with correct focus, prompt/download ownership and extension identity. Window merging and two-pane split remain deferred.
- [ ] **P8c lightweight surfaces:** peek, small external-link windows and opt-in archival remain deferred; specify ownership and recovery before implementation.
- [ ] **P8d page tools:** qualify authorized local-file access, visible screenshots, engine-appropriate archives, current-DOM export, zoom and inspector lifecycle. Existing fixtures do not prove native Save-panel or filesystem-failure behavior.
- [ ] **P8e ecosystem:** obtain Apple browser/password/passkey approvals and qualify the actual signed build. Verify extension grants/revocation, private opt-in, action UI, keyboard focus and supported API behavior. See [Apple browser requirements](docs/features/apple-browser.md).

Deferred organization work also includes multiple-tab URL copying, URL QR codes,
guided import and tab hover previews. Top-toolbar auto-hide is outside the chosen
sidebar design. Deferred items are not public-v1 promises.

## Chromium integration — P9

Current source targets ABI 16. Historical ABI 3–15 checks do not establish current
runtime qualification. The SDK owns native implementation; Cobble owns shared
contracts and UI. Keep request handles and rendering types inside adapters.

| IDs | Current boundary and remaining qualification |
| --- | --- |
| C01–C03, C28 | Match source, ABI, exports and packaged runtime; verify startup, child sandbox enforcement, profile paths, teardown and reproducible upgrades. Keep build outputs outside source control. |
| C04, C14, C29, C31 | Native typing, IME, VoiceOver, clipboard, drag/drop, display/sleep and focus; qualify live movement, visibility, find feedback and remembered zoom. |
| C05, C09, C30 | Media and popup bridges exist; qualify hardware/TCC, grant/revoke, origin/frame identity, stale prompts, exactly-once cancellation and safe window movement. |
| C06, C07, C15 | Screen/system-audio capture, geolocation/notifications/device prompts, content fullscreen and pointer/keyboard lock lack qualified host integration. Keep unsupported paths unavailable or safely rejected. |
| C08, C35 | Native connection/certificate details and repost ownership exist. Complete mixed-content/TLS/error recovery and shared-renderer crash/replacement checks; URL text alone is not security evidence. |
| C10, C18, C19 | Native blocking, profile cleanup and data controls have fixtures. Verify live mutation failure, private isolation, category/domain/cache scopes, extension-storage exclusions and time-range limits. |
| C11–C13, C16, C33 | Native mute, print, screenshot, metadata, DOM/MHTML, local-file and DevTools paths need current-package native/document qualification. Do not label MHTML as a WebKit archive. |
| C17 | Qualify download danger/quarantine, unknown length, eligible GET resume/retry, POST non-replay, disk failure, profile lifetime and close/quit ownership. |
| C20, C24 | Verify shared history, routing, exact-host rules, external links, restoration and Fast/Full transitions. Preserve saved engine choices and separate live state; qualify optional cookie sharing independently. |
| C21 | Extensions are experimental. Store consent, restart/updater, action popups, private access, optional permissions and extension-created tab/window adoption remain separate gates. |
| C22, C34 | Qualify native dialogs, uploads, before-unload, HTTP/proxy/client-certificate auth, SIWA, WebAuthn and Apple helper paths. Authentication details live in the feature checklist. |
| C23, C36 | Inventory packaged codecs/DRM/WebRTC/WebGPU, system proxy/PAC/DNS, certificate policy, Safe Browsing and component services. No universal Chrome compatibility claim. |
| C25, C26 | Inventory ordinary-launch traffic and measure WebKit-only, mixed and Chromium-default costs, including zero tabs. Targeted service suppression is not proof of no background networking. |
| C27, C37 | Qualify the exact signed Full artifact, native regression matrix, resources/architectures, notices, updates and rollback. Assign and exercise routine/emergency Chromium security-update ownership. |

P9a requires demonstrated compatibility benefit, sustainable engine maintenance,
and acceptable native/resource/distribution behavior. P9b requires predictable
routing, isolation/recovery and everyday second-engine use without regressing
WebKit. Neither replaces P6/P7.

## Optional iCloud sync

- [ ] Verify signed builds, CloudKit container/schema, first upload and two-device convergence with offline edits/deletions.
- [ ] Verify each category’s enable/disable/re-enable behavior; disabling sync must not erase cloud or other-device data.
- [ ] Verify blocker preferences, unavailable-engine fallback, tab close confirmation and retained local rules.
- [ ] Verify account changes, errors, private-data exclusion and local recovery after cloud failure.

See [sync](docs/features/sync.md). Local builds cannot qualify two-device behavior.

## Evidence

Existing local development evidence includes hosted regression tests, ABI 16
adapter checks and isolated native fixtures. [CHROMIUM.md](CHROMIUM.md) records
runtime evidence and its limits; [RESEARCH.md](RESEARCH.md) records unresolved
platform questions. Evidence is specific to the tested source/runtime/configuration;
this cleanup does not mark any acceptance gate complete.
