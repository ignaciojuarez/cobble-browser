# Cobble super audit — 2026-11-05

## 1. Scope and state

- **Repo:** `ignaciojuarez/cobble-browser`, worktree `t3/cc2d025a`, base `1fdbf2b` (clean at start). All fixes are uncommitted working-tree edits.
- **Scope:** all first-party source (`App/ Browser/ Domain/ Engine/ Persistence/ UI/`), `Tests/`, `Scripts/`, CI workflow, `Package.swift`/`Package.resolved`, Xcode project settings, `Localizable.xcstrings`, Info.plist, root docs.
- **Excluded:** Chromium SDK source (read only to trace prompts/close at pin `f0a128ea`), generated build output, browser data.
- **Method:** 6 read-only specialists (architecture, dead code/reuse, correctness ×3, dependencies) → coordinator re-read every implicated path before ranking. Ponytail ladder applied to every remedy.
- **Not covered:** live CloudKit, signed/notarized release paths, manual Full (Chromium runtime) behaviour, visual UI checks. Debug-only `ResourcePanel`/`ResourceSampler` skimmed only.

## 2. Ranked findings

Priority: P0 severe · P1 real failure · P2 bounded bug / meaningful cost · P3 cleanup. Confidence is an evidence judgement, not a probability.

| ID | P | Finding | Confidence | Risk | Status |
| --- | --- | --- | --- | --- | --- |
| COR-01 | P1 | Newer/unreadable `session.json` blocks every normal-window page load and cancels every Quit | High — traced all callers | Low | ✅ Fixed (approved) |
| COR-02 | P1 | Return key grants (and remembers) camera/mic in the permission popover | Medium-High — code expects popover to be key; not run | Low | ✅ Fixed (approved) — manual Return check pending |
| COR-03 | P1 | Chromium tab with armed before-unload can't be closed; blocks Quit/window close | Medium-High — traced adapter + SDK; not reproduced | Low | ✅ Fixed (approved) — manual Full check pending |
| ARC-01 | P2 | Quit sequence duplicated; shipping Full build runs the untested copy | High — diffed both bodies | Medium | ✅ Fixed (approved) — manual Full quit check pending |
| DEP-01 | P2 | `actions/checkout@v5` / `upload-artifact@v4` behind v7 (Node 20 deprecated on runners) | High — GitHub API | Low | ✅ Fixed (approved) — verify on next CI run |
| COR-04 | P2 | Script/subframe downloads can queue unlimited save sheets | Medium — assumes no WebKit throttle | Medium | ✅ Fixed (approved) |
| COR-05 | P2 | Dropping a pin/favorite onto itself moves it to the end | High — traced + test | Low | ✅ Fixed |
| COR-06 | P2 | Favorites/pin grid picks the next row for the lower ~40% of each tile | High — failing assertion added | Low | ✅ Fixed |
| COR-07 | P2 | Pre-migration session copy is overwritten by the second save, despite the “retained as a backup” notice | High — traced | Low | ✅ Fixed |
| COR-08 | P2 | One page title over 4 KB stalls history sync for up to 90 days | High — traced + test | Low | ✅ Fixed |
| COR-09 | P2 | Sync rewrites the whole journal ~8× per 30 s cycle even when idle | High behaviour / Medium size | Low | ✅ Fixed |
| DEAD-01 | P2 | Unused contract defaults let a new adapter compile with silent no-ops | High — every conformer listed | Low | ✅ Fixed |
| COR-10 | P2 | Pinned tab with whitespace-only (e.g. `&nbsp;`) or >16 KB title stalls organization sync and all dependent modules | Medium — HTML title trimming not run | Low | 🔎 Investigate |
| COR-11 | P2 | ⌘-click tab lands in a different space when it switches engine; Chromium-opened tabs ignore site rules | Medium — traced, not run | Low | 🔎 Investigate |
| COR-12 | P2 | WebKit opener and child share `WKPreferences`, so one site's popup setting flips the other's | Medium — inferred from tests that rely on sharing | Low | 🔎 Investigate |
| COR-13 | P2 | Two sidebar drop zones vanish after switching spaces from the picker | Medium — depends on `onGeometryChange` not firing | Low-Med | 🔎 Investigate |
| COR-14 | P3 | Local-only (secret-URL) pins jump to the end of their group on organization sync | High — test added | Low | ✅ Fixed |
| COR-15 | P3 | `tel:911` navigates to `http://tel:911/`; `tel:5551234` errors | High — test added | Low | ✅ Fixed |
| COR-16 | P3 | WebKit could grant screen sharing it can neither show nor stop (probe mismatch) | High mismatch / Low likelihood | Low | ✅ Fixed |
| COR-17 | P3 | Toolbar tooltips and VoiceOver labels shown in English for Spanish users | High — catalog checked | Low | ✅ Fixed |
| COR-18 | P3 | 16 Chromium adapter messages never localized | High — catalog checked | Low | ✅ Fixed |
| COR-19 | P3 | Session rewritten (+backup rotated) ~1/s while a page title ticks | Medium | Medium | ✅ Fixed (approved) |
| DEP-02 | P3 | Sparkle 2.10.0 → 2.10.1 (bug fixes, no security/API change) | High — release notes | Low | ✅ Fixed (approved) |
| COR-20 | P3 | Concurrent page `prepare()` restarts extension reconcile (reloads contexts with ≥2 extensions) | High occurs / Medium impact | Low-Med | 🔎 Investigate |
| COR-21 | P3 | Opening a local HTML file fails while content rules are still loading | Medium — timing | Low | 🔎 Investigate |
| COR-22 | P3 | Deleting one profile pauses history/site-setting writes for all profiles | Medium | Low | 🔎 Investigate |
| COR-23 | P3 | Incoming `https://user:pass@…` from other apps bypasses the resolver; tab won't restore | Medium | Low | 🔎 Investigate |
| COR-24 | P3 | Cancelled quit restarts sync in isolated `COBBLE_DATA_DIRECTORY` runs | High code / Low impact | Low | 🔎 Investigate |
| COR-25 | P3 | Chromium tab load fails if an unrelated rule import fails concurrently | Medium | Low | 🔎 Investigate |
| COR-26 | P3 | `setAppPromptPending` default can clear WebKit's own pending flag | Medium | Low | 🔎 Investigate |
| COR-27 | P3 | Missing compiled rule list blocks profile deletion | Low-Medium | Low | 🔎 Investigate |
| COR-28 | P3 | Collapsed-folder state goes stale in drop rows → pin drops into a collapsed folder | Medium | Low | 🔎 Investigate |
| COR-29 | P3 | Cancelled drag's 1 s delayed clear can wipe the next drag | Medium | Low | 🔎 Investigate |
| COR-30 | P3 | Downloads list stats/icons files on every redraw | Medium | Low | 🔎 Investigate |
| COR-31 | P3 | `release.py` feed check may fail on CDN cache; existing remote tag ignores `--target` | Low | Low | 🔎 Investigate |
| COR-32 | P3 | Extension optional-permission sheet not cancelled when its window closes | Low | Low | 🔎 Investigate |
| REUSE-01 | P3 | Prompt presenter setup copied 7× in `BrowserWindowModel` | High | Low | ✅ Fixed |
| REUSE-02 | P3 | Six JSON writes bypass `PersistenceFile` | High | Low | ✅ Fixed (5 of 6) |
| REUSE-03 | P3 | `"chromium"` engine ID retyped 10× | High | Low | ✅ Fixed |
| REUSE-04 | P3 | Canonical-origin check repeated 6× | High | Low | ✅ Fixed |
| DEAD-02 | P3 | Test-only/unused model API (`isLoading`, `renameSpace`, `setSpaceIcon`, `setFolderColor`, `accessibilityTitle`) | High | Low | ✅ Fixed |
| DEAD-03 | P3 | `SyncProvider.name` never read | High | Low | ✅ Fixed |
| DEAD-04 | P3 | `BrowserThemeProviding` protocol with one real conformer | High | Low | ✅ Fixed |
| DEAD-05 | P3 | `disposePopups` alias, `TabSelectionDownload` test helper | High | Low | ✅ Fixed |
| DEAD-06 | P3 | `INFOPLIST_KEY_*` settings ignored (`GENERATE_INFOPLIST_FILE = NO`) | High — built plist checked | Low | ✅ Fixed |
| ARC-02 | P3 | Four stores default to the real `~/Library/Application Support/Cobble` | High — no caller omits it | Low | ✅ Fixed |
| ARC-03 | P3 | `Domain/DefaultBrowser.swift` imports AppKit for no AppKit use | High | Low | ✅ Fixed |
| DOC-01 | P3 | ARCHITECTURE.md: schema 7 (actual 10), 3 of 7 contract files, Persistence row incomplete | High | Low | ✅ Fixed (rest deferred) |
| DEAD-07 | P3 | ~57 dead localization keys | High | Low | ⏸ Deferred |
| REUSE-05 | P3 | HTTP sign-in sheet built twice; copies already differ (proxy wording) | High | Low | ⏸ Deferred |
| REUSE-06 | P3 | Saved-item context menus duplicated and drifted (“Unload Page” only on tiles) | Medium | Low | ⏸ Deferred |
| REUSE-07 | P3 | Settings profile picker + fallback written 6× | High | Low | ⏸ Deferred |
| REUSE-08 | P3 | `ChromiumPage` re-binds callbacks by copy-paste (`attach` vs `closeCancelled`) | High | Low-Med | ⏸ Deferred |
| REUSE-09 | P3 | Update-source validator duplicated; `ContentBlockerSync` uses different rules | High | Low | ⏸ Deferred |
| REUSE-10 | P3 | WebKitPage document-state restore ×3; cert helpers live in page file | High | Low | ⏸ Deferred |
| DEAD-08 | P3 | Other test-only API: `setTabLoadingIndicator`, `SiteSettingsStore.remove/clear`, `BrowserPage.find(_:)`, `clearWebsiteData` | High | Low | ⏸ Deferred |
| DEAD-09 | P3 | `Scripts/run_cobble_build.sh` shim, `smoke_chromium_review.mjs`, `ChromiumResourceFixture.swift` unreferenced | High / Medium | Low | ⏸ Deferred |
| DEAD-10 | P3 | Chromium capability built 3 ways from always-true constants | High | Low | ⏸ Deferred |
| ARC-04 | P3 | Shared test fakes buried in 2,371-line `EngineBoundaryTests.swift` | High | Low | ⏸ Deferred |
| ARC-05 | P3 | Small layer leaks: NSColor hex helpers in Persistence; AppModel builds App-shell types | High | Low | ⏸ Deferred |

**Totals:** 60 findings · 31 fixed (8 after user approval) · 0 open decisions · 17 investigate · 12 deferred · 7 rejected (appendix).

## 3. Per-finding detail

### Decisions — approved and applied 2026-11-05

**COR-01 — newer/unreadable session blocks browsing and Quit (P1)**
- Evidence: `SessionStore.saveLocked` refuses when `canSave == false` (`Persistence/SessionStore.swift:49`). `AppModel.init` then starts from defaults with empty `profileEngineUsage`; the first page calls `recordEngineUse` → `store.saveSynchronously` fails → `EngineRegistry.context` throws “could not save this profile’s engine ownership” (`Browser/EngineRegistry.swift:36-45`). Quit: `flushAndWait` (`Browser/AppModel.swift:253`) returns the same refusal, so `applicationShouldTerminate`/`quitChromiumClient` (`App/CobbleApp.swift:99,181`) cancel termination → Force Quit only. Full also unloads every Chromium page on each Quit attempt.
- Trigger: open an older build after a newer one wrote the session (Fast local ↔ Full release share the workspace), or any read error.
- Recommended fix: `recordEngineUse` returns `true` for `Profile.defaultID` when `!store.allowsSaving` (default profile can't be deleted, so usage is irrelevant); `flushAndWait` returns `nil` when `!store.allowsSaving` (launch notice already explains). `deleteProfile` keeps its own fail-closed save.
- Verify: AppModelTests — write `{"version": current+1}`, build AppModel, open a tab, assert a page exists and `flushAndWait() == nil`; existing failed-final-save test must still cancel.
- **Done:** `recordEngineUse` returns true for the default profile when the store is read-only; `flushAndWait` returns nil when the store is read-only. New `testNewerSessionStillBrowsesAndQuitsWithoutTouchingItsFiles` passes, and fails without the fix with “could not save this profile’s engine ownership”. Failed-final-save test still passes.

**COR-02 — Return grants camera/mic (P1)**
- Evidence: `UI/MediaPermissionPopover.swift:116` `Button("Allow") … .keyboardShortcut(.defaultAction)`; same on “Window…” (`:134`, macOS picker still follows). Eligibility accepts the popover window being key (`:175`). Grant is remembered when `canRemember`.
- Trigger: page calls `getUserMedia` (no gesture needed) while the user is typing; next Return = Allow.
- Recommended fix: drop `.defaultAction` from Allow/Window…; keep Escape → Not Now.
- Verify: manual page requesting camera after 2 s with a focused text field; optional hosted keyDown test.
- **Done:** removed `.keyboardShortcut(.defaultAction)` from Allow and Window…; Esc → Not Now unchanged. Manual Return check still pending.

**COR-03 — Chromium close-time before-unload always cancelled (P1)**
- Evidence: `ChromiumPage.requestClose` sets `.closing` before `source.close()` (`Engine/Chromium/ChromiumPage.swift:429-438`); SDK raises the before-unload dialog during close; `receiveJavaScriptDialog` → `promptHost` requires `.ready` (`Engine/Chromium/ChromiumEngine.swift:659-663`) → `request.cancel()` = “stay”; `requestClosePages` then refuses Quit/window close.
- Recommended fix: `promptHost(_:allowClosing:)`, pass `request.kind == .beforeUnload`.
- Verify: Full build only — fixture with `onbeforeunload`, interact, close tab → sheet; Cancel keeps, Leave closes; repeat with ⌘Q. Not verifiable in this environment.
- **Done:** `promptHost(_:allowClosing:)`; only `.beforeUnload` may reach a `.closing` page. Window side already accepts it (tab, page and generation stay current during `requestClose`). `swift build` ok; manual Full check pending.

**ARC-01 — duplicated quit sequence (P2)**: `App/CobbleApp.swift:99-125` and `:181-212` differ only in reply. Fix: one `prepareToQuit() async -> Bool`. Medium risk because the Full path has no automated coverage; needs a manual Full quit check (failing save + active download). **Done:** both entry points call `prepareToQuit()`; only the reply differs. Manual Full quit check pending.

**DEP-01 — CI actions (P2)**: checkout v5 → v7.0.1 (2026-07-20), upload-artifact v4 → v7.0.2 (2026-10-07); v4 runs on deprecated Node 20. Workflow already sets `persist-credentials: false`; v7 `archive` default preserves behaviour. Only verifiable by a CI run after push. **Done:** both bumped to `@v7`; tags confirmed via `git ls-remote`.

**COR-04 — download sheet flood (P2)**: `WebKitPage.swift:964-1000` turns any frame's attachment into a download, `DownloadStore.swift:264` opens a sheet each. Proposed: one unresolved destination sheet per window, cancel further arrivals. Product behaviour change → decision. **Done:** `DownloadStore.panelWindows`; later arrivals in that window are cancelled with “Another download in this window is waiting for a location.” (es added). New `testWindowShowsOneDownloadSaveSheetAtATime` passes.

**COR-19 — title-tick saves (P3)**: `record` didSet → `persist()` with 250 ms debounce (`AppModel.swift:222`) → two file writes per tick. Proposed throttle (skip if pending, ~1–2 s). Timing-sensitive tests → decision. **Done:** `persist()` is a 2 s throttle (no reset while pending), close to Chromium’s 2.5 s session save delay; quit/explicit saves still flush. Full suite passes.

**DEP-02 — Sparkle 2.10.1 (P3)**: fixes premature install on NFC-encoded paths, release-notes whitespace, `generate_appcast` prefix handling. Requires matching CLI tools for `release.py --tools`; bundle with next release. **Done:** `Package.swift` exact 2.10.1, `Package.resolved` → `ab7d712`; docs/notices/help text updated. `swift build` links Sparkle 2.10.1; download the 2.10.1 tools before the next release.

### Fixed (pre-fix evidence → change → check)

| ID | Pre-fix evidence | Change | Check |
| --- | --- | --- | --- |
| COR-05 | `moveSavedItem` had no `before == id` guard; `insertSaved` then appended | `guard before != id` (`Browser/AppModel.swift:803`) | AppModelTests self-drop assertion |
| COR-06 | `rowY` used nearest `minY` (`UI/SidebarDrop.swift:201`); y=50 on 70 pt tiles hit row 2 | nearest `midY` for row pick/filter/next | SidebarDropTests y=50 assertion (fails pre-fix) |
| COR-07 | `lastValidData` = original bytes, rotated out by save 2 | preserve `session.pre-migration-*.json` on migration (`SessionStore.swift:134`) | ModelPersistenceTests migration test |
| COR-08 | `syncItems` threw on >4 KB/NUL titles for history (uneditable) while `historyItems` blanked them | history syncs untitled; bookmarks keep the actionable error | LibraryStoreTests 5000-byte title |
| COR-09 | `saveState` encoded+wrote full journal on every call (`SyncCoordinator.swift:126`) | `SyncState: Equatable`; skip when equal to last saved; write via `PersistenceFile` | SyncTests/SyncStoreTests pass; write count not directly asserted |
| COR-14 | `nextSaved += localOnly` (`OrganizationSync.swift:155`) | re-insert before the same synced successor | SyncOrganizationReviewTests order test |
| COR-15 | `hostPort` regex matched `tel:911` | exclude `mailto:`/`tel:` from host:port | ModelPersistenceTests assertions |
| COR-16 | request delegate checked `support == .full` only; engine also required `WebKitAudioMute.isAvailable` | probe returns `.denyOnly` unless capture getters exist; engine uses probe alone | Suite (probe not mockable) |
| COR-17 | `.help(String)` shows literal; keys stale but translated | `String(localized:)` at 10 BrowserView call sites; compiled bundle ships stale keys | Catalog checked; `es.lproj` contains keys |
| COR-18 | plain literals in Chromium adapter | wrapped 16 in `String(localized:)` (all have `es`) | `swift test` |
| DEAD-01 | 15 default members in `Engine/Contracts/BrowserEngine.swift` overridden by every conformer; `removeWebsiteData(ids:)`/`clearCache()` uncalled | deleted (−50 lines) + 2 orphaned catalog keys | Xcode + package builds |
| DEAD-02..06 | grep: no production callers | deleted / inlined; tests moved to `updateSpace`/`updateFolder` | Suite |
| ARC-02 | `init(directory: URL? = nil)` → real data folder | `directory` required in 4 stores | Compiler |
| ARC-03 | `import AppKit` in Domain | `import Foundation` | Compiler |
| REUSE-01..04 | see table | `makePresenter`, `PersistenceFile.save/preserve`, `EngineID.chromium`, `AddressResolver.isCanonicalOrigin` | Suite + `swift test` |
| DOC-01 | ARCHITECTURE.md stale | schema/contract/persistence lines updated; themes.md protocol name | Read-through |

### Needs investigation — cheapest next check

| ID | Evidence | Next check |
| --- | --- | --- |
| COR-10 | `saveTab` copies raw `tab.title` (`AppModel.swift:789`); `OrganizationSync.name()` rejects empty-after-trim / >16 KB (`:69-71`) | Test `saveTab` with `"\u{00A0}"` title then apply own projection |
| COR-11 | `adopt` cross-engine path calls `addTab(url:)` → `selectedSpaceID` (`BrowserWindowModel.swift:415,1046`); `ChromiumEngine.receivePopup` only `onCreatePage` (`:270`) | TabCommandTests: opener = favorite in non-selected space, both branches; decide Chromium routing intent |
| COR-12 | children built from opener `configuration` (`WebKitPage.swift:972,1055`); `applyPopupPreference` mutates `configuration.preferences` (`:1540`) | Parent Allow origin, child Ask origin: assert parent flag after child commit |
| COR-13/28 | `resetSpaceRows()` drops rows; `SidebarDropFrameModifier` re-adds only on frame change (`SidebarDrop.swift:865`) | Log `dropSession.rows` after picker switch between two empty spaces |
| COR-20 | each `prepare()` bumps `revision` (`WebKitExtensionManager.swift:578`), aborting the running pass | Two extensions + two concurrent `prepare()`; assert first context instance survives |
| COR-21–27, 29–32 | see specialist traces (file:line in table rows) | Focused tests named per item in the specialist notes |

### Deferred — reason

All P3 maintenance items: safe but either UI refactors without visual verification (REUSE-06/07), Full-only code without runtime coverage (REUSE-08, DEAD-10), product wording choices (REUSE-05, REUSE-09 rule mismatch), or deliberate tooling the owner may still use (DEAD-09 compatibility shim — no repo/T3/KiwiOS reference found). DEAD-07: catalog cleanup is safe to do in Xcode (“Remove stale”), but 114 stale-marked keys are still used at runtime (Full-only/dynamic lookups), so do not bulk-delete.

## 4. Architecture

**Keep current structure.** Engine isolation holds (no WebKit/CobbleChromium in Browser/UI/Persistence/Domain/Contracts/Shared, enforced by `EngineBoundaryTests`). Large files (`BrowserWindowModel` 1.9k, `WebKitPage` 1.8k, `SidebarView`, `BrowserView`) are cohesive around shared state; splitting would widen `private` members for no gain. Optional only-when-touched moves: `BrowserWindowController` out of `CobbleApp.swift`; `DownloadsView` out of `SettingsView.swift`; test fakes to `Tests/TestEngine.swift`.

## 5. Dependencies (checked 2026-11-05 via GitHub API + release notes)

| Dependency | Pinned | Latest | Verdict |
| --- | --- | --- | --- |
| Sparkle | 2.10.1 (`ab7d712`), was 2.10.0 (`eef1a53`) | 2.10.1 (2026-10-25) | Updated (DEP-02); license unchanged; release needs 2.10.1 tools |
| chrome-sdk | `f0a128ea…` | first-party pin | Keep — Package.swift = Package.resolved = CHROMIUM.md |
| actions/checkout | v7, was v5 | v7.0.1 (2026-07-20) | Updated (DEP-01) |
| actions/upload-artifact | v7, was v4 | v7.0.2 (2026-10-07) | Updated (DEP-01) |
| Runner `xcode-27` | — | GitHub-hosted; repo has 0 self-hosted runners | Keep |
| Python/Node scripts | stdlib / `node:` only | — | Keep; no manifests needed |

## 6. Rejected candidates

- CI runs fork PRs on a self-hosted machine — `gh api …/actions/runners` = 0; `xcode-27` is hosted.
- Fail-closed display-capture script added once per page — idempotent, only on WebKit lacking the SPI.
- `BrowserEntitlementsTests` duplicates passkey test — also checks `has(passkeys)`; keep.
- Test seams (`readOnlyTextWindows`, `presentedPopup*`) — deliberate.
- `BrowserPage` defaults used only by fakes — no net reduction.
- `xcodebuild | tee` hides CI failures — `shell: bash` implies `-eo pipefail`.
- Splitting large files — see §4.
- Specialists' cleared areas: SQLite statement/binding lifetimes, session corrupt/newer handling, private-window isolation, prompt single-completion, cookie-transfer scope, extension grants, external schemes, release publish ordering and build-number monotonicity.

## 7. Checks

| Check | Before | After |
| --- | --- | --- |
| `./Scripts/test.sh` (Xcode, all suites) | 625 run, 1 skipped, 0 failed | After decisions: 630 run (+5 new), 0 failed, 5 skipped — the 4 extra are `NSApp.isActive` GUI skips that also skip on an unmodified `HEAD` worktree now (another app held the foreground). COR-01 test fails without its fix. |
| `swift build` / `swift test` (Full client, ChromiumAdapterTests) | build ok | build ok with Sparkle 2.10.1 · 12/12 pass |
| `test_run_config.py`, `assemble_chromium/prepare_update/release --self-check` | pass | pass |
| Manual Full / signed release / CloudKit / CI with actions v7 / manual Return-key check | not run | not run |
