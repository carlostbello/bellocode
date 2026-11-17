// Fixture pages for the browser self-test and end-to-end run. Origin A serves pages; origin B (a different port on `localhost`) is cross-site.
import Foundation

enum Fixtures {
    static func route(_ path: String, headers: [String], crossOrigin: String, sameOrigin: String) -> FixtureResponse? {
        let bare = path.split(separator: "?").first.map(String.init) ?? path
        func page(_ body: String) -> FixtureResponse { FixtureResponse(body: body) }
        switch bare {
        case "/", "/form.html": return page(form)
        case "/dialogs.html": return page(dialogs)
        case "/console.html": return page(console)
        case "/spa.html", "/spa/details": return page(spa)
        case "/frames.html": return page(frames(same: sameOrigin, cross: crossOrigin))
        case "/child.html": return page(child)
        case "/shadow.html": return page(shadow)
        case "/long.html": return page(long)
        case "/slow.html": return page("<!doctype html><title>Slow</title><p id=t>Loading</p><script>setTimeout(() => { t.textContent = 'Ready now'; }, 600)</script>")
        case "/popup.html": return page(popup)
        case "/scheme.html": return page(scheme)
        case "/landing.html": return page(landing)
        case "/report.csv":
            return FixtureResponse(type: "text/csv", body: "name,plan\nAda Lovelace,pro\n", headers: ["Content-Disposition: attachment; filename=\"report.csv\""])
        case "/private":
            // HTTP Basic: ada / secret.
            let expected = "Authorization: Basic " + Data("ada:secret".utf8).base64EncodedString()
            if headers.contains(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) {
                return page("<!doctype html><title>Members</title><h1 id=welcome>Welcome, Ada</h1>")
            }
            return FixtureResponse(status: "401 Unauthorized", body: "<!doctype html><title>Sign in</title>sign in required", headers: ["WWW-Authenticate: Basic realm=\"Fixture members\""])
        default: return nil
        }
    }

    static let popup = """
    <!doctype html><html><head><title>Popup fixture</title>\(style)</head><body>
    <a id="blank" href="/landing.html?from=blank" target="_blank">Open landing in a new tab</a>
    <button id="open" onclick="window.open('/landing.html?from=open')">window.open landing</button>
    <a id="download" href="/report.csv">Download report</a>
    </body></html>
    """

    static let landing = "<!doctype html><title>Landing</title>\(style)<h1>Landing page</h1><p id=from></p><script>from.textContent = location.search</script>"

    static let scheme = """
    <!doctype html><html><head><title>Scheme fixture</title><meta name="color-scheme" content="light dark">
    <style>body{font:16px -apple-system,sans-serif;margin:24px;background:#fff;color:#111} @media (prefers-color-scheme: dark){body{background:#1c1c1e;color:#f2f2f7}}
    .card{border:1px solid #8884;border-radius:12px;padding:16px;max-width:520px}</style></head><body>
    <div class="card"><h1>Preview</h1><p id="mode"></p><p id="size"></p></div>
    <script>const update = () => { mode.textContent = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'; size.textContent = innerWidth + 'x' + innerHeight; };
    update(); matchMedia('(prefers-color-scheme: dark)').addEventListener('change', update); addEventListener('resize', update);</script>
    </body></html>
    """

    static let style = "<style>body{font:14px -apple-system,sans-serif;margin:16px} label{display:block;margin:6px 0} .box{padding:8px;border:1px solid #888;margin:6px 0}</style>"

    static let form = """
    <!doctype html><html><head><title>Signup fixture</title>\(style)</head><body>
    <h1>Sign up</h1>
    <form id="f">
      <label>Full name <input id="name" name="name"></label>
      <label>Email <input id="email" type="email" name="email"></label>
      <label>Plan <select id="plan" name="plan"><option value="">Choose…</option><option value="free">Free</option><option value="pro">Pro</option></select></label>
      <label><input id="terms" type="checkbox" name="terms"> I accept the terms</label>
      <fieldset><legend>Contact</legend>
        <label><input type="radio" name="contact" value="email" checked> By email</label>
        <label><input id="phone" type="radio" name="contact" value="phone"> By phone</label></fieldset>
      <label>Start date <input id="start" type="date"></label>
      <label>Notes <textarea id="notes"></textarea></label>
      <button id="submit" type="submit">Create account</button>
    </form>
    <p id="result" role="status"></p>
    <div id="hoverbox" class="box" tabindex="0">Hover target</div><span id="hovered">not hovered</span>
    <label>Key log <input id="keys"></label><span id="keylog"></span>
    <label>Upload <input id="upload" type="file" multiple></label><span id="uploaded"></span>
    <div id="drop" class="box" tabindex="0" aria-label="Drop zone">Drop here</div>
    <div id="dragsrc" class="box" draggable="true" role="button" tabindex="0">Drag me</div>
    <div id="dragdst" class="box" role="button" tabindex="0">Drop target</div><span id="dragged"></span>
    <script>
      window.trust = [];
      const log = (e) => { if (trust.length < 400) trust.push(e.type + ':' + e.isTrusted + ':' + (e.target.id || e.target.localName)); };
      for (const t of ['click', 'mousedown', 'keydown', 'beforeinput', 'input', 'mousemove', 'mouseover']) document.addEventListener(t, log, true);
      const f = document.getElementById('f');
      f.addEventListener('submit', (e) => {
        e.preventDefault();
        if (!f.name.value || !terms.checked || !plan.value) { result.textContent = 'Missing fields'; return; }
        const code = 'BC-' + (f.name.value.length * 7 + plan.value.length);
        result.textContent = 'Confirmation ' + code + ': ' + f.name.value + ' <' + f.email.value + '> on the ' + plan.value + ' plan';
        console.info('submitted', code);
      });
      hoverbox.addEventListener('mouseenter', (e) => { hovered.textContent = 'hovered:' + e.isTrusted; });
      keys.addEventListener('keydown', (e) => { keylog.textContent += e.key + (e.isTrusted ? '+' : '-') + ' '; });
      upload.addEventListener('change', () => { uploaded.textContent = Array.from(upload.files).map((x) => x.name + ':' + x.size).join(','); });
      drop.addEventListener('dragover', (e) => e.preventDefault());
      drop.addEventListener('drop', (e) => { e.preventDefault(); drop.textContent = 'dropped ' + Array.from(e.dataTransfer.files).map((x) => x.name).join(','); });
      dragsrc.addEventListener('dragstart', (e) => e.dataTransfer.setData('text/plain', 'x'));
      dragdst.addEventListener('dragover', (e) => e.preventDefault());
      dragdst.addEventListener('drop', (e) => { e.preventDefault(); dragged.textContent = 'drag-ok'; });
    </script></body></html>
    """

    static let dialogs = """
    <!doctype html><html><head><title>Dialogs fixture</title>\(style)</head><body>
    <button id="a" onclick="alert('Hello from alert'); out.textContent = 'alert:done'">Show alert</button>
    <button id="c" onclick="out.textContent = 'confirm:' + confirm('Proceed?')">Show confirm</button>
    <button id="p" onclick="out.textContent = 'prompt:' + prompt('Your name?', 'anon')">Show prompt</button>
    <p id="out">none</p></body></html>
    """

    static let console = """
    <!doctype html><html><head><title>Console fixture</title>\(style)</head><body><p>Console</p>
    <script>
      console.debug('debug line'); console.log('log line', { a: 1 }); console.warn('warn line'); console.error('error line');
      setTimeout(() => { throw new Error('boom from timer'); }, 0);
      Promise.reject(new Error('rejected promise'));
    </script></body></html>
    """

    static let spa = """
    <!doctype html><html><head><title>SPA fixture</title>\(style)</head><body>
    <nav><a id="home" href="/spa.html">Home</a> <a id="details" href="/spa/details">Details</a></nav>
    <main id="view"></main>
    <script>
      const render = () => { view.textContent = location.pathname === '/spa/details' ? 'Details view' : 'Home view'; document.title = 'SPA ' + view.textContent; };
      document.addEventListener('click', (e) => { const a = e.target.closest('a'); if (!a) return; e.preventDefault(); history.pushState({}, '', a.getAttribute('href')); render(); });
      addEventListener('popstate', render); render();
    </script></body></html>
    """

    static func frames(same: String, cross: String) -> String {
        """
        <!doctype html><html><head><title>Frames fixture</title>\(style)</head><body><h1>Frames</h1>
        <iframe title="Same origin frame" name="same" src="\(same)/child.html?same" style="width:420px;height:140px;border:1px solid #888"></iframe>
        <iframe title="Cross origin frame" name="cross" src="\(cross)/child.html?cross" style="width:420px;height:140px;border:1px solid #888;margin-left:20px"></iframe>
        </body></html>
        """
    }

    static let child = """
    <!doctype html><html><head><title>Child</title>\(style)</head><body>
    <button id="b" onclick="n.textContent = 'clicked ' + (++window.count) + ' trusted=' + event.isTrusted">Child button</button>
    <span id="n">clicked 0</span><label>Child input <input id="i"></label>
    <script>window.count = 0;</script></body></html>
    """

    static let shadow = """
    <!doctype html><html><head><title>Shadow fixture</title>\(style)</head><body>
    <x-card id="open"><span slot="title">Slotted title</span></x-card>
    <x-closed id="closed"></x-closed>
    <p id="out">none</p>
    <script>
      customElements.define('x-card', class extends HTMLElement { constructor() { super(); const r = this.attachShadow({ mode: 'open' });
        r.innerHTML = '<div class="box"><slot name="title"></slot><button id="sb">Shadow button</button><label>Shadow input <input id="si"></label></div>';
        r.getElementById('sb').addEventListener('click', (e) => { out.textContent = 'shadow clicked trusted=' + e.isTrusted; }); } });
      customElements.define('x-closed', class extends HTMLElement { constructor() { super(); const r = this.attachShadow({ mode: 'closed' });
        r.innerHTML = '<button>Closed button</button>'; } });
    </script></body></html>
    """

    static let long = """
    <!doctype html><html><head><title>Long fixture</title>\(style)</head><body>
    <h1 id="top">Top of page</h1><div style="height:5000px;background:linear-gradient(#fff,#cde)"></div>
    <button id="bottom" onclick="this.textContent = 'Bottom clicked'">Bottom button</button></body></html>
    """
}
