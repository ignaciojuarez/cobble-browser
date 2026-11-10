# Chromium

Cobble's Fast app uses system WebKit. Full packages the same native UI with a
separately built Chromium runtime. Both use `com.ignacio.cobble` and the same
Cobble workspace; engine website stores remain separate. WebKit's default
`legacyDefault` store is not moved or copied. The macOS host is unsandboxed;
Chromium retains its child-process sandbox. Full starts Chromium even when no
Chromium tab is open.

The SDK is a separate Swift package and Chromium patch/build project. This
repository contains the app adapter, package pin and assembler, but not the
Chromium source tree or runtime binary. Build the [SDK](https://github.com/ignaciojuarez/chrome-sdk) and its matching
runtime first, then assemble Full. Source checks and Swift package compilation
do not compile the Chromium engine.

## Working setup

The public app and SDK repositories are the only development sources. Clone
them once as `~/Developer/cobble` and `~/Developer/chrome-sdk`. Use temporary
worktrees for branches; do not keep public/private source mirrors.

Keep one incremental Chromium cache outside either repository. On the maintainer
Mac this is `~/Developer/cobble-chromium-build/chromium-157`; compiled outputs
reference that path, so do not rename it. The Chromium 153 `next-stable` tree is
the rollback source until 157 qualifies, then obsolete. Keep immutable packaged
current/rollback runtimes under `cobble-chromium-build/runtimes/`, not copies of
full build trees.

ABI 17 carries exact popup disposition so modified-link children can open in
the background. The app’s shared page event carries the activation choice for
both Chromium and WebKit.

## Current pins

| Component | Version |
| --- | --- |
| Chromium | `157.0.8103.39` (`9a31f0acec1854d44e49a73fbf8017598151a583`) |
| depot_tools | `9fc44de94012dc6598ed1e84a9251759ed5ea7f8` |
| Cobble SDK | Exact public revision in `Package.swift` and `Package.resolved` |
| Cobble ABI | 19 |

`Package.swift` is the build's authoritative SDK revision. Its explicit
`COBBLE_CHROMIUM_SDK_PATH` override selects an absolute development checkout;
the header ABI, SDK lock, archive and packaged runtime must still match. A Git
revision alone cannot identify uncommitted native payloads. The client accepts
only ABI 19; other ABI values fail before compilation. Do not mix a client from
one ABI with a runtime from another.

## ABI 19 screen sharing

ABI 19 routes `getDisplayMedia` to Cobble's origin prompt as a display request.
Window… or Screen… opens the macOS content-sharing picker for that surface;
cancelling it denies the page. The runtime enables Chromium's system-picker
capture path, so Chrome's own desktop-media picker is never shown. Without that
picker the SDK refuses display requests before asking Cobble. Streams are
video only. Page state reports window/screen capture separately from camera and
microphone. `CCSPageStopMediaCapture` (stop-all) now also ends window and screen
streams.

Window management (`getScreenDetails`, cross-screen placement) arrives as the
`windowManagement` media-request kind. Every other prompt-backed permission
stays denied. Cobble's saved decision answers every camera, microphone and
window-management status check through `ChromiumContext.permissionResolver`,
including quiet checks on load, `permissions.query` and whether
`enumerateDevices` names devices. Chromium keeps only a session grant for
unsaved answers (a one-time grant for camera and microphone, so meeting sites
can pick a device) and stores no denial. `ChromiumContext.resetPermission(_:origin:)`
clears that grant; Cobble calls it whenever its saved decision stops allowing.
See `docs/features/screen-sharing.md`.
The SDK harness covers display metadata, window and screen grants, state, stop,
stop-all and denial. For window management it covers metadata, saved decisions
answering quiet checks, reset and stored-nothing denial. It uses fake devices
and DevTools clicks, since stock Chromium asks only after a click.

## ABI 18 integration

The ABI 18 SDK adds structured navigation failures,
load progress and primary-renderer responsiveness to the adapter. Shared page
state stays engine-neutral; WebKit supplies its native progress estimate too.
The SDK also exposes runtime identity and download source/interruption metadata.
The unbranded runtime enables H.264/AAC for MP4, Media Source Extensions and
HLS. Earlier runtimes omitted these codecs and could show reload/load errors
for social-site videos. Full builds require the matched rebuilt runtime;
rebuilding the Swift client alone cannot add codecs.

The SDK's `AUDIT.md` owns the 125-area gap inventory, research, bridge ownership,
and implementation evidence. Page fullscreen moves the page view into its own
native fullscreen window with an origin banner. General permissions, lock UI,
extension popup/side-panel surfaces, device choosers and the other open feature
rows remain work; adding the diagnostics does not qualify those surfaces.

## Build and verification

```bash
# Compile and test the adapter against the pinned public SDK.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Build and sign the WebKit shell with your own development identity.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Cobble.xcodeproj -scheme Cobble \
  -configuration Debug -derivedDataPath .build/shell \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID build

# After building Chromium from the matching SDK source, use a new output path.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Scripts/assemble_chromium.py /absolute/path/to/Chromium.app \
  --cobble-app .build/shell/Build/Products/Debug/Cobble.app \
  --configuration Debug --output .build/Full/Cobble.app
```

For SDK development, `COBBLE_CHROMIUM_SDK_PATH` selects an absolute checkout.
The optional `Scripts/run.sh local full` wrapper uses the separate build-kit
runner configured by `BUILD_TOOLS`; it is not required for direct assembly.
Both paths wrap an **already built** runtime. The assembler checks the embedded
SDK revision, lock, exports and payload and refuses mismatched inputs or an existing
output app. The wrapper also refuses an active native build and requests an
orderly quit before replacing its staged app. Keep builds and receipts outside
source control.

The public snapshot changes native license headers, so older development
runtime payload hashes do not match it. Rebuild and package from the public SDK
before assembling a matching Full app. No runtime binary accompanies the initial
source publication. Assembly emits `release_ready: false`; development signing
is not Developer ID/notarized distribution.

## Unification validation (2026-10-01)

The public ABI 17 runtime was rebuilt incrementally, packaged with matching
native-payload provenance, and checksum-verified. The isolated harness passed
225 native checks, including modified-link popup disposition. Cobble passed
581 hosted tests and 9 adapter tests; the SDK passed 66 Python and 20 Swift
checks. Full assembly passed deep/strict signature verification.

The broader smoke run then timed out during interrupted GET download recovery.
The SDK later fixed that Swift-side retry handling (AUDIT F01); matched
fixtures now pass it (see Runtime boundaries). The runtime remains a
development artifact; no new signed app update is published by this source
migration.

## Chromium 157 validation (2026-11-06)

The SDK moved from 153.0.8010.37 to 157.0.8103.39 with all patches rebased and
the audit's native fixes (see `artifacts/chromium-sdk-audit.md`). The packaged
development runtime (`release_ready: false`) passed the isolated SDK harness:
251 of 251 native checks, plus navigation, DOM, forms, rendering, WebGL2,
downloads, clean shutdown and empty History tables. The former PiP, document
PiP and display-media containment failures were harness artifacts and pass.

Chromium 157 refuses page fullscreen unless the page view has focus in the key
window; a real click provides that, and Cobble focuses the selected tab. The
Cobble adapter built against the pinned SDK and its 12 tests passed. Full
assembly and launch, closing a private window during a download, real sites
and hardware remain to be checked.

## Screen sharing validation (2026-11-04)

The [matched development runtime](https://github.com/ignaciojuarez/chrome-sdk/releases/tag/sdk-153.0.8010.37-abi19-f0a128e)
adds ABI 19 screen sharing and window management. It also fixes a page that
leaves full screen while macOS is still animating in: before, its window stayed
full screen until Esc.

**SDK harness.** All 13 new checks passed:

- seven display checks, including stop-all;
- six window-management checks, including saved decisions answering quiet checks.

DevTools clicks drive window management, since stock Chromium asks only after
one. 242 of 245 native checks passed; the DevTools frontend probe was skipped
because it needs a foreground key window. The three failures need no new native
window and fail identically on the unmodified ABI 18 `371054c` runtime:

- picture-in-picture
- document picture-in-picture
- display-media containment

**Source and adapter checks.** SDK Python (72), Swift (34) and Cobble adapter
(12) tests passed with the pinned SDK. The full Cobble suite passed: 625 tests,
including the four local WebKit audio-mute fixtures.

**`local full` fixture flow** (one display; this Mac has no camera or
microphone, so step 1 used Chromium's fake devices):

- Cobble's prompts named `http://localhost:8765`.
- Remembered camera, microphone and window-management allows answered without
  a prompt, and `permissions.query` reported `granted`.
- Screen details read the real 1920×1080 display.
- The real macOS picker opened for Window…, and Cancel gave `NotAllowedError`.
- A real Screen… share reported `monitor`, and the site menu's Stop ended it.
- Turning Camera off ended the camera, microphone and screen tracks.
- Revoking asked again, and a blocked site was refused without a prompt.
- Fullscreen reported events `[true, false]`, and the window left full screen in
  3 of 3 runs.

Real hardware, multiple displays and real sites remain unqualified.

## Fullscreen validation (2026-10-31)

The [matched development runtime](https://github.com/ignaciojuarez/chrome-sdk/releases/tag/sdk-153.0.8010.37-abi18-371054c)
lets Chromium pages and videos enter full screen. The page moves into its own
native full-screen Space with a 3-second origin banner. A crashed page renderer
no longer crashes the browser; Chrome's sad-tab view needs a Chrome window.

In isolated Full, enter, page exit (original size restored), Escape, navigation
and tab close worked, and a renderer crash left the browser running where the
previous runtime crashed. SDK Python, Swift and node checks passed. Real-site
and macOS-initiated exit qualification remain open.

## Page menu validation (2026-10-23)

The [matched development runtime](https://github.com/ignaciojuarez/chrome-sdk/releases/tag/sdk-153.0.8010.37-abi18-73ea7c5)
adds Chrome's native right-click page menu in Cobble windows. Commands for
Chrome windows, profiles, panels, bubbles, settings, sync, passwords, AI and
View Source are hidden; Inspect appears only while Cobble's DevTools are open
for that page. Copy toasts are skipped because they need a Chrome window.

In isolated Full, Open Image/Link in New Tab, Save Image As, Copy Image, Copy
Image/Link Address, page Save As, Print and Inspect worked. The SDK harness
passed; SDK Python, Swift and node checks and Cobble adapter tests passed.

## Media validation (2026-10-17)

The [matched development runtime](https://github.com/ignaciojuarez/chrome-sdk/releases/tag/sdk-153.0.8010.37-abi18-dec9f53)
includes the immutable archive, checksum and validation summary.

The pinned ABI 18 runtime decoded synthetic H.264/AAC MP4 and advanced video
frames. PNG, JPEG and WebP decoded too. Full smoke passed MP4/AAC and VP9
playback/MSE capability checks, navigation, WebGL2, history and cleanup. The SDK
harness passed all 237 native checks with zero skips using a 120-second timeout;
the initial 30-second run timed out during repost validation. Archive checksum,
ZIP integrity and deep/strict app signatures passed. These are isolated fixture
checks; live Instagram/X account playback and release qualification remain open.

## Historical development evidence

The checks below predate the public snapshot and must be repeated for a release.

The September 23 ABI 16 integration passed 94 focused hosted tests and 8 Swift
adapter tests. A Full fixture assembled, passed deep/strict signature checks,
and launched with an isolated data root. The default-off login-sharing fixture
passed 9/9 WebKit↔Chromium checks with synthetic credentials; see
[`docs/features/login-sharing.md`](docs/features/login-sharing.md). These checks
do not qualify real accounts, CloudKit, everyday use, or notarized distribution.

Matched ABI 16 native evidence includes:

| Area | Evidence | Limit |
| --- | --- | --- |
| Browser identity | 44/44 native checks, including redirects, popups, history/BFCache and UA hints | Service/shared workers keep native identity; site compatibility is untested |
| Cookie transfer | 4/4 native checks for supported fields, scope rejection, private rejection and empty replacement | HTTPS/443 host scope; transfer is non-atomic and opt-in |
| Extension registry | 10/10 checks, including theme rejection and private observer isolation | Store consent, restart/updater and arbitrary extension behavior remain open |
| Native sandbox | ABI 6 inspection found installed Seatbelt state on renderer, GPU, network and storage children | Not an operation-denial test; video-capture service declares no sandbox |

The matching SDK build tree stores `evidence/full-chrome-current-phase.json`,
`evidence/identity-bfcache-resume.log`,
`evidence/cookie-transfer-abi16/summary.json`, and
`evidence/extension-registry-abi16-final/registry.json`. These receipts are not
included in this source repository. The ABI 13 ordinary-launch checks are also
historical evidence, not a substitute for an ABI 16 privacy check: 80-second
fresh/reused unmanaged profiles observed no ListAccounts, GCM registration,
or AIM requests while component update and network-time traffic remained.

## Runtime boundaries

- **Authentication:** HTTP/proxy auth and owned prompts have focused checks.
  Chromium client certificates, WebAuthn/Touch ID, the Apple Passwords helper,
  and real-site Sign in with Apple need the separate gates in
  [`docs/features/passwords.md`](docs/features/passwords.md). A FedCM crash guard
  rejects dialogs without a Views host widget; account sign-in through that
  dialog remains unsupported.
- **Downloads and files:** interrupted GET recovery and POST non-replay passed
  matched native fixtures. Local-file access authorizes one selected regular
  document through an owned descriptor; sibling files, workers, subresources,
  file downloads and PDF through that path are not generally allowed. Browser
  restart, replacement and real-file workflows still need qualification.
- **Extensions and blocking:** normal-profile native blocking and extension
  registry paths have fixtures. Chrome Web Store consent, updates, private
  access and general extension compatibility are experimental.
- **Media and security:** camera/microphone prompts, content blocking and
  printing exist on the ABI 16 path. Hardware/TCC, Safe Browsing service
  availability, proprietary codecs/DRM and ordinary network behavior need
  direct tests. The unbranded build enables H.264/AAC but does not include Widevine.
- **Storage and identity:** Chromium profile deletion has an app preflight and
  durable recovery path; physical cleanup, private isolation and restoration
  still need native end-to-end qualification. Do not copy WebKit cookie files
  or change `HOME` to bridge stores.

`ROADMAP.md` owns the remaining P9 and release gates: child sandbox enforcement,
native focus/IME/accessibility, permissions and data deletion on the shipped
runtime, manual website compatibility/performance, security-update
ownership, Developer ID/notarization, clean install and sustained daily use.
Diagnostic smoke runs with background networking suppressed cannot prove
ordinary-launch privacy or release resource costs.

The earlier sandboxed-host XPC broker experiment is historical. It did not
qualify real Chromium child launch in that topology and does not gate the
current unsandboxed host design.

## Camera and microphone state (2026-11-10)

The SDK smoke gained device-list checks for camera and microphone. On the beta
14 runtime it failed: after Allow, `permissions.query` reported `prompt` and
`enumerateDevices` named no devices. With the SDK fix
([chrome-sdk#21](https://github.com/ignaciojuarez/chrome-sdk/pull/21), `77ab40e`:
status resolver for camera/microphone, one-time grant after Allow, reset for
both), the rebuilt development runtime passed 256 of 256 native checks,
including picking a device by ID. Cobble pins `77ab40e`. Fake devices skip
macOS camera/microphone permission, so real hardware, a Developer ID release
and real meeting sites remain to be checked.
