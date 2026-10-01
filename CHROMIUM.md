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
Mac this is `~/Developer/cobble-chromium-build/next-stable`; its existing path
is preserved because compiled outputs reference it. The former Chromium 152
checkout is obsolete. Keep immutable packaged current/rollback runtimes under
`cobble-chromium-build/runtimes/`, not copies of full build trees.

ABI 17 carries exact popup disposition so modified-link children can open in
the background. The app’s shared page event carries the activation choice for
both Chromium and WebKit.

## Current pins

| Component | Version |
| --- | --- |
| Chromium | `153.0.8010.37` (`b75a5a95ea1a1b55bdbfd6d9f42d47be7507fb8b`) |
| depot_tools | `81577f19a8497ba7e41afac322e8f03553a863ec` |
| Cobble SDK | Exact public revision in `Package.swift` and `Package.resolved` |
| Cobble ABI | 17 |

`Package.swift` is the build's authoritative SDK revision. Its explicit
`COBBLE_CHROMIUM_SDK_PATH` override selects an absolute development checkout;
the header ABI, SDK lock, archive and packaged runtime must still match. A Git
revision alone cannot identify uncommitted native payloads. The client accepts
ABI 3 and 10–17; unsupported ABI values fail before compilation. Do not mix a
client from one ABI with a runtime from another.

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
SDK manifest, exports and payload and refuses mismatched inputs or an existing
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

The broader smoke run timed out during interrupted GET download recovery on
both the original private ABI 17 runtime and the rebuilt public runtime. This
is an existing open qualification issue, not a passing download/release gate.
The runtime remains a development artifact; no new signed app update is
published by this source migration.

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
  direct tests. The reviewed unbranded build does not include Widevine or
  proprietary codecs.
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
