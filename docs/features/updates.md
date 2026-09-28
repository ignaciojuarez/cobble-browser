# App updates

Sparkle 2.10.0 provides signed updates for **Full release builds**. GitHub hosts
the archives and [signed feed](../../updates/appcast.xml); no updater account,
server or paid service is needed. [The current Full beta](https://github.com/ignaciojuarez/cobble-browser/releases/tag/v0.1.0-beta.2)
is Developer ID-signed, Apple-notarized and stapled. Its public ZIP checksum and
signed feed were verified; the final exported app passed isolated Chromium smoke
checks. Beta 2 also passed an AppUpdater startup probe using the exported app’s
Sparkle framework and update configuration. **Beta 1 users must manually install
beta 2 once:** beta 1’s updater cannot start. Installed N → N+1 and clean-Mac
qualification remain open.

## In the app

- A quiet sidebar **Update available** button opens Sparkle’s native dialog.
  Downloaded updates use **Restart to update**; critical updates retain a prompt.
- **Cobble → Check for Updates…** and Settings → General → Updates are always
  reachable, even with the sidebar hidden.
- Sparkle asks permission for daily checks. Automatic installation is disabled;
  users choose when to install and restart. System-profile submission is disabled.
- Debug, tests, isolated fixtures and WebKit-only builds cannot start the updater.
  Full packaging must explicitly opt in with `--enable-updates`.
- Update the complete app, including its matched Chromium runtime and helpers.

`AppUpdater` is shared by all windows. Sparkle owns its dialogs, verification and
installer; Cobble observes its state through the supported Gentle Reminders API.
Only the Full Swift package links Sparkle; the Xcode WebKit target needs no updater
framework. Assembly embeds the framework and signs its nested helpers inside out.

Sparkle sends an ordinary Apple quit event and waits for process exit. The SDK’s
`DeferAppQuit` routes Chromium termination through Cobble’s existing download
confirmation, page-close preflight, durable save and engine shutdown. Canceling
or failing a save leaves the app running. No separate force-quit or restart path
is added. This source trace still needs the real installed-update test below.

## Signing setup (once)

Download the **2.10.0** tools from [Sparkle’s official release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0).
Keep the extracted `bin` directory at a stable local path:

```sh
export SPARKLE_BIN="/path/to/Sparkle/bin"
"$SPARKLE_BIN/generate_keys" --account com.ignacio.cobble.sparkle
```

The original key is already generated in the maintainer’s Mac Keychain. Its public
key is in `App/Info.plist`; the private key is never stored in this repository.
Approve macOS’s Keychain prompts locally. Securely back up that key using Sparkle’s
key-export instructions; losing it prevents signing updates for installed copies.
Contributors distributing forks must use their own key, bundle ID and feed URL.

Apple Developer ID Application signing and notarization are separate from Sparkle
signing. A development certificate alone does not qualify a public download.

## Repeatable release command

Requires Python 3.11+, Xcode, GitHub CLI (`gh auth login`), Sparkle 2.10.0 tools,
a matching prebuilt Chromium runtime, and a clean committed public checkout.
Sign into your developer team in Xcode first. The command uses that existing
sign-in for notarization; no separate notarization password/profile is required.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 Scripts/release.py build --version 0.1.0 --build 1 --tag v0.1.0-beta.1 \
  --team YOUR_TEAM_ID \
  --chromium /path/to/Chromium.app --tools "$SPARKLE_BIN" \
  --output /path/outside/repo/release-1 --notes /path/to/notes.md
```

This archives and Developer ID-signs the shell, packages Full, notarizes/staples,
and generates signed release assets. It does not compile Chromium or publish.
Apple processing is asynchronous. If Xcode reports that the archive is still
processing, resume without rebuilding or re-uploading:

```sh
python3 Scripts/release.py finish /path/outside/repo/release-1 --tools "$SPARKLE_BIN"
```

After the installation/update checks below, publish from the same source commit:

```sh
python3 Scripts/release.py publish /path/outside/repo/release-1/assets --tools "$SPARKLE_BIN"
```

Publishing checks signatures, checksums and the source commit, creates the GitHub
Release, verifies the public download, then commits/pushes the feed last. Existing
release assets are never overwritten. If publishing stops after creating a release,
inspect that release and finish feed publication only after verifying its bytes.
Build numbers must increase for every release. Keep signing keys backed up privately.

## Individual release steps

1. Increase Xcode’s `CURRENT_PROJECT_VERSION` to a new positive integer and set
   `MARKETING_VERSION`. Build the Release shell with Developer ID Application.
   Produce a Chromium runtime matching the pinned SDK and its native manifest.
2. Assemble Full with updates enabled:

   ```sh
   python3 Scripts/assemble_chromium.py /path/to/Chromium.app \
     --cobble-app /path/to/Release/Cobble.app \
     --configuration Release --enable-updates --output /path/to/staging/Cobble.app
   ```

3. Notarize and staple the assembled app. Run the distribution checks below.
   Prepare the ZIP, EdDSA signatures, checksum and feed in a new directory:

   ```sh
   python3 Scripts/prepare_update.py /path/to/staging/Cobble.app \
     --tools "$SPARKLE_BIN" --tag v0.1.0-beta.1 \
     --notes /path/to/release-notes.md --output /path/to/update-staging
   ```

   This checks the app identity, increasing build number, update key, signature,
   Gatekeeper and stapled notarization ticket. It never uploads anything. Start
   from the latest public checkout so the previous feed entries are preserved.
   Full ZIPs only; add deltas after measuring release size and download cost.

4. Upload the ZIP and `SHA256SUMS` to the **matching GitHub Release tag**. Download
   that public asset again and verify its checksum. Keep archives immutable.
5. Copy the generated `appcast.xml` to `updates/appcast.xml`, commit and push it
   **last**. Do not edit signed XML; regenerate it to change anything. Publishing
   the feed makes the release eligible for installed users. GitHub’s prerelease
   label does not hide an item from Sparkle.

The first installation needs a manual download containing Sparkle. The feed URL is
`https://raw.githubusercontent.com/ignaciojuarez/cobble-browser/main/updates/appcast.xml`.

## Qualification still required

- Installed, Developer ID-signed/notarized N → N+1 on a clean Mac: restart,
  Chromium, saved tabs/settings/cookies, and all old process exits.
- Canceled quit, active downloads, page-close cancellation and failed persistence.
- Invalid archive/feed signatures, offline/interrupted downloads, unsupported
  OS/architecture, insufficient disk space and installation permissions.
- Multiple/private windows, hidden sidebar, VoiceOver, contrast and localization.
- Public source/notices for shipped components, quarantine, and recovery without
  overwriting newer-schema data. Restoring unsaved forms is not guaranteed.

Local builds/tests do not close these release gates. See [ROADMAP](../../ROADMAP.md).

## References

[Sparkle setup](https://sparkle-project.org/documentation/),
[Gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/),
[publishing](https://sparkle-project.org/documentation/publishing/),
[installer quit event](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/InstallerProgress/InstallerProgressAppController.m).
