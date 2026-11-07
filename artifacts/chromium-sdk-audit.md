# Chromium SDK super audit — 2026-11-06

## 1. Scope and state

- **SDK:** `ignaciojuarez/chrome-sdk` at Cobble's pin `f0a128e` (ABI 19, Chromium 153.0.8010.37). `origin/main` (`ef35f30`) differs only by a CI timeout bump.
- **App:** Cobble worktree `t3/1a8cb08b`, base `60d9baa`, clean at start. Covered `Engine/Chromium/*`, `Engine/Contracts/*`, the Chromium paths in `App/` and `Browser/`, `Package.swift`/`.resolved`, `Scripts/assemble_chromium.py`, `run.sh`/`hook_full.sh`, the Full path in `release.py`, CI, and the docs.
- **SDK sources covered:**
  - Swift API, C loader, ABI header and native overlay (`cobble_*.mm`).
  - The 36 patches, build/update/repair scripts, 4 workflows, the harness and smoke tests, AUDIT/README.
  - Upstream 153 source, read-only from the local build cache, to trace upstream behaviour.
- **Method:** 4 read-only specialists (architecture + dependencies + packaging, native bridge + security, Swift SDK + adapter, features + tests). The coordinator re-read every fixed path and spot-checked the P1 claims (the crash path upstream, the live Chrome version feed, disk space). Every remedy went through Ponytail.
- **Fix locations:**
  - Cobble: this worktree's branch and its PR.
  - SDK: branch `update/chromium-157`, [chrome-sdk#19](https://github.com/ignaciojuarez/chrome-sdk/pull/19).
- **Not covered:**
  - Nothing was run against a live runtime: no Full launch, harness run, packet capture or real sites.
  - Native findings are traced from source, not reproduced.
  - Partly read: `cobble_extensions.mm` and `cobble_website_data.mm` (first halves), the DNR internals of patch 0022, and `prepare_update.py`.
- **Native fixes:** every SDK native fix needs a multi-hour Chromium rebuild, a matched runtime, and a re-pin.
- **User decisions (2026-11-06):** update Chromium, and fix clear native bugs without asking.
- **Update outcome (2026-11-06):** SDK PR [ignaciojuarez/chrome-sdk#19](https://github.com/ignaciojuarez/chrome-sdk/pull/19) at `93c1dad`; Cobble pins that revision. The packaged 157 runtime passed the isolated harness 251/251. The harness also caught four 157 regressions, now fixed: find request IDs start at zero, unpacked extensions lost install-time host withholding, my first `getDisplayMedia` activation check was stricter than Chrome, and site-specific HISTORY removal crashed. Full assembly could not be signed from this session (no Xcode account), so a Full launch is pending.

## 2. Ranked findings

P0 severe · P1 real failure · P2 bounded bug / meaningful cost · P3 minor. Confidence is an evidence judgement, not a probability.

| P | Finding | Recommendation | Confidence | Risk | Status |
| --- | --- | --- | --- | --- | --- |
| P1 | Chromium pinned at 153; Mac Stable is 156/157. 153 gets no more security fixes, and public betas ship it | Rebase to 157.0.8103.x with matching depot_tools; rebuild, run the harness, re-pin Cobble, ship a beta | High — live feeds | High | ✅ Fixed — 157.0.8103.39; harness 251/251; Full launch pending |
| P1 | Closing the last Chromium window (a private window) during any download crashes the browser | Post the download-close callback asynchronously with `true` (Cobble owns download lifetime); add a harness check | High — traced to a `CHECK`; not reproduced | Low (native) | ✅ Fixed (native) — not reproducible in harness; manual Full check pending |
| P1 | Cobble shortcuts beat web apps in Chromium tabs (⌘S, ⌘D, ⌘F…); ⌘H/⌘M do nothing while a page has focus | SDK sends unhandled keys back to the host menu (like the fullscreen window); Cobble pre-empts only Chrome's reserved shortcuts | Med-High — traced; not run | Med | ⚖️ Needs decision |
| P1 | Tab discarding (memory pressure or an extension's `chrome.tabs.discard`) can silently close Cobble tabs | Confirm with a CDP memory-pressure smoke check; then `SetAutoDiscardable(false)` for SDK pages and refuse extension discards | Medium — upstream path; not reproduced | Low (native) | ✅ Fixed (patch 0037) — not exercised by harness |
| P1 | Safe Browsing is likely inactive (no Google API key); dangerous downloads hard-fail with no override | Decide on a key/proxy; until then say "no Safe Browsing in Chromium tabs" in FEATURES and mark AUDIT D09 Missing | Medium — key absent; runtime effect unobserved | Med | ⚖️ Needs decision |
| P1 | With history "disabled", normal profiles still save visited URLs (favicons with full URLs, predictor, NEL), and SDK removal can't clear them | Stop favicon persistence and the predictor under the SDK; add HISTORY to all-time profile removal and Cobble's history clear | High (favicons) / Med (predictor) | Med (native) | ✅ Fixed (patches 0038/0039 + all-site HISTORY removal); harness empty-History check passes |
| P1 | A WebAuthn/passkey request may abort the whole app: the Views authenticator sheet has no host and no guard exists | Add a guard like the FedCM one (patch 0030) that fails the request cleanly; check with a CDP virtual authenticator | Medium — documented Debug abort | Low (native) | ✅ Fixed (patch 0036) — not exercised by harness |
| P2 | Every auto-denied permission prompt is saved as a permanent Chromium BLOCK; a site's second automatic download is blocked forever | Resolve Cobble-page requests `Cancelled()` in `RoutePermissionRequest` so nothing persists; clear existing BLOCKs once | High — traced | Low (native) | ✅ Fixed — smoke asserts a refused prompt stays "prompt" |
| P2 | Chromium private windows aren't Incognito-typed: third-party cookies allowed, HTTPS-First off, ambient Negotiate auth on | Override cookie controls, HTTPS-First and ambient auth for `Cobble::PrivateWindow` profiles (lower risk than retyping them as Incognito) | High — traced | Med (native) | ⚖️ Needs decision |
| P2 | Any subframe navigation or frame deletion cancels every pending prompt on the page | Cancel page-wide only for the primary main frame; otherwise cancel only that frame's requests | High — traced | Low (native) | ✅ Fixed — harness frame-removal checks pass |
| P2 | `getDisplayMedia` skips Chromium's Permissions-Policy, user-activation and background checks | Add `IsFeatureEnabled(kDisplayCapture)`, `HasTransientUserActivation()` and a visibility check to the display branch | High — traced | Low (native) | ✅ Fixed — Chrome's own activation rule; harness display checks pass |
| P2 | Profile deletion fails when Settings or sync opened that profile's Chromium context | Close the manager-held context before scheduling deletion | High — traced to the native BUSY refusal | Low | ✅ Fixed — manual Full check pending |
| P2 | An unreadable Chromium rules file blocks every Chromium page, and the message points to a disabled setting | Keep browsing with the installed rules and disable only changes (WebKit parity) | Med-High — traced | Low | ✅ Fixed |
| P2 | Denying camera/mic force-unloads unrelated Chromium tabs that hold a stale grant; stop-all also ends screen shares | SDK: stop-capture also revokes not-yet-opened grants and reports success when nothing is live; then per-kind stop | Medium — needs a no-device/TCC-denied state | Low-Med | ⚖️ Needs decision |
| P2 | A leave-page request on a non-http(s) page (e.g. a `window.open('')` popup) resolves as Stay, so the tab can't close and ⌘Q is always refused | Reproduce with an about:blank popup fixture; if confirmed, show a generic leave prompt labelled with the tab title | Medium — traced; trigger page not run | Med | 🔎 Investigate |
| P2 | Chromium private windows get no content blocking; WebKit private windows do | Allow the rules extension in private profiles (SDK); until then show a notice in Chromium private windows | High | Med (SDK) | ⚖️ Needs decision |
| P2 | Chromium autocomplete (form history) is on and Cobble can't show or clear it | Turn off autofill and the password-manager service by profile pref at SDK profile init | High (defaults) / Med (saving) | Low (native) | ⚖️ Needs decision |
| P2 | Right-click "Search Google for…" / "Search image with Google" ignore the user's search engine | Hide those three context-menu commands now; add a host search template later | Medium | Low (native) | ⚖️ Needs decision |
| P2 | Extension keyboard `commands` can never fire (no Views shortcut registry) | Say so in the extension UI; build an SDK-owned registry when extensions are prioritised | High — upstream | Med | 📝 Documented (AUDIT E09) · Deferred |
| P2 | `symbol_level=0`: Chromium crashes, which take down the whole app, can't be symbolicated; the release gate needs retained symbols | Build with `symbol_level=1` + `enable_dsyms=true`; keep dSYMs outside Git with each runtime | High | Low | ⚖️ Needs decision (artifact size) |
| P2 | `update.py` proposes Early Stable (0.5%) builds and flips milestones; 7 draft bot PRs are open | Pick the highest version VersionHistory serves at ≥20%; close superseded bot PRs | High — live feed + PRs | Low | ⚖️ Needs decision |
| P2 | SIGTERM/SIGHUP during `build.py compile` leaves autoninja running and releases the build lock | Treat termination as an interrupt; kill the compiler's process group before exiting | High | Low | ✅ Fixed (SDK PR #19) |
| P2 | The 3 "known" harness failures (PiP, document PiP, display-media containment) probably come from the harness capturing windows before fullscreen | Capture the window list after fullscreen exit, log all outcomes, and add an AUDIT row; expect 245/245 | Medium | Low | ✅ Fixed — confirmed harness artifacts; 251/251 |
| P2 | Test gaps: adapter tests are mostly constants; no CI runs Chromium behaviour; high-value edge cases are untested | Extract the adapter's pure logic into tested statics; require a smoke receipt with every SDK pin bump | High | Low | Deferred |
| P2 | Daily-driver feature gaps (see §3): notifications, geolocation, PiP, pointer lock, 3P-cookie blocking, extension popup/side panel, Apple Passwords | Prioritise in ROADMAP; next: notifications + geolocation through Cobble's existing permission prompts | High | — | Deferred (roadmap) |
| P3 | JS dialog / HTTP auth / file chooser stay pending when the SDK refuses the answer (NUL bytes, bad selection) | Cancel when the SDK refuses, as the client-certificate path already does | High | Low | ✅ Fixed |
| P3 | A Chromium tab fails to load with an unrelated content-blocker change's error | Ignore the earlier change's error; rely on the rule state | High | Low | ✅ Fixed |
| P3 | Exception cap mismatch: Cobble allows 1000, the SDK allows 512, with a misleading error | Cap at 512 with an accurate message; consider raising the SDK cap toward Chromium's 1000-regex limit | High | Low | ✅ Fixed |
| P3 | Full aborts with a crash report after the "Quit any other Cobble" alert, and crashes silently on a runtime/ABI mismatch | Exit after the alert; show an alert for runtime failures | High — launcher calls `abort()` | Low | ✅ Fixed — manual Full check pending |
| P3 | Docs drift: stale interrupted-GET "open issue"; ROADMAP says ABI 18; AUDIT B20/D09/E09/P05/P19 stale or misclassified; identity smoke undocumented | Correct the text | High | Low | ✅ Fixed |
| P3 | `PageEvents.onKeyEvent` is wired but no engine ever fires it | Delete it; re-add with the keyboard-routing fix if needed | High — grep | Low | ✅ Fixed (removed) |
| P3 | Cobble's adapter `swift test` CI step is skipped whenever the hosted tests fail | Run it unless the job is cancelled | High — 6 skipped runs | Low | ✅ Fixed |
| P3 | Opening Website Data creates a Chromium profile without recording use, so deletion leaves it behind | Don't open a Chromium context for listing when the profile has never used Chromium | High (mechanism) | Low | ⚖️ Needs decision |
| P3 | Sleeping a Chromium tab loses its back/forward list (no SDK restore API) | Add an SDK navigation-history restore API at the next ABI bump | High | Med (SDK) | Deferred |
| P3 | Load progress and "unresponsive" state are tracked but never shown | Show a progress bar and an unresponsive banner with Wait/Stop, or delete the state | High | Low | ⚖️ Needs decision |
| P3 | The page ABI accepts privileged schemes (`chrome://extensions`, `javascript:`); only Cobble's address bar filters them | Allow only http, https and about:blank in `CCSPageCreate`/`CCSPageLoadURL` | High (SDK side) | Low (native) | ✅ Fixed (native) |
| P3 | Extension-created tabs/windows and unowned DevTools escape Cobble ownership | Adopt extension-created tabs like popups; refuse unowned DevTools frontends | High | Low-Med | Deferred |
| P3 | Closing a page from inside a bridge callback deletes `WebContents` mid-notify (`CHECK`) | Defer close/force-close with a posted task when called re-entrantly | Medium — host doesn't do this today | Low | Deferred — not changed in this update |
| P3 | JS-dialog cleanup after retire is fragile; `CCSPageRelease` on an open page can leak via before-unload | Match JS requests by `WebContents`; make release force-close | Medium | Low (native) | ✅ Fixed (native) |
| P3 | A media request can stay pending when resolve fails natively | Finish a non-live request as failed | Medium | Low (native) | ✅ Fixed (native) |
| P3 | Private MHTML temp files survive a crash; early-return cleanup does blocking IO on the UI thread | Write private MHTML in memory or a crash-cleaned directory; delete on a blocking-IO task | High | Low (native) | Deferred |
| P3 | Patch health: 0002 uses a test switch as policy; 0027 loosens content invariants ungated; 0020 is obsolete; heavy overlap | During the 157 rebase, drop 0020 and gate 0027 on Cobble pages; replace the test switch via the permissions fix | High | Med | Reviewed — 0020 is still used by a smoke option and 0027 is Mac-embedder-only; kept |
| P3 | `local full` "active build" guard reads a stale phase file, not `build.py`'s lock | Take a non-blocking flock on `.cobble-build.lock` while assembling | Medium | Low | 🔎 Investigate |
| P3 | Provenance: the SDK runtime release isn't immutable; `release.py --chromium` takes any app; `package()` allows a dirty tree | Enable immutable releases; verify the runtime zip SHA-256 in `release.py`; refuse a dirty tree in `package()` | Medium | Low | ⚖️ Needs decision |
| P3 | `chromium-build.yml` trusts a checkpoint artifact from any run ID | Require the run's workflow path, `workflow_dispatch` event and same repository before download | Medium — workflow has 0 runs | Low | Deferred |
| P3 | SDK `chromium-build.yml` pins node20-era actions (upload-artifact v4, setup-node v4) | Bump to the current v7 SHAs when the workflow is next used | High | Low | Deferred |
| P3 | Six ABI exports are required at load but never called | Delete them at the next ABI bump | High | Med (ABI) | Deferred to next ABI bump |
| P3 | Adapter duplication: callback install/teardown ×3, six native-ID maps, duplicate trim helpers, raw `data.write`, engine reaching into `BrowserWindowController` | One install/detach function, one generic native-ID helper, `PersistenceFile` everywhere | High | Low-Med | Deferred |
| P3 | Fixed-time "nothing happened" waits in harness/smoke can pass falsely | Pair each wait with a positive barrier (hit counter or a later commit) | High (pattern) | Low | Deferred |
| P3 | `runtimes/` keeps 13 packaged runtimes (SDK AGENTS.md: one rollback) | Keep the current and one rollback runtime; delete the rest after the 157 runtime qualifies | High | Low | Deferred (ops) |

## 3. Missing features vs a Chromium daily driver

Never-list items (AI chrome, telemetry, Cobble vault, sync, native messaging, translate/reader) are excluded.

| Area | Status | Impact | P | Recommendation |
| --- | --- | --- | --- | --- |
| Security updates | Updated to 157 (SDK PR #19) | Keep pace with each Stable milestone | P1 | Set a security-patch owner and deadline (AUDIT B21) |
| Keyboard routing | Unhandled ⌘ keys dropped | Web editors lose ⌘S/⌘Z/…; ⌘H/⌘M dead | P1 | SDK key redispatch to the host menu |
| Safe Browsing | Likely inactive | No phishing/malware warnings in Chromium tabs | P1 | Key/proxy, or document the gap |
| WebAuthn / passkeys | No host; may abort | Passkey sign-in fails or crashes | P1 | Crash guard now; host the dialog later |
| Notifications / Web Push | Denied, and the denial is saved | No Slack/Gmail/Calendar alerts | P2 | Route through Cobble's prompt, then UNUserNotification delivery |
| Geolocation | Denied, and the denial is saved | Maps and store finders | P2 | Route through Cobble's prompt + CoreLocation usage string |
| Picture-in-picture / document PiP | Refused (0015) | No video PiP; Meet/Teams floating window | P2 | Host video PiP in an owned NSPanel first |
| Pointer / keyboard lock | Denied | Figma scrubbing, games, remote desktop | P2 | Allow pointer lock with an origin banner (like fullscreen) |
| Screen sharing | Window/screen video only | No tab capture, no tab/system audio | P2 | Add tab capture after real-site qualification |
| Third-party cookie blocking | Absent (Chrome default) | Weaker than WebKit ITP | P2 | Default-block 3P cookies in private windows; offer a setting for normal ones |
| Private-window protections | Not Incognito-typed; no blocking | Weaker private mode | P2 | See the private-window rows in §2 |
| Extension action popup / side panel | Absent (E05/E06) | Most extensions' main UI | P2 | Host the action popup in an owned popover first |
| Extension shortcuts | Can't fire | Password/tab-manager shortcuts | P2 | SDK-owned registry (after key redispatch) |
| Chrome Web Store install | Hooks exist; entry hidden (E07) | Install friction | P2 | Qualify consent/update/restart, then unhide |
| Apple Passwords helper | Absent (entitlement-gated) | No system password fill | P2 | Wait on Apple's allow-list (passwords.md) |
| Network PDF view/print/save | Untested; local PDFs rejected | Unknown | P2 | Add a harness check for network PDFs |
| Crash symbols | `symbol_level=0` | Crashes unreadable | P2 | Retain dSYMs per runtime |
| VoiceOver in pages, IME, Services | Qualify | Accessibility | P2 | Manual VoiceOver/IME pass on the 157 runtime |
| Clipboard read, MIDI, idle, fonts, storage access, protocol handlers | Denied | Niche | P3 | Keep denied (without persisting) until the general permission bridge |
| USB/HID/Serial/Bluetooth | Blocked on purpose | Hardware web apps | — | Keep blocked until a chooser exists |
| Widevine/DRM | Absent (licensing) | Netflix/Spotify web | P3 | Route DRM sites to WebKit |
| Live captions, EyeDropper, Web Speech | Absent | Niche | P3 | Skip for now |
| Find whole-word, print-to-PDF API | Absent | Minor | P3 | Skip for now |
| Secure DNS / proxy UI | Chromium defaults only | Minor | P3 | Rely on system settings |
| Handoff | Absent in both engines (Cobble-level) | Minor | P3 | Remove the Info.plist declaration or implement it |

## 4. Per-finding evidence (key items)

### Chromium pin is stale — P1 · ✅ Fixed
- **Pin:** `chromium.lock.json` has 153.0.8010.37, `verified_at` 2026-09-12.
- **Live data (2026-11-06):**
  - VersionHistory serves 156.0.8078.80 (49.5%), 156.0.8078.81 (24.75%) and 157.0.8103.38 (24.75%).
  - 157.0.8103.39 was published 2026-11-03.
  - 158.0.8127.18 is Early Stable at 0.5%.
- **Secondary sources:** 154 shipped 108 fixes (11 Critical) and 157 shipped 213 fixes (7 Critical). Counts for 155 and 156 conflict and are unverified. No in-the-wild exploit was found that affects 153.0.8010.37. If one appears, this becomes P0.
- **Recommendation:**
  - Target 157, the current milestone, since 156 gets only a few more weeks of fixes.
  - Bump `depot_tools_revision` too.
  - Rebase the 36 patches, rebuild, package, run the harness, re-pin Cobble and ship a beta.
- **Checked and rejected:** a specialist reported a disk-space blocker. The build volume has ample free space, so there is none.

### Private-window close during a download crashes — P1 · ✅ Fixed
- `cobble_browser_window.mm:728-733` calls `ConfirmBrowserCloseWithPendingDownloads` → `std::move(callback).Run(false)` synchronously.
- `unload_controller.cc`: `CanCloseWithInProgressDownloads` returns early only for non-OTR profiles. For the last Browser with `BlockingShutdownCountAllProfiles() > 0` it returns `kBrowserShutdown`.
- The synchronous `Run(false)` reaches `InProgressDownloadResponse`. That calls `chrome::ShowDownloads(browser_)`, then runs `warn_before_closing_callback_` before `MaybeWarnBeforeClosing` has assigned it, which hits `CHECK(!is_null())`.
- Trigger: the only Chromium Browser is a Cobble private window, and any download in any profile is running. Close that window.
- **Recommendation:** post the callback asynchronously with `true`; Cobble owns download lifetime via its OTR lease. Add a `privateWindowCloseWithActiveDownload` harness check.

### Keyboard routing — P1 · Needs decision
- `cobble_browser_window.mm:738-745` `HandleKeyboardEvent` returns false. Only the fullscreen window redispatches; upstream redispatch needs a Views window.
- Cobble pre-runs bound menu commands (`CobbleApp.swift:288-293, 761-818`).
- **Recommendation:** the SDK sends unhandled key events back to the host window's main menu, as the fullscreen window already does. Cobble then pre-empts only Chrome's reserved set: new/close tab or window, reopen, quit and tab switching.
- **Check:** a fixture page cancels ⌘S/⌘Z and the sidebar must not toggle; ⌘M minimizes while the page has focus.

### Tab discard — P1 · Investigate
- Upstream `tab_lifecycle_unit.cc:270-321` replaces the `WebContents`. In-place discard is off on Mac, and extension discards are always eligible.
- The SDK retires the page on destroy (`cobble_chromium.mm:1568-1588`), and Cobble closes the tab (`BrowserWindowModel.swift:439-446`).
- **Recommendation:** add a smoke check with CDP `Memory.simulatePressureNotification("critical")` plus a fixture extension calling `tabs.discard`. If confirmed, `SetAutoDiscardable(false)` in WrapPage and refuse extension discards.

### Safe Browsing — P1 · Needs decision
- `build.py:321-331` sets no `google_api_key`. Safe Browsing V4/V5 updates require one.
- WebKit tabs do get Apple's fraudulent-site warning.
- **Recommendation:**
  - Short term: state "no Safe Browsing in Chromium tabs" in FEATURES and mark AUDIT D09 Missing.
  - Long term: decide whether to supply a key or proxy.

### History-disabled leaks — P1 · ✅ Fixed
- Favicons: `favicon_handler.cc:276-277` writes page→icon mappings with full URLs for non-OTR profiles.
- Predictor: `loading_predictor_config.cc:15-18` enables it.
- NEL/Reporting: persisted.
- `cobble_website_data.mm:669-675` removes only SITE_DATA|CACHE; these stores need DATA_TYPE_HISTORY.
- **Recommendation:**
  - Disable favicon persistence and the predictor under the SDK.
  - Add DATA_TYPE_HISTORY to all-time profile removal and to Cobble's history clear.
  - Add a `historyDisabledLeavesNoUrlTraces` harness check.

### WebAuthn abort — P1 · ✅ Fixed
- `docs/features/passwords.md` records a Debug abort in `AuthenticatorRequestDialogViewControllerViews`.
- Unlike FedCM (patch 0030), there is no guard.
- **Recommendation:** guard like 0030, failing the request with `NotAllowedError`. Check with a CDP virtual authenticator on a fixture page.

### Persisted denials — P2 · ✅ Fixed
- Patch 0002 adds `kDenyPermissionPrompts`.
- `permission_context_base.cc:796-801` persists the BLOCK.
- `download_request_limiter.cc:263-269` saves a BLOCK for automatic downloads.
- Removal never clears CONTENT_SETTINGS.
- **Recommendation:** in `RoutePermissionRequest`, take Cobble-page requests and resolve them `Cancelled()`, which persists nothing. Clear existing BLOCKs once. Add a `deniedPromptDoesNotPersist` harness check.

### Private ≠ Incognito — P2 · Needs decision
- `CreateUnique("Cobble::PrivateWindow")` produces `kOtherOffTheRecordProfile`, so `IsIncognitoProfile()` is false.
- That flag drives the 3P-cookie default (`cookie_settings_factory.cc:105`), HTTPS-First (`https_upgrades_util.cc:81`) and ambient auth (`profile_network_context_service.cc:227-232`).
- **Recommendation:** override those three settings for these profiles. This is lower risk than retyping them as Incognito, which would need a teardown re-audit.

### Subframe events cancel all prompts — P2 · ✅ Fixed
- `cobble_chromium.mm:1264-1275` (`DidStartNavigation`) and `:1348-1356` (`RenderFrameDeleted`) have no primary-main-frame check.
- **Recommendation:** cancel page-wide only for the primary main frame; otherwise cancel only that frame's requests. Add an `iframeNavigationKeepsTopLevelPrompts` harness check.

### Display capture checks — P2 · ✅ Fixed
- `HandleMediaAccessRequest` (`cobble_chromium.mm:2230-2283`) replaces `DisplayMediaAccessHandler`'s policy, activation and visibility checks.
- **Recommendation:** add `IsFeatureEnabled(kDisplayCapture)`, `HasTransientUserActivation()` and a visibility check to the display branch.

### Profile deletion with a manager-held context — P2 · ✅ Fixed
- **Before:**
  - `ChromiumEngine.extensionContext` opens contexts outside `EngineRegistry`, so `retireProfile` never closes them.
  - Native `Validate(require_retired)` then returns BUSY "still has live contexts or pages".
  - Preflight passes, because it doesn't require a retired profile.
  - Deletion then failed after the windows were already closed.
- **Fix:** `ChromiumEngine.removeProfile` closes `normalContexts[profile.id]` before `scheduleProfileDeletion`.
- **Verified:** compile plus the full suite. A manual Full check is pending: toggle Chromium rules for an unused profile, then delete it.

### Unreadable rules file blocks all Chromium pages — P2 · ✅ Fixed
- **Before:**
  - `canLoad` required `writable`, so a corrupt or newer `settings.json` made `createPage` refuse every Chromium tab, private ones included.
  - The message said to disable rules in Settings, which is disabled in that state.
  - WebKit keeps browsing in the same situation.
- **Fix:**
  - `canLoad` = `!failed`.
  - `prepare` skips installing when not writable; Chromium keeps enforcing its already-installed rules extension.
  - `lastError` is still shown.

### Small adapter fixes — ✅ Fixed
- **Pending prompts:** `accept` / `submit` / `select` returning false now cancels the request, matching the client-certificate path.
- **Unrelated blocker error:** `prepare` ignores an earlier queued change's error and relies on `canLoad`/`installed`.
- **Exception cap:**
  - The cap is 512 with an accurate localized error (es added).
  - `setException` checks it too.
  - Sync of more than 512 WebKit exceptions still fails, now with a clear message. Raising the SDK cap toward Chromium's 1000-regex limit is an SDK decision.
- **Launch abort:**
  - Patch 0001 aborts on any nonzero `CCSClientMain`.
  - A lock conflict now exits after the existing alert.
  - A runtime/ABI failure shows "Couldn’t open Cobble" with the error, then exits.
  - Manual check pending: open Full while Cobble runs.

### Update discovery — P2 · Needs decision
- `update.py:54-56` takes `max(time, version)` from chromiumdash `channel=Stable`, which includes Early Stable.
- Open drafts: #8, 9, 11, 13, 14, 15, 18. #18 proposes 158.0.8127.18 at 0.5%.
- **Recommendation:**
  - Filter by VersionHistory `fraction ≥ 0.2`, then take the highest version.
  - Close superseded bot PRs when opening a new one.
  - Add a `test_update.py` case built from today's feed.

### Build lock on SIGTERM — P2 · ✅ Fixed (SDK PR #19)
- **Before:**
  - `compile_chrome` caught only `TimeoutExpired`/`ValueError`/`KeyboardInterrupt`.
  - SIGTERM/SIGHUP (default action) and other exceptions such as `OSError` exited Python and released the flock, while autoninja kept running in its own session.
- **Fix:**
  - `__main__` maps SIGTERM/SIGHUP to `KeyboardInterrupt`.
  - The compile cleanup catches `BaseException`, kills the process group, then re-raises.
- **Test:** `test_compile_stops_its_process_group_on_any_interruption` fails before the fix and passes after.

## 5. Architecture

**Recommendation: keep the current structure.**

- `CobbleChromium` is imported only by `Engine/Chromium/*` and the `App/` composition root. `EngineBoundaryTests` enforces this.
- The ABI is compiled from the overlay header, with exact-match ABI checks and `struct_size` checks on both sides.
- The adapter files (937/854/565 lines) are smaller than `WebKitPage.swift` (1772). No concrete pain justifies a split.
- The worthwhile cleanup is the adapter-duplication row: one callback install/detach function and one generic native-ID map. It is deferred as P3.

## 6. Dependencies (checked 2026-11-06)

| Dependency | Current | Recommendation | Source |
| --- | --- | --- | --- |
| Chromium | 153.0.8010.37 → 157.0.8103.39 | **Updated** (SDK PR #19) | versionhistory.googleapis.com (mac/stable, endtime=none); chromiumdash fetch_releases |
| depot_tools | `81577f19` (2026-09-04) | Update with Chromium; teach `update.py` to bump it | lock file |
| Sparkle | 2.10.1 | Keep (latest; resolved SHA matches tag) | GitHub releases |
| swift-tools-version | 6.0 | Keep | — |
| Cobble CI actions | `@v7` tags | Keep; SHA pinning optional | GitHub |
| SDK `chromium-build.yml` actions | upload-artifact v4.6.2, setup-node v4.4.0 (node20) | Bump to v7 SHAs when the workflow is next used | GitHub Node 20 deprecation notice |
| SDK pin vs `origin/main` | `f0a128e` vs `ef35f30` | Keep until the 157 re-pin; the only difference is a CI timeout | git |

## 7. Rejected candidates

- **Disk blocker for the Chromium update:** the build volume has ample free space; the 10 GiB reading was wrong.
- **External protocols launching without a gesture:** native code requires a gesture, the main frame and a non-opaque origin, and Cobble prompts on every launch.
- **Local-file traversal and symlinks:** blocked by `O_NOFOLLOW_ANY`, an `F_GETPATH` match and a pre-opened descriptor.
- **Native messaging and the Keychain:** native messaging is refused (0007), and the Keychain is scoped to the bundle (0009).
- **Swift threading:** `MainActor.assumeIsolated` is safe because the header guarantees main-thread callbacks. Unmanaged retains and releases are balanced, and prompts can't resolve twice.
- **Permission origin normalization:** case, default ports and punycode are handled and tested. Private windows save nothing.
- **Script injection in the SDK workflows:** inputs are validated, there is no `pull_request_target`, and tokens are read-only.
- **The duplicate patch number 0012:** deliberate, and renaming would change the payload hash.
- **Unifying the three Chromium capability sets:** they differ on purpose (`supportsProfileDeletion`, data removal).
- **chrome:// reachable from the address bar:** the address bar accepts only http/https. The ABI-level gap is the privileged-schemes row.

## 8. Checks run

| Check | Result |
| --- | --- |
| `swift build` (CobbleNativeClient against the pinned SDK) | ✅ |
| `swift test` (Cobble adapter, 12 tests) | ✅ |
| `Localizable.xcstrings` JSON parse | ✅ |
| Full hosted Cobble suite (`Scripts/test.sh`) | ✅ 632 tests, 0 failures, 5 skipped |
| SDK `python3 -m unittest` (73 tests; new test fails before the fix, passes after) | ✅ |
| SDK `swift test` at the pin (specialist) | ✅ |
| `assemble_chromium.py --self-check`, `test_run_config.py` (specialist) | ✅ |
| SDK native harness + smoke on packaged 157 runtime (`93c1dad`) | ✅ 251/251 native checks; navigation, DOM, forms, rendering, WebGL2, downloads, clean shutdown, empty History |
| SDK `unittest` (73), `swift test` (34), smoke fixture after the update | ✅ |
| Cobble `swift build` + adapter `swift test` (12) against pinned `93c1dad` | ✅ |
| Full assembly and launch | ❌ blocked — Xcode signing account unavailable to this session |
| Real sites, hardware, private-window download close in Full | ❌ not run |
