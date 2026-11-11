# Automation and AI agents

Cobble exposes normal-window tabs through its AppleScript dictionary
(`App/Cobble.sdef`). The bundled `cobble` script wraps that dictionary as JSON
commands and as an MCP server, so shell agents (Claude Code, Codex) and MCP
clients use the same native path. No port, token or extension is involved.

## Consent

| Layer | Grants | Default |
| --- | --- | --- |
| macOS Automation (TCC) | Which apps may send Cobble Apple Events | Asked on first use |
| Let Apps Control Tabs | List, open, select, navigate, reload, wait for and close tabs | On; turning it off refuses every app |
| Let Apps Read Pages | Page text, outlines, activity and screenshots | Off |
| Let Apps Use Pages | Click, fill, select, scroll and press keys in pages | Off; needs Read Pages |
| Private Sites | Hosts (and subdomains) apps can never read or use | Empty |

All switches live in Settings › Automation, on this Mac only, and are
never synced. A toggle in Cobble, not an Apple Event, enables page access, like
Safari's and Chrome's "Allow JavaScript from Apple Events".

## Agent space and the user's tabs

- `open tab … with agent space` opens in the profile's **Agents** space (🤖).
  Cobble creates it on first use, without an undo entry. Its ID derives from
  the profile ID, so synced Macs share one space, and a deleted Agents space
  returns on next use.
- The `cobble` tool and MCP server open new tabs there, in the background,
  by default. `--here` / `here` uses the current space; `--show` / `show`
  brings the tab to the front.
- Any tab ID from `list tabs` works wherever the tab lives, so an agent can
  use the tab the user is talking about.

## Seeing what apps do

- Tabs an app touched in the last 20 seconds show a pointer button in the
  sidebar (and "Used by an app" to VoiceOver). Clicking it turns all three
  switches off at once; the user turns them back on in Settings.
- Settings › Automation › Open Privacy Settings… shows which apps macOS lets
  control Cobble.

## Visibility

| Visible | Never visible |
| --- | --- |
| Normal windows, front to back; frontmost, selected tab, space, Agents space | Private windows and their tabs |
| Tab id, http(s) URL, title, space, selected, loaded, loading, engine, saved, audible, muted, busy | `file:`, `data:`, `about:` and credential URLs (shown empty) |
| Private Sites: origin only, `excluded` true | Their paths, titles, text and controls |
| With Read Pages: `innerText`, outline, errors, failed loads, request timing, viewport PNG | Form values, passwords, frames, cookies, history, downloads, raw DOM, console messages |

## What sites can tell

- **No user activation.** WebKit's public script calls run as a user gesture:
  the page's `navigator.userActivation` turns on and tracking prevention logs
  an interaction. Cobble's reads, actions and View Current DOM use WebKit's
  runtime-checked private calls without a gesture (matched by type encoding)
  and fail closed when they are missing. Chromium's isolated-world call has
  no gesture.
- **Actions look synthetic.** Events are untrusted (`isTrusted` false) and
  carry no ⌘, ⌃, ⌥ or ⇧ state, so Keyboard Privacy holds. Without activation,
  popups, full screen, clipboard writes and sound autoplay that need a click
  stay blocked; navigate the tab instead.
- **Reads run no page code.** Outlines, text and activity only read native
  DOM properties and Performance entries from the client world, never a
  page-supplied object, and add nothing to the page. A page cannot tell the
  error recorder exists.
- **Background agent tabs** sit outside any window: no native key or pointer
  events reach them, and they cannot show permission prompts, which need the
  tab on screen. They lay out at the window's page size, never a full-screen
  page's size.
- **Window titles** follow the selected tab (private windows stay "Cobble —
  Private"). The macOS screen-sharing picker shows them; sites only see a
  window the user picks there, and no display information comes from
  automation.

## Page outline and actions

`outline tab` walks the top document from WebKit's client script world and
lists visible headings, text blocks and controls, indented by landmark:

```text
navigation "Main":
  link "Docs" [ref=kqa3, to=/docs]
heading "Sign in" [level=1]
form:
  textbox "Email" [ref=kqa7, filled, required]
  textbox "Password" [ref=kqa8, password]
  combobox "Plan" [ref=kqa9, choice="Free"]
    option "Free" [selected]
  button "Continue" [ref=kqa10]
```

- Refs carry a random per-document prefix (`kqa` above) and keep their
  number for an element across outlines of the same document. Actions accept
  only refs from the latest outline of the current document; anything else
  asks for a new outline.
- While a modal dialog is open, the outline lists only the dialog. Actions on
  elements behind it, inside `inert` content or in a disabled fieldset are
  refused.
- Text fields report `[filled]`, never their values. Selects show the chosen
  label, which is on screen anyway.
- Open shadow roots and slots are followed. Frames appear as a placeholder.

`perform page action` takes `click`, `fill` (replaces text; optional
`submitting`), `select` (option label or value), `scroll` (a ref, or `up`,
`down`, `top`, `bottom`) and `press` (`Enter`, `Escape`, `Tab`, `Space`,
`Backspace`, `Delete`, `ArrowUp`/`ArrowDown`/`ArrowLeft`/`ArrowRight`, `Home`,
`End`, `PageUp`, `PageDown` or one character). It validates the
target first, then acts on the page's next task, so a page dialog cannot hold
the Apple Event open. Events are synthesized in the page, not system input:
`fill` types with `insertText` only when the field took focus (otherwise it
sets the value and fires `input`), so frameworks see normal input events; key
presses do not move focus or type by themselves.

Page scripts cannot see or replace the outline and action code: it runs in
the client world, receives values as data (never as script source), and keeps
refs in that world's globals.

## Activity

A client-world script records script errors, unhandled rejections, failed
resource loads and CSP blocks from document start (200 most recent). A
rejection's reason is recorded only when it is a string, number or other
primitive; objects show their type, because WebKit hands this world the
page's own object and reading it could run page code that reveals Cobble.
`read activity` adds the Performance API's navigation and resource entries
(status where WebKit reports it, type, duration, transfer size, URL).
Cobble's own favicon fetch can appear there. Console messages are not
captured: that would need a page-world hook pages could detect; use Web
Inspector for them.

## Behavior

- Tab ids are Cobble's stable tab UUIDs; `in window` is optional and defaults
  to the frontmost normal window.
- Background tabs load and lay out at the visible page's size, so outlines
  and screenshots work without showing them.
- Navigation, back, forward, reload, read, outline, actions and capture need
  a loaded tab. Unloaded tabs return "Select it first"; scripting never loads
  one silently.
- `wait for tab` returns when the page stops loading (default 30 s, at most
  60). After scripted navigation or an action it waits up to a second for
  loading to start, so it cannot return the previous page. The MCP tools wait
  after opening, navigating and acting.
- Mutations and actions are refused while a page shows a dialog, sheet, close
  confirmation or file action, or while its profile is being deleted.
- `load url` keeps the tab's engine. An address assigned to another engine is
  refused, because engine switches need the user's confirmation.
- Reads fail if the page navigates, the window becomes unusable, page access
  is turned off or the site becomes private before the result returns.
- Screenshots are at most 1600 px on the long edge.
- The native window title is the selected tab's title (private windows stay
  "Cobble — Private"); sidebar rows carry `tab-<id>` and `saved-<id>`
  accessibility identifiers that match Apple Event ids.

## Engines

| Capability | WebKit | Chromium |
| --- | --- | --- |
| Tabs, navigation, wait, screenshots | Yes | Yes |
| Page text | `innerText`, client world | Serialized DOM text: CSS-hidden text can appear |
| Outline, actions, activity | Yes | Not yet: needs an isolated-world script call in the Chromium SDK |

## Command line and MCP

```bash
COBBLE=/Applications/Cobble.app/Contents/Resources/cobble   # Settings › Automation › Copy Path
"$COBBLE" tabs
"$COBBLE" open https://example.com          # Agents space, background
"$COBBLE" wait TAB_ID
"$COBBLE" outline TAB_ID
"$COBBLE" fill TAB_ID kqa7 "ada@example.com" --submit
"$COBBLE" screenshot TAB_ID --out page.png
claude mcp add cobble -- "$COBBLE" mcp
```

MCP tools: `list_tabs`, `open_tab`, `select_tab`, `close_tab`,
`navigate_tab`, `wait_for_tab`, `read_tab`, `outline_tab`, `page_action`,
`page_activity`, `screenshot_tab`. The script targets the running
`com.ignacio.cobble` and does not launch Cobble. JXA reads terminology from
the Cobble app Launch Services registers, so an older copy can lack newer
commands.

## Qualification

Hosted tests cover records, routing, refusals, all switches, Private Sites,
the Agents space, the activity indicator, `wait`, typed Apple Event records
for synchronous commands, and the AppleScript terminology. Real-WebKit tests
cover the isolated text read, the outline (hidden text, values and page-script
spoofing excluded), click, select, fill with submit, stale refs, refs from an
earlier document, covered and disabled controls, error capture, background
screenshots, and that reads and actions never activate the page or run its
code. Asynchronous replies across processes need
Automation consent and remain a manual check, as do Chromium DOM text and the
Full build.
