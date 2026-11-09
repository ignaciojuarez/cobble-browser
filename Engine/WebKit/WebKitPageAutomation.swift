import WebKit

/// Page outline, actions and activity for automation. Every script runs in WebKit's client world, so pages
/// cannot see or replace it; element refs live in that world's globals and die with the document.
extension WebKitPage {
    func pageOutline(limit: Int) async throws -> (text: String, truncated: Bool) {
        try Self.textPair(await callClientScript(WebKitPageAutomation.prelude + WebKitPageAutomation.outline,
                                                 arguments: ["limit": max(0, limit)]))
    }

    func perform(_ action: PageAction) async throws -> String {
        // Actions may navigate, so the page identity is not rechecked; the action already happened.
        let result = try await callClientScript(WebKitPageAutomation.prelude + WebKitPageAutomation.act, arguments: [
            "kind": action.kind.rawValue, "ref": action.ref ?? "", "value": action.value ?? "", "submit": action.submit,
        ], requireSamePage: false)
        guard let pair = result as? [Any], pair.count == 2, let status = pair[0] as? String, let detail = pair[1] as? String else {
            throw EngineError.notReady(String(localized: "WebKit did not return the action result."))
        }
        switch status {
        case "ok": return detail
        case "stale": throw PageActionError.staleReference
        case "disabled": throw PageActionError.disabled
        case "blocked": throw PageActionError.blocked
        case "option": throw PageActionError.noMatchingOption(action.value ?? "")
        default: throw PageActionError.notApplicable
        }
    }

    func pageActivity(limit: Int) async throws -> (text: String, truncated: Bool) {
        try Self.textPair(await callClientScript(WebKitPageAutomation.prelude + WebKitPageAutomation.activity,
                                                 arguments: ["limit": max(0, limit)]))
    }

    private static func textPair(_ result: Any?) throws -> (text: String, truncated: Bool) {
        guard let pair = result as? [Any], pair.count == 2, let text = pair[0] as? String, let truncated = pair[1] as? Bool else {
            throw EngineError.notReady(String(localized: "WebKit did not return the page text."))
        }
        return (text, truncated)
    }
}

enum WebKitPageAutomation {
    private typealias Completion = @convention(block) (Any?, Error?) -> Void
    private typealias CallWithGesture = @convention(c) (WKWebView, Selector, NSString, NSDictionary, WKFrameInfo?,
                                                        WKContentWorld, ObjCBool, Completion) -> Void
    private typealias EvaluateWithGesture = @convention(c) (WKWebView, Selector, NSString, ObjCBool, NSURL?, NSDictionary,
                                                            ObjCBool, WKFrameInfo?, WKContentWorld, Completion) -> Void
    private nonisolated(unsafe) static let callSelector =
        NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")
    private nonisolated(unsafe) static let evaluateSelector = NSSelectorFromString(
        "_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")

    /// WebKit's public script calls run as a user gesture: the site sees `navigator.userActivation` turn on and
    /// tracking prevention records a visit the user never made. Cobble's reads and actions use WebKit's runtime-checked
    /// private calls without one, matched by type encoding, and fail closed when neither exists.
    @MainActor
    static func callWithoutUserGesture(_ view: WKWebView, body: String, arguments: [String: Any]) async throws -> Any? {
        func implementation(_ selector: Selector, _ encoding: String) -> IMP? {
            guard let method = class_getInstanceMethod(WKWebView.self, selector), let types = method_getTypeEncoding(method),
                  String(cString: types).filter({ !$0.isNumber }) == encoding else { return nil }
            return method_getImplementation(method)
        }
        let call = implementation(callSelector, "v@:@@@@B@?")
        let evaluate = call == nil ? implementation(evaluateSelector, "v@:@B@@B@@@?") : nil
        guard call != nil || evaluate != nil else {
            throw EngineError.unsupported(String(localized: "app access to pages on this version of macOS"))
        }
        // WebKit replies once, on the main thread.
        nonisolated(unsafe) var reply: Any?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: Completion = { result, error in
                if let error { continuation.resume(throwing: error) } else { reply = result; continuation.resume() }
            }
            if let call {
                unsafeBitCast(call, to: CallWithGesture.self)(view, callSelector, body as NSString, arguments as NSDictionary,
                                                             nil, .defaultClient, false, done)
            } else if let evaluate {
                unsafeBitCast(evaluate, to: EvaluateWithGesture.self)(view, evaluateSelector, body as NSString, true, nil,
                                                                     arguments as NSDictionary, false, nil, .defaultClient, done)
            }
        }
        return reply
    }

    /// Shared state and helpers. `C.log` is filled from document start by `activityScript`.
    static let prelude = #"""
        const C = globalThis.__cobbleAutomation ??= { log: [] };
        C.ids ??= new WeakMap(); C.els ??= new Map(); C.next ??= 0;
        // Refs carry a random per-document tag, so a ref from an earlier page never matches an element on this one.
        C.tag ??= Array.from(crypto.getRandomValues(new Uint8Array(3)), b => 'abcdefghijkmnpqrstuvwxyz'[b % 24]).join('');
        const clean = s => String(s ?? '').replace(/\s+/g, ' ').trim();
        const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
        const quote = (s, n = 120) => JSON.stringify(cut(clean(s), n));
        const TEXT = new Set(['textbox', 'searchbox', 'combobox', 'listbox', 'spinbutton', 'slider']);
        // innerText of an element that is not rendered falls back to textContent, which includes hidden text and scripts.
        const rendered = el => el.getClientRects().length ? el.innerText : '';
        const disabled = el => el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true';
        const role = el => {
          const tag = el.localName;
          const explicit = clean(el.getAttribute('role')).split(' ')[0];
          // Form controls and editors keep their own role, so their default text is never walked as page text.
          if (tag === 'select') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
          if (tag === 'textarea') return 'textbox';
          if (tag === 'input') {
            const type = (el.type || 'text').toLowerCase();
            if (type === 'hidden') return '';
            if (['button', 'submit', 'reset', 'image', 'file'].includes(type)) return 'button';
            if (type === 'checkbox' || type === 'radio') return type;
            if (type === 'range') return 'slider';
            if (type === 'number') return 'spinbutton';
            return type === 'search' ? 'searchbox' : 'textbox';
          }
          if (el.isContentEditable && !el.parentElement?.isContentEditable) return TEXT.has(explicit) ? explicit : 'textbox';
          if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
          if (tag === 'a' || tag === 'area') return el.hasAttribute('href') ? 'link' : '';
          if (tag === 'button' || tag === 'summary') return 'button';
          if (/^h[1-6]$/.test(tag)) return 'heading';
          if (tag === 'img') return clean(el.alt) ? 'img' : '';
          const landmarks = { nav: 'navigation', main: 'main', form: 'form', dialog: 'dialog', aside: 'complementary', search: 'search' };
          if (landmarks[tag]) return landmarks[tag];
          if (el.hasAttribute('onclick') || (el.tabIndex >= 0 && el.hasAttribute('tabindex'))) return 'clickable';
          return '';
        };
        const name = (el, r) => {
          const aria = clean(el.getAttribute('aria-label'));
          if (aria) return aria;
          const by = el.getAttribute('aria-labelledby');
          if (by) {
            const text = clean(by.split(/\s+/).map(id => document.getElementById(id)?.textContent || '').join(' '));
            if (text) return text;
          }
          if (el.labels?.length) {
            const text = clean([...el.labels].map(rendered).join(' '));
            if (text) return text;
          }
          if (clean(el.alt)) return clean(el.alt);
          if (el.localName === 'input' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value) || el.type;
          if (TEXT.has(r) && clean(el.placeholder)) return clean(el.placeholder);
          if (!TEXT.has(r)) {
            const text = clean(rendered(el));
            if (text) return text;
          }
          if (clean(el.title)) return clean(el.title);
          return clean(el.querySelector?.('img[alt]')?.alt);
        };
        const target = ref => {
          const el = ref ? C.els.get(ref)?.deref() : null;
          return el && el.isConnected ? el : null;
        };
        const describe = el => { const r = role(el) || el.localName; return `${r} ${quote(name(el, r))}`; };
        let modal = null;
        try { modal = document.querySelector(':modal'); } catch (_) {}
        // Ancestors across shadow roots.
        const within = (el, outer) => { for (let n = el; n; n = n.parentNode || n.host) if (n === outer) return true; return false; };
        const blocked = el => {
          for (let n = el; n; n = n.parentNode || n.host) if (n.inert) return true;
          return Boolean(modal && !within(el, modal));
        };
        const focused = () => { let a = document.activeElement; while (a?.shadowRoot?.activeElement) a = a.shadowRoot.activeElement; return a; };
        """#

    static let outline = #"""
        const lines = [];
        let size = 0, truncated = false, budget = 50000, pending = '';
        C.els = new Map();
        const emit = (depth, text) => {
          if (truncated) return;
          const line = '  '.repeat(depth) + text;
          if (size + line.length + 1 > limit) { truncated = true; return; }
          lines.push(line); size += line.length + 1;
        };
        const flush = depth => { const text = clean(pending); pending = ''; if (text) emit(depth, 'text ' + quote(text, 300)); };
        const ref = el => {
          let id = C.ids.get(el);
          if (!id) { id = C.tag + (++C.next); C.ids.set(el, id); }
          C.els.set(id, new WeakRef(el));
          return id;
        };
        const shown = el => {
          if (el.checkVisibility && el.checkVisibility({ checkVisibilityCSS: true, visibilityProperty: true })) return true;
          if (el.checkVisibility) return getComputedStyle(el).display === 'contents';
          return el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
        };
        const states = (el, r) => {
          const out = [];
          if (disabled(el)) out.push('disabled');
          if (r === 'heading') out.push('level=' + (el.getAttribute('aria-level') || (/^h[1-6]$/.test(el.localName) ? el.localName[1] : 2)));
          const checked = el.localName === 'input' ? el.checked : el.getAttribute('aria-checked') === 'true';
          if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(r) && checked) out.push('checked');
          const expanded = el.getAttribute('aria-expanded');
          if (expanded) out.push(expanded === 'true' ? 'expanded' : 'collapsed');
          if (el.getAttribute('aria-selected') === 'true') out.push('selected');
          const current = el.getAttribute('aria-current');
          if (current && current !== 'false') out.push('current');
          if (['textbox', 'searchbox', 'spinbutton'].includes(r)) {
            if (el.type === 'password') out.push('password');
            if (clean('value' in el ? el.value : el.innerText)) out.push('filled');
            if (el.required) out.push('required');
          }
          if (document.activeElement === el) out.push('focused');
          if (el.localName === 'select' && !el.multiple && el.selectedOptions?.[0]) {
            out.push('choice=' + quote(el.selectedOptions[0].label));
          }
          if (r === 'link' && typeof el.href === 'string' && el.href) {
            try {
              const url = new URL(el.href, location.href);
              out.push('to=' + cut(url.origin === location.origin ? url.pathname + url.search : url.href, 160));
            } catch (_) {}
          }
          return out;
        };
        const tags = list => list.length ? ' [' + list.join(', ') + ']' : '';
        const INTERACTIVE = new Set(['link', 'button', 'checkbox', 'radio', 'textbox', 'searchbox', 'combobox', 'listbox',
          'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem', 'clickable']);
        const LANDMARKS = new Set(['navigation', 'main', 'form', 'dialog', 'alertdialog', 'complementary', 'search', 'region',
          'banner', 'contentinfo', 'alert', 'status', 'menu', 'menubar', 'tablist', 'toolbar', 'radiogroup', 'tree', 'grid']);
        const BLOCK = /^(address|article|aside|blockquote|br|dd|details|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul)$/;
        const SKIP = /^(script|style|noscript|template|head|meta|link|svg|canvas|object|embed|audio|video|datalist)$/;
        const kids = node => {
          if (node.localName === 'slot') {
            const assigned = node.assignedNodes({ flatten: true });
            return assigned.length ? assigned : node.childNodes;
          }
          return (node.shadowRoot || node).childNodes;
        };
        const walk = (node, depth) => {
          for (const child of kids(node)) {
            if (truncated || budget-- <= 0) { truncated = true; return; }
            if (child.nodeType === 3) { pending += child.data; continue; }
            if (child.nodeType !== 1) continue;
            const el = child, tag = el.localName;
            if (SKIP.test(tag) || el.inert || el.getAttribute('aria-hidden') === 'true' || !shown(el)) continue;
            const r = role(el);
            const block = BLOCK.test(tag) || Boolean(r);
            if (block) flush(depth);
            if (tag === 'iframe' || tag === 'frame') { emit(depth, 'frame (contents not included)'); continue; }
            if (r === 'heading' || r === 'img') { emit(depth, r + ' ' + quote(name(el, r)) + tags(states(el, r))); continue; }
            if (INTERACTIVE.has(r)) {
              emit(depth, r + ' ' + quote(name(el, r)) + tags(['ref=' + ref(el), ...states(el, r)]));
              if (tag === 'select') {
                let count = 0;
                for (const option of el.options) {
                  if (count++ >= 25) { emit(depth + 1, `… ${el.options.length - 25} more options`); break; }
                  emit(depth + 1, 'option ' + quote(option.label) + (option.selected ? ' [selected]' : ''));
                }
              }
              continue;
            }
            const landmark = LANDMARKS.has(r);
            const inner = landmark ? depth + 1 : depth;
            if (landmark) emit(depth, r + (clean(el.getAttribute('aria-label')) ? ' ' + quote(el.getAttribute('aria-label')) : '') + ':');
            walk(el, inner);
            if (block) flush(inner);
          }
        };
        // An open modal dialog makes the rest of the page inert, so only the dialog is listed.
        const root = modal || document.body || document.documentElement;
        if (modal) emit(0, 'modal dialog' + (clean(modal.getAttribute('aria-label')) ? ' ' + quote(modal.getAttribute('aria-label')) : '') + ':');
        if (root) { walk(root, modal ? 1 : 0); flush(modal ? 1 : 0); }
        return [lines.join('\n'), truncated];
        """#

    /// Validates synchronously, then acts on the next task so a page dialog cannot hold the reply open.
    static let act = #"""
        const later = work => { setTimeout(() => { try { work(); } catch (_) {} }, 0); };
        const editable = el => el.isContentEditable || el.localName === 'textarea' ||
          (el.localName === 'input' && !['button', 'submit', 'reset', 'image', 'file', 'checkbox', 'radio', 'range', 'color', 'hidden'].includes((el.type || 'text').toLowerCase()));
        const KEYS = { Enter: [13, 'Enter'], Escape: [27, 'Escape'], Tab: [9, 'Tab'], Backspace: [8, 'Backspace'],
          Delete: [46, 'Delete'], ArrowUp: [38, 'ArrowUp'], ArrowDown: [40, 'ArrowDown'], ArrowLeft: [37, 'ArrowLeft'],
          ArrowRight: [39, 'ArrowRight'], PageUp: [33, 'PageUp'], PageDown: [34, 'PageDown'], Home: [36, 'Home'], End: [35, 'End'],
          ' ': [32, 'Space'] };
        // [key, keyCode, code], or null. Modifier keys are never sent, so pages never see ⌘ or ⌃ from Cobble.
        const keyInfo = raw => {
          const key = raw === 'Space' ? ' ' : raw;
          if (Object.hasOwn(KEYS, key)) return [key, ...KEYS[key]];
          if ([...key].length !== 1) return null;
          const code = /^[a-z]$/i.test(key) ? 'Key' + key.toUpperCase() : /^[0-9]$/.test(key) ? 'Digit' + key : '';
          return [key, key.toUpperCase().charCodeAt(0), code];
        };
        const press = (el, raw) => {
          const [key, keyCode, code] = keyInfo(raw);
          const init = { key, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true };
          const proceed = el.dispatchEvent(new KeyboardEvent('keydown', init));
          if (key === 'Enter' && proceed && el.form && el.localName === 'input') el.form.requestSubmit();
          el.dispatchEvent(new KeyboardEvent('keyup', init));
        };
        if (kind === 'scroll' && !ref) {
          const pages = { up: -0.8, down: 0.8 }[value || 'down'];
          const scroller = document.scrollingElement || document.documentElement;
          if (value === 'top') scroller.scrollTop = 0;
          else if (value === 'bottom') scroller.scrollTop = scroller.scrollHeight;
          else if (pages) scroller.scrollBy({ top: innerHeight * pages, behavior: 'instant' });
          else return ['invalid', ''];
          return ['ok', `Scrolled ${value || 'down'} to ${Math.round(scroller.scrollTop)} of ${Math.max(0, scroller.scrollHeight - innerHeight)}`];
        }
        if (kind === 'press' && !ref) {
          if (!keyInfo(value)) return ['invalid', ''];
          const el = focused() || document.body;
          later(() => press(el, value));
          return ['ok', `Pressed ${value}`];
        }
        const el = target(ref);
        if (!el) return ['stale', ''];
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        if (kind === 'scroll') return ['ok', 'Scrolled to ' + describe(el)];
        if (disabled(el)) return ['disabled', ''];
        if (blocked(el)) return ['blocked', ''];
        if (kind === 'click') {
          later(() => {
            const box = el.getBoundingClientRect();
            const at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                         clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
            const pointer = { ...at, pointerId: 1, pointerType: 'mouse', isPrimary: true };
            el.dispatchEvent(new PointerEvent('pointerdown', { ...pointer, buttons: 1 }));
            el.dispatchEvent(new MouseEvent('mousedown', { ...at, buttons: 1 }));
            el.focus?.({ preventScroll: true });
            el.dispatchEvent(new PointerEvent('pointerup', pointer));
            el.dispatchEvent(new MouseEvent('mouseup', at));
            el.click();
          });
          return ['ok', 'Clicked ' + describe(el)];
        }
        if (kind === 'fill') {
          if (!editable(el) || el.readOnly) return ['invalid', ''];
          later(() => {
            el.focus({ preventScroll: true });
            // Typing goes to whatever has focus, so it is used only when the field really took focus.
            let typed = false;
            if (focused() === el) {
              if (el.isContentEditable) {
                const range = document.createRange();
                range.selectNodeContents(el);
                getSelection().removeAllRanges(); getSelection().addRange(range);
              } else { try { el.select(); } catch (_) {} }
              typed = value ? document.execCommand('insertText', false, value) : document.execCommand('delete', false);
            }
            if (!typed) {
              if (el.isContentEditable) el.textContent = value;
              else Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set.call(el, value);
              el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
            }
            el.dispatchEvent(new Event('change', { bubbles: true }));
            if (submit) press(el, 'Enter');
          });
          return ['ok', 'Filled ' + describe(el) + (submit ? ' and submitted' : '')];
        }
        if (kind === 'select') {
          if (el.localName !== 'select') return ['invalid', ''];
          const wanted = clean(value).toLowerCase();
          const option = [...el.options].find(o => o.value === value) ||
            [...el.options].find(o => clean(o.label).toLowerCase() === wanted);
          if (!option) return ['option', ''];
          if (option.disabled) return ['disabled', ''];
          later(() => {
            el.focus({ preventScroll: true });
            option.selected = true;
            el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          });
          return ['ok', `Chose ${quote(option.label)} in ${describe(el)}`];
        }
        if (kind === 'press') {
          if (!keyInfo(value)) return ['invalid', ''];
          later(() => { el.focus?.({ preventScroll: true }); press(el, value); });
          return ['ok', `Pressed ${value} on ${describe(el)}`];
        }
        return ['invalid', ''];
        """#

    static let activity = #"""
        const lines = [];
        let size = 0, truncated = false;
        const emit = line => {
          if (truncated) return;
          if (size + line.length + 1 > limit) { truncated = true; return; }
          lines.push(line); size += line.length + 1;
        };
        const at = time => '+' + Math.max(0, Math.round(time)) + 'ms';
        emit('Errors and failed loads:');
        if (!C.log.length) emit('  none');
        for (const [time, kind, text] of C.log) emit(`  ${at(time - performance.timeOrigin)} ${kind} ${text}`);
        const requests = performance.getEntriesByType('navigation').concat(performance.getEntriesByType('resource'));
        emit(`Requests (${requests.length}, newest last):`);
        for (const entry of requests.slice(-200)) {
          const status = entry.responseStatus ? String(entry.responseStatus) : '-';
          const bytes = entry.transferSize ? (entry.transferSize / 1024).toFixed(1) + 'KB' : (entry.decodedBodySize ? 'cached' : '-');
          emit(`  ${at(entry.startTime)} ${status} ${entry.initiatorType || entry.entryType} ${Math.round(entry.duration)}ms ${bytes} ${cut(entry.name, 300)}`);
        }
        return [lines.join('\n'), truncated];
        """#

    /// Records script errors and failed loads from document start. Read only through `pageActivity`.
    @MainActor static let activityScript = WKUserScript(source: #"""
        (() => {
          const C = globalThis.__cobbleAutomation ??= {};
          const log = C.log = [];
          const add = (kind, text) => { log.push([Date.now(), kind, String(text).slice(0, 1000)]); if (log.length > 200) log.shift(); };
          addEventListener('error', event => {
            const node = event.target;
            if (node && node !== window && node.localName) {
              add('failed', `${node.localName} ${node.currentSrc || node.src || node.href || ''}`);
            } else {
              add('error', (event.message || 'Script error') + (event.filename ? ` (${event.filename}:${event.lineno}:${event.colno})` : ''));
            }
          }, true);
          // WebKit hands this world the page's own reason object. Reading it could run a page getter or Proxy
          // trap and reveal this listener, so only primitives are recorded.
          addEventListener('unhandledrejection', event => {
            const value = event.reason, type = typeof value;
            add('error', 'Unhandled rejection: ' + (value === null || (type !== 'object' && type !== 'function') ? String(value) : `(${type})`));
          });
          addEventListener('securitypolicyviolation', event => add('blocked', `${event.violatedDirective} ${event.blockedURI}`));
        })();
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
}
