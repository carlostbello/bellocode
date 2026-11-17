import Foundation

/// Turns what the person typed in the address field into a URL: a URL with a scheme, a host-like word (`localhost:3000`
/// and IP addresses use http, other hosts https), or a search.
public enum BrowserAddress {
    /// `%s` is replaced with the percent-encoded query.
    public static let defaultSearchTemplate = "https://duckduckgo.com/?q=%s"

    public static func resolve(_ input: String, searchTemplate: String = defaultSearchTemplate) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "about:blank" { return URL(string: text) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
            return url
        }
        if !text.contains(" "), looksLikeHost(text) {
            let local = isLocal(text)
            return URL(string: (local ? "http://" : "https://") + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: query))
    }

    /// `localhost`, loopback and private IPv4 hosts, with an optional port and path.
    public static func isLocal(_ text: String) -> Bool {
        text.range(of: #"^(localhost|127(\.\d{1,3}){3}|0\.0\.0\.0|\[::1\]|10(\.\d{1,3}){3}|192\.168(\.\d{1,3}){2}|[\w-]+\.local)(:\d+)?([/?#].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeHost(_ text: String) -> Bool {
        if isLocal(text) { return true }
        // host.tld[:port][/path]
        return text.range(of: #"^[\w-]+(\.[\w-]+)+(:\d+)?([/?#].*)?$"#, options: .regularExpression) != nil
    }

    /// Schemes a page may navigate to inside the browser. Others (mailto:, custom apps) go to the system.
    public static func isWebScheme(_ url: URL) -> Bool {
        ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
    }

    /// What the address field shows for a URL: the full URL, without a trailing slash on a bare origin.
    public static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.absoluteString == "about:blank" { return "" }
        var text = url.absoluteString
        if url.path() == "/", url.query() == nil, url.fragment() == nil, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Dev-server URLs in text (terminal output, agent output): loopback hosts with a port.
    public static func devServerURLs(in text: String) -> [URL] {
        let pattern = #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{2,5}(/[^\s"'<>)\]]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var value = String(text[range]).replacingOccurrences(of: "0.0.0.0", with: "localhost")
            while let last = value.last, ".,;:".contains(last) { value.removeLast() }
            guard seen.insert(value).inserted else { return nil }
            return URL(string: value)
        }
    }
}
