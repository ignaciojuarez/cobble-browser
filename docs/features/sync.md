# iCloud sync

Optional, off by default, for one person's Macs on the same iCloud account. Local data remains usable without iCloud. Cobble does not offer shared accounts, cross-person spaces, or a Linux transport.

| Category | Default after enabling sync | Transfers |
| --- | --- | --- |
| Organization | On | Profile names/IDs, spaces, folders, pins, favorites |
| Bookmarks | On | Library bookmarks; requires Organization |
| Open tabs | Off | Ordinary tab URL/title/name/space/order; requires Organization |
| History | Off | Visit records; requires Organization |
| Preferences | Off | Search engines, shortcuts, tab behavior |
| Site settings | Off | Site zoom; requires Organization |
| Content blockers | Off | Preferences and site exceptions for matching engines; requires Organization |

Private tabs, cookies, passwords, website stores, file bookmarks, downloads, live forms, extension binaries, OS permissions, engine grants, and window geometry stay local. Engine assignments can sync while the engine is unavailable; a receiving Mac may temporarily open the tab in WebKit without changing the saved preference. Remote tab closure still obeys the local page-close confirmation. Disabling a category pauses transfer on this Mac and does not erase cloud data; local deletions while paused may reappear when re-enabled.

## Implementation and limits

- `Domain/Sync/SyncProvider.swift` defines portable records; `Persistence/Sync/CloudKitSyncProvider.swift` is the CloudKit adapter. `Browser/Sync/SyncCoordinator.swift` owns opt-in choices, account binding, retries, and module application. A running normal app polls every 30 seconds; isolated test directories do not auto-connect.
- `sync-state.json` journals identity, acknowledgments, pending uploads, and cursors with atomic writes. Write failure stops uploads; corrupt or newer journals disable sync without overwriting them. Explicit history deletion is journaled before local removal.
- Modules use private CloudKit zones and encrypted Bytes payloads. No public/shared database is used, and Cobble makes no end-to-end encryption claim for these records. Fields merge by logical counter plus device ID, not wall clock. Unknown fields survive; unsupported versions refuse writes. Deletion tombstones have no compaction or device expiry.
- Account changes pause sync until the current local data is explicitly connected again. Parent deletion and concurrent moves repair organization deterministically; a remote profile removal with open windows pauses that category. Native website stores are never erased by sync.
- Only validated HTTP(S) destinations transfer. Local files, URL userinfo, and known secret query/fragment keys are filtered, but site-specific secret formats may escape the filter. Imported blocker files stay local. Missing engines retain cloud records; unsupported local blocker configurations pause that category. Live remote rule removal is not supported.

## Release qualification

Signed builds need the `iCloud.com.ignacio.cobble` container and the `CobbleSyncRecord` production schema with encrypted Bytes `payload`. Unsigned builds show a Settings error. Local isolated tests cover two-client merge, offline journal recovery, account changes, category dependencies, invalid data, missing engines, and tab-close vetoes. Signed two-Mac CloudKit behavior, production schema, offline conflicts, deletion, and upgrade still need verification. See [ROADMAP.md](../../ROADMAP.md).
