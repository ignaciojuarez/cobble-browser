# Screen sharing and screen details

Latest state of `getDisplayMedia`, window management (`getScreenDetails`) and
how they combine with camera, microphone and fullscreen. Roadmap: W19.

## Engine parity

| Capability | WebKit pages | Chromium pages |
| --- | --- | --- |
| Screen sharing | Cobble prompt, then the macOS picker | Cobble prompt, then the macOS picker |
| Shared audio | WebKit decides | None: video only |
| Screen details | Stock WebKit: `window.screen`, no `getScreenDetails` | Stock Chromium: `getScreenDetails` after a Cobble prompt |
| Cross-screen window placement | Not available | Stock Chromium once window management is allowed |
| Fullscreen | Stock WebKit element fullscreen | Stock Chromium fullscreen |

The split is deliberate. Chromium pages get the screen APIs stock Chromium
offers, and WebKit pages keep stock WebKit's capability. Cobble does not
emulate, override or filter what a site reads about screens or windows. It does
not suppress or rewrite `fullscreenchange` or `fullscreenElement`.

## Prompts and saved decisions

| Permission | Prompt | Saved per site | Revoked by |
| --- | --- | --- | --- |
| Camera, microphone | Not Now / Allow | Allow, Deny | Site-menu switch off, Settings |
| Window management (Chromium) | Not Now / Allow | Allow, Deny | Site-menu switch off, Settings |
| Screen sharing | Not Now / Window… / Screen… | Deny only | Site-menu switch on, Settings → Ask |

- Every prompt names the requesting origin. A prompt for an embedded frame also names the top-level page.
- Embedded and private-window requests are never remembered.
- Screen sharing grants are never saved; the specification forbids it. Each
  request asks, and choosing a window or screen in the macOS picker is the final
  consent. A blocked site gets `NotAllowedError` with no prompt.
- The site menu's Screen sharing switch lets the site ask (on) or blocks it
  (off). Blocking also stops current sharing. **Stop** ends sharing without blocking.
- The screen sharing and window-management prompts note when two or more
  displays are connected. Cobble counts them from AppKit's display list. The
  note is informational: it is not sent to the page and does not change or gate
  the request.
- As in stock Chromium, a site can prompt for window management only after a
  click. Without one, `getScreenDetails` checks quietly.
- Chromium asks Cobble's saved decision on every window-management status
  check, quiet checks and `permissions.query` included. So a remembered allow
  or deny holds on page load and reports `granted` or `denied`.
- An unsaved grant (embedded, private, or before saving) lasts for Chromium's
  browsing session. Like Chrome's "Allow this time", it reports `prompt`.
- Turning the switch off, choosing Ask or Deny in Settings, or Forget clears that
  session grant. A denial stores nothing in Chromium.

## Stopping

- The Screen sharing **Stop** button ends window and screen streams.
- Chromium only offers stop-all, and it ends camera, microphone, window and screen streams together. Turning off
  camera or microphone on a Chromium page therefore also ends its screen sharing.
- If a stop fails, Cobble unloads the page and says so.

## Fail-closed cases

A site gets a clean `NotAllowedError`, never a silent platform-only consent, when:

- the user chooses Not Now, cancels the macOS picker, or the site is blocked;
- Cobble cannot show its prompt (inactive app, background tab, sheet, navigation);
- WebKit lacks the checked private delegate. With only the request delegate, it
  is refused there. With none, `WebKitDisplayCapture.failClosedScript` makes
  page-world `getDisplayMedia` reject before WebKit's stock picker can open;
- Chromium has no macOS content-sharing picker (`kUseSCContentSharingPicker`
  off or macOS before 14). The SDK refuses before asking Cobble. There is no
  fallback that needs blanket Screen Recording permission.

Known limit: without the WebKit delegate, a script in another content world,
such as an extension, still reaches WebKit's stock picker. That picker still
requires choosing a source.

## Verification

`Tests/Fixtures/PermissionFlow/index.html` runs one origin through the order
permission-heavy sites use:

1. camera and microphone
2. screen details
3. screen sharing
4. fullscreen

Each step reports exactly what the engine returned.

| Evidence | Covers |
| --- | --- |
| `WebKitPageTests.testPermissionFlowHonorsSavedDecisionsAndFailsClosed` | Saved allow, revoke, deny; real screen size; block; refusal without a prompt |
| `WebKitPageTests.testPermissionFlowAsksWithTheOriginAndKeepsFullscreenEvents` | Cobble prompts, remembered allow, never-saved sharing, fullscreen events `[true, false]`; foreground only, presses prompts by keyboard shortcut |
| `WebKitPageTests.testDisplayCaptureFailsClosedWithoutTheCheckedWebKitDelegate` | Missing delegate, including blank frames |
| `PagePresenterTests`, `EngineBoundaryTests` | Block before prompt, display note, window-management storage and revocation |
| SDK smoke `display*`, `stopAllEndsDisplayCapture`, `windowManagement*` | ABI 19 request metadata, click-gated request, saved decisions answering quiet checks, reset, stored-nothing denial |
| `local full`, 2026-11-04 (`CHROMIUM.md`) | Real picker Cancel, real screen share and Stop, remembered decisions, revoke and block, stop-all, fullscreen events and window exit; one display, fake camera and microphone |

### Full build (manual)

0. Quit Cobble, then package and launch Full with the local SDK and runtime:
   `COBBLE_CHROMIUM_SDK_PATH=<chrome-sdk checkout> ./Scripts/run.sh local full`.
   This uses your normal Cobble profile. Afterwards, restore `Package.resolved`
   if the local SDK path rewrote it. On a Mac without a camera or microphone,
   step 1 gives `NotFoundError` before any prompt. Relaunch the packaged app
   with Chromium's fake devices:
   `open -n .context/Cobble.app --args --use-fake-device-for-media-stream`.
   Fake devices also replace the macOS picker with a synthetic window or
   screen, so check the picker in a normal launch.
1. Serve the fixture from `http://localhost`, which is a secure context:
   `python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Fixtures/PermissionFlow`.
   Then open `http://localhost:8765/` in a Chromium tab of `./Scripts/run.sh local full`.
2. Run steps 1–4 with the buttons. Check each prompt names
   `http://localhost:8765`.
3. In step 3, check the macOS picker opens and Cancel gives `NotAllowedError`.
4. Check that step 4 reports `entered`, `exited` and events `[true, false]`, and
   that the window leaves full screen too.
5. Turn off Window management in the site menu and rerun step 2. Cobble asks
   again. Block Screen sharing and rerun step 3: you get `NotAllowedError` with
   no prompt.
6. With camera and screen sharing both live, turn off Camera. **Live tracks**
   then reports none.

Real-site calls (Meet, Zoom, Teams), background tabs and navigation while the
picker is open still need manual qualification.
