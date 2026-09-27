# Per-site browser identity

Settings → Browsing → Site Rules provides exact-origin, per-profile rules for Default, Android Phone, Android Tablet, iPhone, and iPad. Rules apply on navigation or reload. Private contexts read saved rules without persisting private activity; Default restores native identity.

| Area | Current implementation |
| --- | --- |
| Shared storage | `SiteSettingsStore.browserIdentity(for:profileID:)`; version 3 migration keeps older records on native identity |
| WebKit | Public `WKWebView.customUserAgent` before top-level navigation |
| Chromium | Pinned ABI 16 resolver before page creation; native User-Agent and Client Hints |
| Popups | Native child pages inherit opener policy before their first HTTP(S) request |

The preset changes identity strings, not viewport, zoom, touch hardware, `navigator.platform`, or rendering engine. Committed non-HTTP(S) pages return to native identity. iOS presets suppress UA hints, though Chromium's `userAgentData` interface may remain with empty values. Shared/service workers retain native Chromium identity; dedicated workers and document subresources inherit the page override. Extensions that rewrite HTTP User-Agent can diverge from JavaScript identity.

Chromium's SDK fixture passed **44/44** checks across first navigation, redirects, links/forms/scripts, reload/history, rules, profiles/private contexts, popups, iframes, and geometry. WebKit fixtures cover first request/JavaScript, cross-origin links, history, edited-rule reload, and redirect reset. A 307/308 redirect preserves the original POST body. Real-site compatibility remains unqualified; see [CHROMIUM.md](../../CHROMIUM.md) for the current SDK pin and build evidence.
