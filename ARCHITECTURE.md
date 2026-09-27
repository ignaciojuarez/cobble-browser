# Architecture

Native macOS 26+ browser, Swift 6. AppKit owns windows, geometry, restoration, and focused commands. SwiftUI renders chrome, settings, and overlays. System `WKWebView` is the default. Full also wraps the Chromium SDK. Fast and Full are the same unsandboxed app (`com.ignacio.cobble`) with shared Cobble records and engine-specific website stores. Chromium keeps upstream child-process sandbox policies; platform exceptions are recorded in `CHROMIUM.md`.

Source presence is not a release gate. Remaining work: `ROADMAP.md`. Why: `DECISIONS.md`. SDK pins: `CHROMIUM.md`.

## Project shape

| Location | Responsibility |
| --- | --- |
| `App/` | Lifecycle, window controllers, menu dispatch, adapter assembly |
| `Browser/` | Shared and window models, prompts, downloads, website-data coordination |
| `Domain/` | Codable records, engine/context identity, address resolution |
| `Engine/Contracts/` | Engine, context, page, blocking, transfer — no rendering SDK types |
| `Engine/Shared/` | Shared adapter implementation: content-rule downloads and favicon normalization |
| `Engine/WebKit/` | System WebKit adapter |
| `Engine/Chromium/` | Chromium SDK adapter (Full only) |
| `UI/` | SwiftUI chrome and the retained native page container |
| `Persistence/` | Sessions, SQLite library, preferences, site permissions |
| `Tests/` | Fake-engine contracts and isolated WebKit/UI checks |

One app target, one test target. `Package.swift` also builds `CobbleNativeClient` for the SDK launcher. Register adapters at assembly. No plugin loader. A source-boundary test rejects both rendering SDKs and adapter types in Browser/UI/Persistence/Domain/Contracts/Shared. This is a single-module boundary, not separate Swift packages. AppKit is allowed at native boundaries.

The Xcode test scheme owns its isolated test environment. The package's separate
`ChromiumAdapterTests` target exercises adapter boundaries against the selected
SDK and ABI; these checks do not require or qualify the packaged native runtime.

## Names

| Name | Meaning |
| --- | --- |
| `SavedItem` | Durable favorite (`spaceID == nil`) or space pin |
| `Tab.savedItemID` | This window’s live or unloaded instance of a `SavedItem` |
| `LibraryEntry.isBookmark` | SQLite library bookmark, not a sidebar pin |
| `BrowserPage` | Live engine page (`pages` / `selectedPage`) |
| `EngineContext` / `BrowsingContextID` | Engine × profile × optional private window |
| `SiteSetting` | Camera/mic/popups/zoom per exact origin × engine × profile |
| `PagePresenter` | Originating-window sheets and media popovers; one completion per request |

`Browser*` means not the rendering SDK. `AppModel` lives in `Browser/` because `App/` is the process shell.

## Ownership

```text
AppModel
  profiles, spaces, folders, saved items     shared durable organization
  BrowserWindowModel[]
    WindowRecord                             durable normal-window state
    address draft, command query, focus      window-local
    BrowserPage keyed by tab UUID            live until close/discard
    PageFileOperations                       page export and file-panel lifecycle
  EngineRegistry                             adapters and contexts
  SessionStore                               durable snapshots
```

Windows share saved organization, not live tabs, selection, drafts, or page views. One native page has one window owner. Callbacks are generation-checked; an edited address is not overwritten by background navigation.

## Durable records

| Record | Meaning |
| --- | --- |
| `Profile` | Identity + `legacyDefault` or `named(UUID)` store |
| `Space` | Ordered workspace in one profile; optional one-grapheme icon |
| `Folder` | Acyclic same-space pin hierarchy |
| `SavedItem` | Saved URL/title; nil space = favorite |
| `Tab` | Window-local page identity, current URL, optional saved item |
| `WindowRecord` | Profile, selection, tabs, sidebar, frame |
| `SessionSnapshot` | Versioned organization + normal windows |
| `SyncCoordinator` | Module choices, account binding, journal commits, and applying changes through browser/store projections |
| `SyncState` | Provider-neutral field merging, tombstones, local comparison baseline, and pending uploads |
| `CloudKitSyncProvider` | iCloud identity, private zones, opaque cursors, conditional writes, and server backoff |
| `ProfileEngineUsage` | Engines that may own profile data, saved before first use |
| `PendingProfileDeletion` | Required engine cleanup retained across failure/restart |

Saved URL and current navigation are separate. Private windows never enter snapshots. Folder delete promotes children; space delete moves within the profile; the last space stays.

Optional iCloud sync uses a separate record projection. The local session remains the recovery copy; CloudKit records exclude website stores, cookies, passwords, private tabs, file bookmarks, and window geometry. Modules and prerequisites are described in `docs/features/sync.md`.

## Website data and pages

Default profile stays on `WKWebsiteDataStore.default()` via `legacyDefault`. Named profiles use stable store UUIDs. Spaces share logins; they are not privacy boundaries. Private windows use a nonpersistent store per window. Downloads and explicit organization edits can persist. `COBBLE_DATA_DIRECTORY` is fixtures only.

Create pages lazily. `prepare()` gates navigation; `close()` invalidates callbacks. Tab switches do not reload a live page. Recovery restores URLs and organization, not DOM, forms, or engine history.

Stored web URLs never pass through search fallback. Local-file reactivation uses
the dedicated bookmark-authorized load path. Private file bookmarks stay in the
window model, copy on duplication, and disappear when their tab closes. Private
contexts never add durable profile-engine usage records. Profile deletion waits
for that profile's live and already-retiring contexts, not unrelated windows.

## Session files

`PersistenceFile` owns atomic writes and unique recovery copies. Each store keeps its own schema validation and recovery policy. Preferences and site settings expose `PersistenceStatus` to distinguish a read-only load failure from a retryable write error. Page file workflows live in the window-owned `PageFileOperations`; tab/bookmark commits remain in `BrowserWindowModel`.

`~/Library/Application Support/Cobble`, process lock, debounce, atomic replace, `session.backup.json`, preserve corrupt/newer data, flush on quit. A final save failure cancels quit, and private-window lifecycle does not rotate the normal-session backup. Schema 7 includes profile engine ownership and pending deletion records. Settings General can export redacted diagnostics with no URLs, cookies, or history.

Before an engine creates profile data, its identity is saved through the existing
session writer. Deletion requires those engines even after switching to Fast.
Older named profiles conservatively require WebKit and Chromium because their
past engine use was not recorded. A saved deletion marker fences the profile
until every required cleanup finishes; native logical scheduling alone is not
completed deletion. Private page URLs and session records remain excluded.

Browser state is runtime data, not project source. It is intentionally excluded
from the project-only new-Mac handoff in `AGENTS.md`.

## Engines

Contracts in `Engine/Contracts/`: engine/context and blocking in `BrowserEngine.swift`, page state/events and operations in `BrowserPage.swift`, and typed requests in `PagePrompts.swift`. Both adapters keep engine/context, page, and download implementations in separate files. SDK types with matching adapter names are qualified with `CobbleChromium.`. Content blockers and extension managers require `ProfileMutationGuarded`; assembly installs their ownership guard without optional casts. Platform entitlement probes, passkey authorization, and visibility logging live in `App/`; Sign in with Apple URL parsing stays in `Domain/AppleSignIn.swift`. WebKit is the shipping adapter. Routing: tab override, then exact-host rule, then app default. Popup children retain the opener's context, engine override, and space, and are rejected once the opener starts closing. In Fast, saved Chromium assignments temporarily use WebKit without rewriting their engine preference. Website stores stay separate. Default-off experimental login sharing can transfer supported site cookies before an engine-switch navigation within the same normal profile; see `docs/features/login-sharing.md`. Chromium details: `CHROMIUM.md`.

Page capabilities control shared actions and site controls. Typed prompt requests
carry the originating tab, context, window, document and frame; adapters retain
native request handles and deny stale or unhandled decisions. `PagePresenter`
owns AppKit sheets and resolves file choices after sheet teardown. Native
security evidence supplies the connection label; on-demand connection details
are discarded when the page's document/security revision changes, including
same-URL reloads. SDK and certificate-framework types stay in adapters.
Client-certificate prompts carry an explicit document, navigation or page
context instead of fabricated frame IDs. The shared sheet receives bounded
certificate descriptions and opaque choice IDs; adapters retain identities,
private keys and native completions. Chromium revalidates the originating
request after asynchronous key acquisition. WebKit checks the current page
request/navigation and builds client credentials without requiring the server's
client CA to be locally trusted. Neither adapter persists the selected identity.
Live detach registers the destination AppKit window before calling the engine's
move operation, then adopts the retained page. A refused move removes the empty
destination; an old SwiftUI container cannot unmount a page already reparented.

## Chrome numbers

| Measure | Value |
| --- | --- |
| Sidebar width | 280 default, 260–440 |
| Resize hit | 20 pt across the boundary |
| Space swipe | 25% of sidebar width; no wrap, no haptics |
