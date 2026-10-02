# Changelog

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
