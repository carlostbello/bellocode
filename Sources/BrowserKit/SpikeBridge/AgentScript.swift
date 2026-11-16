// SPIKE (gate G3). JavaScript injected into every frame. The agent script runs in an isolated WKContentWorld, so
// page scripts cannot see or replace `window.__bc`; it shares the DOM with the page. The console hook must run in the
// page world to wrap the page's own `console`, so pages can see and spoof it: its entries are untrusted.

enum AgentScript {
    static let worldName = "bellocode.agent"
    static let agentHandler = "bcAgent"
    static let consoleHandler = "bcConsole"

    static let source = #"""
    (() => {
      if (window.__bc) return;
      const post = (message) => { try { window.webkit.messageHandlers.bcAgent.postMessage(message); } catch (_) {} };
      const frameId = 'frame_' + (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));
      let refs = new Map();
      const squash = (value) => String(value ?? '').replace(/\s+/g, ' ').trim();
      const INTERACTIVE = new Set(['button', 'link', 'textbox', 'searchbox', 'combobox', 'listbox', 'checkbox', 'radio',
        'option', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'treeitem']);
      const NAME_FROM_CONTENT = new Set(['button', 'link', 'heading', 'option', 'cell', 'columnheader', 'rowheader', 'tab',
        'menuitem', 'treeitem', 'paragraph', 'LabelText', 'legend', 'StaticText', 'switch']);
      const INPUT_ROLES = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
        image: 'button', file: 'button', range: 'slider', search: 'searchbox', number: 'spinbutton', color: 'button' };
      const TAG_ROLES = { button: 'button', summary: 'button', textarea: 'textbox', option: 'option', nav: 'navigation',
        main: 'main', header: 'banner', footer: 'contentinfo', aside: 'complementary', form: 'form', ul: 'list', ol: 'list',
        menu: 'list', li: 'listitem', table: 'table', tr: 'row', td: 'cell', th: 'columnheader', p: 'paragraph',
        dialog: 'dialog', iframe: 'Iframe', frame: 'Iframe', fieldset: 'group', details: 'group', progress: 'progressbar',
        meter: 'meter', label: 'LabelText', legend: 'legend', hr: 'separator', h1: 'heading', h2: 'heading', h3: 'heading',
        h4: 'heading', h5: 'heading', h6: 'heading', article: 'article', blockquote: 'blockquote', video: 'video', audio: 'audio' };
      const SKIP = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'title', 'base']);

      // Text of a subtree including open shadow roots and slotted content (innerText ignores shadow DOM).
      function composedText(node, out = []) {
        if (out.length > 400) return out;
        if (node.nodeType === 3) { out.push(node.data); return out; }
        if (node.nodeType !== 1 && node.nodeType !== 11) return out;
        if (node.nodeType === 1) {
          if (SKIP.has(node.localName)) return out;
          if (node.localName === 'input' || node.localName === 'select' || node.localName === 'textarea') return out;
          const style = getComputedStyle(node);
          if (style.display === 'none') return out;
        }
        for (const child of children(node)) composedText(child, out);
        return out;
      }
      function children(node) {
        if (node.nodeType === 1 && node.shadowRoot) return node.shadowRoot.childNodes;
        if (node.nodeType === 1 && node.localName === 'slot') {
          const assigned = node.assignedNodes({ flatten: true });
          return assigned.length ? assigned : node.childNodes;
        }
        return node.childNodes;
      }
      function roleOf(el) {
        const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
        if (explicit === 'presentation' || explicit === 'none') return null;
        if (explicit) return explicit;
        const tag = el.localName;
        if (tag === 'a' || tag === 'area') return el.hasAttribute('href') ? 'link' : null;
        if (tag === 'input') {
          const type = (el.getAttribute('type') || 'text').toLowerCase();
          if (type === 'hidden') return null;
          return INPUT_ROLES[type] || (el.hasAttribute('list') ? 'combobox' : 'textbox');
        }
        if (tag === 'select') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
        if (tag === 'img') return el.getAttribute('alt') === '' ? null : 'img';
        if (tag === 'section') return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
        if (TAG_ROLES[tag]) return TAG_ROLES[tag];
        if (el.isContentEditable && el.hasAttribute('contenteditable')) return 'textbox';
        return null;
      }
      function labelText(label) {
        const clone = label.cloneNode(true);
        clone.querySelectorAll('input,select,textarea,button').forEach((node) => node.remove());
        return squash(clone.textContent);
      }
      function nameOf(el, role) {
        const root = el.getRootNode();
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
          const text = labelledBy.split(/\s+/).map((id) => (root.getElementById ? root.getElementById(id) : document.getElementById(id)))
            .filter(Boolean).map((node) => squash(composedText(node).join(' '))).join(' ');
          if (text) return text;
        }
        const label = el.getAttribute('aria-label');
        if (label && label.trim()) return squash(label);
        const tag = el.localName;
        if (tag === 'input' && ['submit', 'button', 'reset'].includes(el.type)) return squash(el.value || (el.type === 'reset' ? 'Reset' : el.type === 'submit' ? 'Submit' : ''));
        if (el.labels && el.labels.length) {
          const text = Array.from(el.labels).map(labelText).join(' ');
          if (text) return text;
        }
        if (tag === 'img' || tag === 'area' || (tag === 'input' && el.type === 'image')) { const alt = el.getAttribute('alt'); if (alt) return squash(alt); }
        if (tag === 'iframe' || tag === 'frame') return squash(el.getAttribute('title') || el.getAttribute('name') || '');
        if (tag === 'fieldset') { const legend = el.querySelector(':scope > legend'); if (legend) return squash(legend.textContent); }
        if (NAME_FROM_CONTENT.has(role)) { const text = squash(composedText(el).join(' ')); if (text) return text; }
        const placeholder = el.getAttribute('placeholder');
        if (placeholder) return squash(placeholder);
        const title = el.getAttribute('title');
        if (title) return squash(title);
        return '';
      }
      function valueOf(el) {
        if (el.localName === 'select') return Array.from(el.selectedOptions).map((o) => squash(o.textContent)).join(', ');
        if (el.localName === 'input' && el.type === 'password') return el.value ? '•'.repeat(Math.min(el.value.length, 12)) : '';
        if ('value' in el && (el.localName === 'input' || el.localName === 'textarea')) return el.value;
        if (el.isContentEditable) return squash(el.textContent);
        return undefined;
      }
      function isEditable(el) {
        if (el.localName === 'textarea') return !el.readOnly && !el.disabled;
        if (el.localName === 'input') return !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color', 'hidden'].includes(el.type) && !el.readOnly && !el.disabled;
        return el.isContentEditable;
      }
      function rect(el) {
        const r = el.getBoundingClientRect();
        return { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) };
      }

      function snapshot(input) {
        refs = new Map();
        const ctx = { lines: [], refs: [], counter: input.base || 0, depth: input.depth || 8, max: 500, truncated: false, text: true, boxes: !!input.boxes };
        const emit = (level, ref, role, name, flags) => {
          ctx.lines.push(`${'  '.repeat(level)}${ref ? '@' + ref + ' ' : ''}[${role}] ${JSON.stringify(String(name).slice(0, 300))}${flags.length ? ' ' + flags.join(' ') : ''}`);
        };
        const walk = (node, level) => {
          if (ctx.lines.length >= ctx.max) { ctx.truncated = true; return; }
          if (node.nodeType === 3) {
            const text = squash(node.data);
            if (text && ctx.text) { if (level > ctx.depth) { ctx.truncated = true; return; } emit(level, '', 'StaticText', text, []); }
            return;
          }
          if (node.nodeType === 11) { for (const child of node.childNodes) walk(child, level); return; }
          if (node.nodeType !== 1) return;
          const el = node;
          if (SKIP.has(el.localName)) return;
          if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return;
          const style = getComputedStyle(el);
          if (style.display === 'none') return;
          const role = style.visibility === 'hidden' ? null : roleOf(el);
          let next = level;
          if (role) {
            if (level > ctx.depth) { ctx.truncated = true; return; }
            const name = nameOf(el, role);
            let ref = '';
            const focusable = el.hasAttribute('tabindex') && el.tabIndex >= 0;
            if (INTERACTIVE.has(role) || focusable || el.isContentEditable && el.hasAttribute('contenteditable')) {
              ref = 'e' + (++ctx.counter);
              refs.set(ref, new WeakRef(el));
              ctx.refs.push(ref);
            }
            const flags = [];
            if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) {
              const aria = el.getAttribute('aria-checked');
              flags.push('checked=' + (el.indeterminate ? 'mixed' : 'checked' in el && el.localName === 'input' ? el.checked : aria === 'true'));
            }
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') flags.push('disabled=true');
            if (el.hasAttribute('aria-expanded')) flags.push('expanded=' + el.getAttribute('aria-expanded'));
            else if (el.localName === 'details') flags.push('expanded=' + el.open);
            if (role === 'option') { if (el.localName === 'option') flags.push('value=' + JSON.stringify(el.value)); if (el.selected || el.getAttribute('aria-selected') === 'true') flags.push('selected=true'); }
            if (role === 'heading') flags.push('level=' + (el.localName.match(/^h(\d)$/)?.[1] || el.getAttribute('aria-level') || '2'));
            const value = ['textbox', 'searchbox', 'spinbutton', 'combobox', 'listbox', 'slider'].includes(role) ? valueOf(el) : undefined;
            if (value !== undefined) flags.push('value=' + JSON.stringify(String(value).slice(0, 200)));
            if (role === 'link' && el.href) flags.push('url=' + JSON.stringify(String(el.href).slice(0, 300)));
            if (role === 'Iframe') flags.push('src=' + JSON.stringify(String(el.src || '').slice(0, 300)));
            if (el.shadowRoot) flags.push('shadow=open');
            if (ctx.boxes && ref) flags.push('box=' + JSON.stringify(rect(el)));
            emit(level, ref, role, name, flags);
            next = level + 1;
            if (role === 'textbox' || role === 'searchbox' || role === 'Iframe') return;
          }
          const keepText = ctx.text;
          if (role && NAME_FROM_CONTENT.has(role)) ctx.text = false;
          for (const child of children(el)) walk(child, next);
          ctx.text = keepText;
        };
        let start;
        if (input.rootRef) start = resolve(input.rootRef);
        if (start) walk(start, 0);
        else {
          emit(0, '', 'RootWebArea', document.title || '', ['url=' + JSON.stringify(location.href.slice(0, 300))]);
          if (document.body) walk(document.body, 1);
        }
        return { lines: ctx.lines, refs: ctx.refs, counter: ctx.counter, truncated: ctx.truncated };
      }

      function resolve(ref) {
        const id = String(ref).replace(/^@/, '');
        const element = refs.get(id)?.deref();
        if (!element || !element.isConnected) throw new Error('stale_ref: element ' + id + ' is gone or from an older snapshot');
        return element;
      }

      // Scrolls the element into view when needed and reports where its centre is, in this frame's CSS pixels.
      function point(input) {
        const el = resolve(input.ref);
        const before = el.getBoundingClientRect();
        if (before.top < 0 || before.left < 0 || before.bottom > innerHeight || before.right > innerWidth) {
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        }
        const r = el.getBoundingClientRect();
        const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        const root = el.getRootNode();
        const hitNode = (root.elementFromPoint ? root : document).elementFromPoint(cx, cy);
        const labels = el.labels ? Array.from(el.labels) : [];
        const hit = !!hitNode && (hitNode === el || el.contains(hitNode) || hitNode.contains(el) && hitNode.getRootNode() !== root || labels.some((l) => l.contains(hitNode)));
        return { x: r.left, y: r.top, width: r.width, height: r.height, cx, cy, hit, hitTag: hitNode ? hitNode.localName : null,
          tag: el.localName, type: el.type || null, editable: isEditable(el), draggable: !!el.draggable,
          checked: 'checked' in el && el.localName === 'input' ? el.checked : null };
      }

      function prepareType(input) {
        const el = resolve(input.ref);
        if (!isEditable(el)) throw new Error('not_editable: element is not an editable text field; use select for dropdowns and check for checkboxes');
        el.focus();
        if (el.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(el);
          const selection = getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } else {
          try { el.select(); } catch (_) { try { el.setSelectionRange(0, el.value.length); } catch (_) {} }
        }
        return { focused: el.getRootNode().activeElement === el || document.activeElement === el };
      }

      function fillScript(input) {
        const el = resolve(input.ref);
        if (!isEditable(el)) throw new Error('not_editable: element is not an editable text field');
        el.focus();
        if (el.isContentEditable) {
          el.textContent = input.text;
        } else {
          const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, input.text);
        }
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: input.text }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return valueOf(el);
      }

      function selectOptions(input) {
        const el = resolve(input.ref);
        if (el.localName !== 'select') throw new Error('not_select: element is not an HTML select; click custom dropdowns instead');
        const options = Array.from(el.options);
        const chosen = input.values.map((value) => options.find((o) => o.value === value) || options.find((o) => squash(o.textContent) === squash(value)));
        const missing = input.values.filter((_, i) => !chosen[i]);
        if (missing.length) throw new Error('option_missing: no option with value ' + JSON.stringify(missing) + '; available values ' + JSON.stringify(options.map((o) => o.value).slice(0, 50)));
        if (!el.multiple && chosen.length > 1) throw new Error('not_multiple: this select accepts one value');
        el.focus();
        for (const option of options) option.selected = chosen.includes(option);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return Array.from(el.selectedOptions).map((o) => o.value);
      }

      function clickScript(input) {
        const el = resolve(input.ref);
        const r = el.getBoundingClientRect();
        const base = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
          button: input.button === 'right' ? 2 : input.button === 'middle' ? 1 : 0, altKey: !!input.alt, ctrlKey: !!input.ctrl, metaKey: !!input.meta, shiftKey: !!input.shift };
        el.dispatchEvent(new PointerEvent('pointerdown', base));
        el.dispatchEvent(new MouseEvent('mousedown', base));
        if (el.focus) el.focus();
        el.dispatchEvent(new PointerEvent('pointerup', base));
        el.dispatchEvent(new MouseEvent('mouseup', base));
        if (input.button === 'right') { el.dispatchEvent(new MouseEvent('contextmenu', base)); return true; }
        if (input.button === 'middle') { el.dispatchEvent(new MouseEvent('auxclick', base)); return true; }
        // HTMLElement.click() runs default actions (links, checkboxes, submit) that a synthetic MouseEvent would not.
        for (let i = 0; i < (input.count || 1); i++) el.click();
        if ((input.count || 1) === 2) el.dispatchEvent(new MouseEvent('dblclick', { ...base, detail: 2 }));
        return true;
      }

      function hoverScript(input) {
        const el = resolve(input.ref);
        const r = el.getBoundingClientRect();
        const base = { bubbles: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
        for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
          const Ctor = type.startsWith('pointer') ? PointerEvent : MouseEvent;
          el.dispatchEvent(new Ctor(type, { ...base, bubbles: !type.endsWith('enter') }));
        }
        return true;
      }

      function dragScript(input) {
        const source = resolve(input.from), target = resolve(input.to);
        const data = new DataTransfer();
        const fire = (el, type) => {
          const r = el.getBoundingClientRect();
          return el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, composed: true, dataTransfer: data, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }));
        };
        fire(source, 'dragstart'); fire(target, 'dragenter'); fire(target, 'dragover'); fire(target, 'drop'); fire(source, 'dragend');
        return true;
      }

      function filesScript(input) {
        const el = resolve(input.ref);
        const data = new DataTransfer();
        for (const file of input.files) {
          const binary = atob(file.data);
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          data.items.add(new File([bytes], file.name, { type: file.mime }));
        }
        if (input.drop) {
          for (const type of ['dragenter', 'dragover', 'drop']) el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, composed: true, dataTransfer: data }));
          return data.files.length;
        }
        if (!(el.localName === 'input' && el.type === 'file')) throw new Error('not_file_input: target is not an input[type=file]; use files.drop for drop areas');
        el.files = data.files;
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return el.files.length;
      }

      function checkedState(input) {
        const el = resolve(input.ref);
        if (el.localName === 'input' && (el.type === 'checkbox' || el.type === 'radio')) return el.checked;
        const aria = el.getAttribute('aria-checked');
        if (aria !== null) return aria === 'true';
        throw new Error('not_checkable: element is not a checkbox, radio or aria-checked control');
      }

      function waitText(input) {
        const has = () => (document.body ? document.body.innerText + ' ' + composedText(document.body).join(' ') : '').includes(input.text);
        const ok = () => (input.gone ? !has() : has());
        return new Promise((resolveWait) => {
          if (ok()) return resolveWait(true);
          let finished = false;
          const done = (value) => { if (finished) return; finished = true; observer.disconnect(); clearTimeout(timer); clearInterval(poll); resolveWait(value); };
          const observer = new MutationObserver(() => { if (ok()) done(true); });
          observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
          const poll = setInterval(() => { if (ok()) done(true); }, 100);
          const timer = setTimeout(() => done(ok()), input.timeoutMs);
        });
      }

      function iframes() {
        return Array.from(document.querySelectorAll('iframe,frame')).map((el) => {
          const r = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return { src: el.src || '', name: el.name || '', x: r.left + el.clientLeft + parseFloat(style.paddingLeft || '0'), y: r.top + el.clientTop + parseFloat(style.paddingTop || '0') };
        });
      }

      function scrollPage(input) {
        const before = { x: scrollX, y: scrollY };
        if (!input.check) scrollBy({ left: input.dx, top: input.dy, behavior: 'instant' });
        return { before, after: { x: scrollX, y: scrollY }, height: document.documentElement.scrollHeight, width: document.documentElement.scrollWidth, viewportWidth: innerWidth, viewportHeight: innerHeight };
      }

      function network() {
        const nav = performance.getEntriesByType('navigation');
        const resources = performance.getEntriesByType('resource');
        return [...nav, ...resources].map((entry) => ({ url: entry.name, initiator: entry.initiatorType || (entry.entryType === 'navigation' ? 'navigation' : 'other'),
          start: performance.timeOrigin + entry.startTime, duration: entry.duration, status: entry.responseStatus || 0, size: entry.transferSize || 0 }));
      }

      const api = { snapshot, point, prepareType, fillScript, selectOptions, clickScript, hoverScript, dragScript, filesScript,
        checkedState, waitText, iframes, scrollPage, network,
        frameInfo: () => ({ frameId, url: location.href, name: window.name, top: window === window.top }),
        valueOf: (input) => valueOf(resolve(input.ref)) ?? null };
      window.__bc = { frameId, resolve, call: (name, input) => api[name](input) };
      post({ kind: 'frame', frameId, url: location.href, name: window.name, top: window === window.top });
    })();
    """#

    static let consoleSource = #"""
    (() => {
      if (window.__bcConsoleInstalled) return;
      Object.defineProperty(window, '__bcConsoleInstalled', { value: true });
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bcConsole;
      if (!handler) return;
      const format = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack || String(value);
        try { return JSON.stringify(value); } catch (_) { return String(value); }
      };
      const send = (level, args, source) => { try { handler.postMessage({ level, text: args.map(format).join(' ').slice(0, 10000), source: source || null }); } catch (_) {} };
      for (const [method, level] of [['debug', 'debug'], ['log', 'info'], ['info', 'info'], ['warn', 'warning'], ['error', 'error']]) {
        const original = console[method];
        console[method] = function (...args) { send(level, args); return original.apply(this, args); };
      }
      addEventListener('error', (event) => send('error', ['Uncaught ' + (event.error && event.error.stack ? event.error.stack : event.message)], event.filename ? { url: event.filename, line: event.lineno || 0, column: event.colno || 0 } : null));
      addEventListener('unhandledrejection', (event) => send('error', ['Unhandled promise rejection: ' + format(event.reason)]));
    })();
    """#
}
