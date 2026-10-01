## Cobble

Native macOS 26+ browser in Swift 6, with favorites, pins, spaces, folders, and tabs.

- **AppKit** owns windows, geometry, restoration, and focused commands.
- **SwiftUI** renders browser chrome, settings, and overlays.
- **WebKit** is the default engine. A separate Chromium SDK enables Full builds; see `CHROMIUM.md`. Both builds use `com.ignacio.cobble` and the same workspace.

## Source of truth

Develop, review and push in public `ignaciojuarez/cobble-browser`. The former
private repository is archived; there is no source-porting or mirror workflow.
Use branches and T3 worktrees for unfinished work. Chrome SDK is independently
maintained in public `ignaciojuarez/chrome-sdk`; pin an exact revision and use
its matching runtime. Keep machine overrides in ignored `Scripts/run.local.config`,
signing keys in Keychain, and browser data/build outputs outside Git.

## Commands

Open `Cobble.xcodeproj` in a compatible Xcode to build the WebKit app. The
hosted tests run without signing:

```bash
xcodebuild -project Cobble.xcodeproj -scheme Cobble \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

`./Scripts/test.sh` runs the same hosted tests without `build-kit`. For launch
and Full packaging, `Scripts/run.sh` uses `build-kit` at
`$HOME/Developer/build-kit` by default; `BUILD_TOOLS` selects another checkout.
`./Scripts/run.sh local fast` launches WebKit. With the matching Chromium SDK
and prebuilt runtime, `./Scripts/run.sh local full` packages both engines; it
does not compile Chromium. `swift test` runs Chromium adapter checks when the
SDK is available. Use `COBBLE_CHROMIUM_SDK_PATH` only for an explicit local SDK
checkout. Select Xcode with `DEVELOPER_DIR`, `XCODE_APP`, or `COBBLE_XCODE`.

Use `CobbleTests` for focused checks. Fixtures need nonpersistent WebKit storage
and temporary Cobble storage. A green suite is not a manual-browser or release gate.
The scheme uses its own test environment (`COBBLE_TESTING=1`), not launch
settings, so the host does not acquire the normal workspace.

All normal builds are unsandboxed macOS apps named Cobble, bundle ID
`com.ignacio.cobble`, using `~/Library/Application Support/Cobble`. Full retains
Chromium's renderer sandbox and stores engine data under `Cobble/Chromium`.
Fast and Full use the same signing certificate; set a Development Team locally
in Xcode and never commit credentials. Quit (⌘Q) before Stop/rebuild when you care
about cookies; Xcode Stop skips orderly quit. Explicit `COBBLE_DATA_DIRECTORY`
is for isolated fixtures and forces nonpersistent WebKit storage in either
configuration; normal build commands never set it. Do not copy cookie files or
move `legacyDefault` off `WKWebsiteDataStore.default()`. No legacy-store migration
is requested. Chromium assignments temporarily run in WebKit when Chromium is
absent, without rewriting preferences. A workspace lock prevents concurrent writers.

## Releasing updates

When the user says **release**, **upload the build**, or **publish an update**,
complete the public Full release **and** signed in-app update feed. A source
push or PR alone is not a release. The destination is
[`ignaciojuarez/cobble-browser`](https://github.com/ignaciojuarez/cobble-browser/releases),
from this same source repository.

Read `docs/features/updates.md` and use `Scripts/release.py` build/finish/publish.
Use an increasing public build number, the pinned SDK and matched runtime,
Developer ID signing, Apple notarization/stapling, and the existing Sparkle key.
Keep binaries outside git. Verify the app, archive signatures and public download
checksum; publish `updates/appcast.xml` last and verify its public build/asset.
Return the public release link and feed status. Do not claim untested gates passed.
Beta 1's updater cannot start: those users need one manual install of a later beta.

## Docs

Keep these at the project root. Feature status lives under `docs/features/`.

| File | Owns |
| --- | --- |
| `AGENTS.md` | How to work in this repo |
| `ROADMAP.md` | Phases, gates, remaining work |
| `CHANGELOG.md` | Public changes, newest first |
| `RESEARCH.md` | Tight research notes; ROADMAP points here |
| `DECISIONS.md` | Why. Edit a changed decision in place |
| `ARCHITECTURE.md` | Ownership, state, persistence, runtime |
| `FEATURES.md` | v1 / qualified / later / never |
| `CHROMIUM.md` | SDK integration, pins, qualification |
| `docs/features/apple-browser.md` | Apple browser doors — default browser, entitlements, helper list |
| `docs/features/passwords.md` | Apple Passwords, passkeys, SIWA — latest state |

## Rules

- **Ponytail:** fewest files, native APIs first, no speculative frameworks. Engine contracts live in `Engine/Contracts/`.
- Rendering SDK types stay in engine adapters. Browser / UI / persistence / domain stay engine-neutral.
- Shared saved organization; window-local tabs, selection, draft, and page hosts.
- Default profile stays `legacyDefault` / `WKWebsiteDataStore.default()`.
- Persist validated versioned records. Surface write failures. Private tabs never enter session snapshots.
- Recovery restores URLs and organization, not unsaved page memory.
- No AI chrome, telemetry, custom cache, or Cobble password vault. System Apple Passwords is entitlement-gated on WebKit; Chromium may use Apple’s system helper (in scope, not required). Apple browser doors: `docs/features/apple-browser.md`. Passwords: `docs/features/passwords.md`.
- Never commit Chromium build outputs, signing credentials, browser data, or local evidence. Native Full builds are local.
- WebKit WebExtensions: public APIs, explicit site grants, private access opt-in. No Safari App Extensions.
- Native tab output mute uses the runtime-checked private bridge in `Engine/WebKit/WebKitAudioMute.swift`. Keep it adapter-local; never substitute playback suspension or bypass its capture-history guard. See W18 in `ROADMAP.md` for qualification and the fresh-tab limitation.
- Do not mark a roadmap gate complete without its named evidence. Seven-day use, signing, and notarization cannot be inferred from a local build.
