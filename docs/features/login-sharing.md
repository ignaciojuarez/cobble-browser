# Experimental cross-engine login sharing

Default off. When a normal tab switches between WebKit and Chromium, Cobble can copy supported cookies for the destination HTTPS host before navigation. It does not transfer passwords, local storage, passkeys, or a whole browser profile. Website compatibility is unqualified.

## Behavior and limits

- Settings → General → Browser enables the experiment. Only the same normal profile participates; private contexts are excluded in the coordinator and both adapters.
- The destination is HTTPS on port 443. Domain and path matching include parent-domain cookies. A narrow Google group includes `google.com`, `accounts.google.com`, and `www.google.com` without broadening cookie scope. Other identity providers are not grouped.
- The source snapshot and destination scopes are checked before mutation. Empty source snapshots preserve destination cookies. Conflicts require an explicit **Replace Cookies** choice; **Keep Existing** is the default.
- Known partitioned cookies are omitted. Incomplete or ambiguous unpartitioned snapshots fail closed. WebKit may narrow ambiguous SameSite policies to `Lax`, which can prevent a login. Chromium uses the cookie bridge in the pinned ABI 16 SDK.
- Cookie writes are verified before obsolete cookies are removed. Live pages can still change sessions during a transfer, and already-started writes cannot be rolled back atomically. A failed write is surfaced; navigation proceeds and the site may ask for sign-in.
- OAuth-looking query markers skip transfer, but this heuristic cannot recognize every login flow. Server-side token rotation, local-storage-bound sessions, and device-bound credentials can invalidate a copied cookie.
- Disabling the setting stops new attempts. Sync and browser storage remain separate. No credential or transfer log is stored.

## Implementation and evidence

| Code | Role |
| --- | --- |
| `Engine/Contracts/EngineCookie.swift` | Transient cookie records and scope validation |
| `Browser/LoginSharing.swift`, `Browser/BrowserWindowModel.swift` | Opt-in, isolation, preflight, and engine-switch ordering |
| `Engine/WebKit/`, `Engine/Chromium/ChromiumEngine.swift` | Store conversion and native cookie operations |
| `Scripts/test_login_sharing.mjs` | Isolated real-engine authentication fixture |

The combined fixture passed **9/9** scenarios through real WebKit↔Chromium switches: opt-out, both directions, replacement consent, rotation, local and server logout, and a local-storage limit. It uses synthetic HttpOnly session/CSRF cookies and a local HTTPS proxy; no real account or normal browser profile. Results are in `.context/auth-preservation-run-final/result.json` and `server-checks.json`. Native ABI 16 cookie checks passed 4/4. These checks do not establish restart persistence or real-site compatibility.

To rerun with a matching Debug Full runtime, set `SDK_DIR`, `CHROMIUM_APP`, and `DEBUG_COBBLE_APP` to local paths, then:

```bash
COBBLE_AUTH_FIXTURE=1 COBBLE_CHROMIUM_SDK_PATH="$SDK_DIR" \
python3 Scripts/assemble_chromium.py "$CHROMIUM_APP" \
  --cobble-app "$DEBUG_COBBLE_APP" --configuration Debug \
  --output .context/login-sharing-fixture/Cobble.app

node Scripts/test_login_sharing.mjs \
  --app .context/login-sharing-fixture/Cobble.app \
  --artifacts .context/login-sharing-fixture-results
```

`COBBLE_AUTH_FIXTURE` is a compile-time Debug-only hook. The runner uses isolated storage, pins its local test certificate without changing system trust, redacts fixture credentials, and removes temporary storage. Do not distribute the fixture build.
