import Foundation

/// One URL fetched for Network diagnostics (Settings ▸ Containers ▸ Corporate network): whether it worked, the HTTP
/// status, the certificate issuer seen (a TLS-intercepting proxy shows its own CA here), and proxy headers if any.
public struct NetworkProbeResult: Sendable, Equatable, Hashable, Identifiable {
    public var url: String
    public var ok: Bool
    public var status: Int?
    /// The issuer of the server certificate as presented (`CN=…, O=…`).
    public var issuer: String?
    /// `Via`, `X-Cache`, `Proxy-*`, `X-Forwarded-*` … response headers (`Name: value`).
    public var proxyHeaders: [String]
    /// A proxy the client used (from its variables), if any.
    public var proxy: String?
    public var error: String?
    /// `curl`, `python3`, `wget`, `URLSession`, or `none` (the image has no tool to fetch with).
    public var tool: String
    public var id: String { url }

    public init(url: String, ok: Bool, status: Int? = nil, issuer: String? = nil, proxyHeaders: [String] = [], proxy: String? = nil,
                error: String? = nil, tool: String) {
        self.url = url
        self.ok = ok
        self.status = status
        self.issuer = issuer
        self.proxyHeaders = proxyHeaders
        self.proxy = proxy
        self.error = error
        self.tool = tool
    }

    /// Response headers that reveal a proxy.
    public static func isProxyHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "via" || lower.hasPrefix("proxy-") || lower.hasPrefix("x-forwarded") || lower == "x-cache" || lower == "x-cache-lookup"
            || lower.hasPrefix("x-bluecoat") || lower.hasPrefix("x-zscaler") || lower == "x-squid-error"
    }
}

/// The in-container probe: curl (`-v` shows the issuer and response headers), else node, else python3, else wget
/// (status only).
/// Output is delimited per URL so a failure of one never hides the others.
public enum NetworkProbe {
    public static func script(urls: [String]) -> [String] {
        let script = #"""
        t=/tmp/.bellocode-diag.$$
        for u; do
          echo "@@url $u"
          if command -v curl >/dev/null 2>&1; then
            echo "@@tool curl"
            curl -sS -v -o /dev/null --max-time 10 "$u" >"$t" 2>&1; c=$?
            head -c 32768 "$t"; echo; echo "@@exit $c"
          elif command -v node >/dev/null 2>&1; then
            echo "@@tool node"
            node -e '
        const u = process.argv[1], m = u.startsWith("https:") ? require("https") : require("http");
        const r = m.request(u, { method: "HEAD", timeout: 10000 }, (res) => {
          const c = res.socket && res.socket.getPeerCertificate ? res.socket.getPeerCertificate() : null;
          if (c && c.issuer) console.log("*  issuer: " + Object.entries(c.issuer).map(([k, v]) => k + "=" + v).join(", "));
          console.log("< HTTP/1.1 " + res.statusCode);
          for (const [k, v] of Object.entries(res.headers)) console.log("< " + k + ": " + v);
          console.log("@@exit 0"); res.resume();
        });
        r.on("timeout", () => r.destroy(new Error("timed out")));
        r.on("error", (e) => { console.log("curl: (1) " + e.message); console.log("@@exit 1"); });
        r.end();' "$u" 2>&1 | head -c 32768
          elif command -v python3 >/dev/null 2>&1; then
            echo "@@tool python3"
            python3 - "$u" <<'PY' 2>&1 | head -c 32768
        import socket, ssl, sys, urllib.request, urllib.parse
        u = sys.argv[1]
        p = urllib.parse.urlsplit(u)
        if p.scheme == "https":
            try:
                ctx = ssl.create_default_context()
                with socket.create_connection((p.hostname, p.port or 443), timeout=10) as s:
                    with ctx.wrap_socket(s, server_hostname=p.hostname) as t:
                        issuer = ", ".join("%s=%s" % kv for rdn in t.getpeercert()["issuer"] for kv in rdn)
                        print("*  issuer: " + issuer)
            except Exception as e:
                print("*  tls-error: %s" % e)
        try:
            r = urllib.request.urlopen(u, timeout=10)
            print("< HTTP/1.1 %d" % r.status)
            for k, v in r.headers.items(): print("< %s: %s" % (k, v))
            print("@@exit 0")
        except urllib.error.HTTPError as e:
            print("< HTTP/1.1 %d" % e.code)
            for k, v in e.headers.items(): print("< %s: %s" % (k, v))
            print("@@exit 0")
        except Exception as e:
            print("curl: (1) %s" % e)
            print("@@exit 1")
        PY
          elif command -v wget >/dev/null 2>&1; then
            echo "@@tool wget"
            wget -S -O /dev/null -T 10 "$u" >"$t" 2>&1; c=$?
            sed 's/^  */< /' "$t" | head -c 32768; echo; echo "@@exit $c"
          else
            echo "@@tool none"; echo "@@exit 127"
          fi
        done
        rm -f "$t"
        """#
        return ["/bin/sh", "-c", script, "bellocode-diagnose"] + urls
    }

    /// Parses the probe's output into one result per URL (in the order given).
    public static func parse(_ output: String, urls: [String]) -> [NetworkProbeResult] {
        var blocks: [String: [Substring]] = [:]
        var current: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@url ") {
                current = String(line.dropFirst(6))
                blocks[current!] = []
            } else if let current {
                blocks[current]?.append(line)
            }
        }
        return urls.map { url in
            guard let lines = blocks[url] else { return NetworkProbeResult(url: url, ok: false, error: "the probe did not reach this URL", tool: "none") }
            return parseBlock(url: url, lines: lines)
        }
    }

    static func parseBlock(url: String, lines: [Substring]) -> NetworkProbeResult {
        var result = NetworkProbeResult(url: url, ok: false, tool: "none")
        var exit: Int?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@tool ") { result.tool = String(line.dropFirst(7)) }
            if line.hasPrefix("@@exit ") { exit = Int(line.dropFirst(7)) }
            if line.hasPrefix("*"), let range = line.range(of: "issuer: ") {
                result.issuer = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("*"), let range = line.range(of: "tls-error: ") { result.error = String(line[range.upperBound...]) }
            if line.hasPrefix("* Uses proxy env variable"), let quote = line.range(of: "== '") {
                result.proxy = String(line[quote.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
            if line.hasPrefix("< HTTP/") || line.hasPrefix("HTTP/") {
                let parts = line.split(separator: " ")
                if let code = parts.dropFirst(line.hasPrefix("<") ? 2 : 1).first.flatMap({ Int($0) }) { result.status = code }
            } else if line.hasPrefix("< "), let colon = line.firstIndex(of: ":") {
                let name = line.dropFirst(2)[..<colon].trimmingCharacters(in: .whitespaces)
                if NetworkProbeResult.isProxyHeader(name) { result.proxyHeaders.append(String(line.dropFirst(2))) }
            }
            if line.hasPrefix("curl: (") { result.error = String(line) }
            if result.tool == "wget", line.contains("certificate"), result.error == nil { result.error = String(line) }
        }
        if result.tool == "none" { result.error = "the container image has no curl, node, python3 or wget to fetch with" }
        result.ok = exit == 0 && result.status != nil
        if !result.ok, result.error == nil { result.error = exit.map { "failed (exit \($0))" } ?? "no answer" }
        return result
    }
}
