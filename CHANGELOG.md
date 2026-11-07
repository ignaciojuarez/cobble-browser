# Changelog

## Unreleased

- Chromium tabs run Chromium 157 (from 153), with its security fixes.
- Closing a Chromium private window while a download is running no longer
  crashes Cobble.
- Chromium no longer remembers a site as blocked after Cobble refuses one of
  its permission requests, and a site's second automatic download is no longer
  blocked for good.
- A prompt in a Chromium tab is no longer dismissed when an embedded frame
  (an ad or a sign-in widget) reloads.
- Chromium tabs no longer keep visited URLs in favicon or predictor databases;
  clearing all website data also removes older entries.
- Signing in with a passkey in a Chromium tab fails cleanly instead of risking
  a crash; Chromium tabs are no longer discarded under memory pressure.
- Find in a Chromium tab reports matches for the first search on each page.
- Deleting a profile now succeeds after its Chromium extensions or content
  rules were changed in Settings, and an unreadable Chromium content-rules file
  no longer stops every Chromium page from loading.
- Full no longer leaves a crash report after "Quit any other Cobble instance",
  and explains a Chromium runtime mismatch instead of crashing.
- HTML files opened from Finder, the Dock or File > Open File… now open in a
  WebKit tab with their styles, images and linked pages, even when Chromium is
  the default engine. They previously failed with "The page is closed."
- Pressing Return while a camera, microphone or screen-sharing prompt is open
  no longer allows it; click Allow or Window…. Esc still means Not Now.
- After a newer Cobble saved your session, an older build can still open pages
  in the default profile and quit normally; the newer session files stay untouched.
- Closing a Chromium tab that asks "Leave this page?" now shows that question
  instead of refusing to close, which also blocked Quit.
- A page can no longer stack download save sheets: each window shows one at a
  time and cancels other downloads that arrive meanwhile.
- Sidebar drags: dropping a pin onto itself keeps it in place, and favorites
  in a grid land in the row under the pointer.
- iCloud sync no longer stalls on a page with a very long title and keeps
  pins that don't sync, such as local files, in their place.
- Typing a `tel:` number opens the phone app instead of a website.
- The session saves at most every 2 seconds, so pages with ticking titles no
  longer rewrite it constantly. Quit still saves everything.
- Links opened in a new tab from a WebKit tab — ⌘-click, middle-click or
  Open Link in New Tab, including links that already open a new window —
  now use the new site's engine setting instead of copying the current tab's.
- Screen sharing works in WebKit and Chromium tabs. When a site asks, Cobble
  shows which site wants to see your screen; choose Window… or Screen…, then
  pick it in the macOS sharing picker. Cobble asks every time and notes when
  more than one display is connected. The site menu can stop sharing or block
  a site from asking. Chromium tabs share video only.
- Chromium tabs can ask to see your displays and place windows on them. Cobble
  asks with the site's name and remembers your answer like camera access; turn
  it off in the site menu or Settings.
- A Chromium page that leaves full screen right after entering no longer leaves
  its window stuck in full screen.
- Settings → Permissions now shows whether passkeys can work: not yet
  allowed, turned off (with a button to open System Settings), no passkey
  provider on this Mac, or ready. It also no longer suggests that a future
  Apple approval will bring Apple Passwords AutoFill to WebKit pages.
- New Keyboard Privacy setting (Settings → Browsing): websites no longer see
  ⌘ or ⌃ keys, in WebKit and Chromium tabs and in page full screen — not even
  held while typing other keys, moving the pointer or scrolling. Clicks still
  report them so ⌘-click and ⌃-click work. Cobble shortcuts, copy/paste and
  text editing keys such as ⌘← or ⌃A keep working; site shortcuts such as ⌘K
  stop. Off by default.
- Clicking Cobble in the Dock brings back your window — even when it's
  minimized or still opening — instead of adding a second one. New windows
  open only from New Window: ⌘N, the File menu, or the Dock icon's menu
  (right-click). ⌘T from Settings opens the tab in your existing window.
- The site menu is simpler: connection status at the top (click it for the
  certificate), then on/off switches for Camera, Microphone, Sound and
  Pop-ups. Allowing camera or microphone now always remembers the site, so
  the switch stays on until you turn it off. Turning it off also stops the
  camera or microphone on that page. Works in WebKit and Chromium tabs.
- Video and page full screen works in Chromium tabs. YouTube and other sites
  open in their own full-screen Space with a brief “Press Esc to exit” banner;
  Esc, the site's own button or leaving the Space returns the page to its tab.
- A crashed Chromium page no longer quits the whole browser.
- Right-click menus work on images and links. In WebKit, Download Image and
  Download Linked File now save the file, and “Open … in New Tab” opens a
  background tab. Chromium pages now show a right-click menu; Copy Image no
  longer crashes, and items that need Chrome windows or panels are hidden.
- Engine choice is one per-website setting — Automatic, WebKit or Chromium — from
  the site menu, the tab's engine menu or Settings → General → Web Engine,
  which also holds this Mac's default. Website choices now cover subdomains, so
  `figma.com` also applies to `www.figma.com`. Declining the reload keeps the previous choice.

## 0.1.0-beta.6 — 2026-10-14

- Preserve inherited local runner settings so worktrees show the configured
  remote Mac and retain signing and Xcode choices.
- Smooth space swiping with lazy rows, isolated sidebar movement, and no
  inactive drop geometry. Follow gesture distance directly and draw the settled
  sidebar before starting destination pages, keeping cold page creation out of
  the visible slide. Reveal already-open tabs immediately on release while the
  sidebar finishes settling, preserving their live page and unsaved state.

## 2026-10-02

- Support explicit development SDK ABI 18 for Chromium navigation failures,
  loading progress and renderer responsiveness; retain the matched public ABI 17 pin.
- Expose engine-neutral loading progress, including WebKit's native estimate.
- Remove obsolete default-browser callback code and clear native-client Swift build warnings.

## 2026-10-01

- Require complete content review before commits/publishing, including new files and screenshots; keep personal browsing material outside public source.
- Unified development in the public app and Chrome SDK repositories, retaining signed update/release tooling.
- Adopted SDK ABI 17 for Chromium background-tab gestures; Command-click/middle-click stay in the background and address modifiers open new tabs.
- Kept the selected space when closing its last tab and rejected stale native focus callbacks.

Changes after the initial public source snapshot will be recorded here.
Implementation status is in [FEATURES.md](FEATURES.md); release gates are in
[ROADMAP.md](ROADMAP.md).

## Unreleased

- Enable H.264/AAC in the Chromium runtime so social-site MP4 videos and streams
  can load. Pin the matching ABI 18 SDK and check codec support in the Full smoke test.
- Park keyboard focus when switching to a space with no loaded tabs, preventing
  automatic sidebar search focus after leaving a Chromium page.
- Use Command-Shift-R for Force Reload, preserving cookies and website data.
- Fill the site-controls action row and collapse certificate details behind one
  counted button; match security and page-action control heights.
- Show native download file icons, use translucent white browser separators,
  and place disclosure chevrons immediately after folder titles.
- Enable automatic daily update checks by default for new installs. Available
  updates appear in the sidebar; existing opt-out choices remain respected.

## 0.1.0-beta.2 — 2026-09-28

- Fix Sparkle startup by enabling verification before extraction, required by
  signed feeds. Beta 1 users need a manual replacement download; its updater
  cannot start. Release staging now rejects this invalid configuration.
- Show an updater startup failure without incorrectly describing a Full release
  as a development build.

## 0.1.0-beta.1 — 2026-09-27

- First public Full download for Apple silicon/macOS 26+, including Chromium.
  Developer ID-signed, notarized and stapled; final exported app smoke-tested.

- Repeatable local Full release command for Developer ID signing, notarization,
  GitHub uploads and verified feed publication.

- Sparkle updates for opted-in Full release builds: sidebar reminder, Settings and
  menu controls, signed GitHub feed, framework packaging and release staging.
  Signed installed-update qualification remains open.

## Initial public source

- Native AppKit windows and SwiftUI browser chrome for macOS 26+.
- Spaces, favorites, pins, nested folders, profiles and independent window tabs.
- WebKit browser and optional Chromium integration through the separate SDK.
- Versioned sessions, recovery, local history/bookmarks and import/export.
- Downloads, per-site permissions, content blockers and experimental extensions.
- Native themes, configurable shortcuts, English and Spanish UI.
- Optional iCloud record sync and experimental cross-engine cookie sharing.
- Public source, build instructions and GPLv3 licensing for original code.

This is a development source release. Apple credential integration, installed-upgrade testing, daily-use and
compatibility qualification remain open; source availability does not imply production readiness.
