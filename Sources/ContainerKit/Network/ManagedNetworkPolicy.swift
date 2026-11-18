import CFNetwork
import Foundation

/// The administrator's network settings (docs/features/containers.md, "Corporate network"), read like the image policy
/// from keys forced by a configuration profile in `com.bellocode.app` or a root-owned, non-writable
/// `/Library/Preferences/app.bellocode.policy.plist`:
///
/// - `NetworkTrustEnterpriseCertificates` (bool): force "Trust enterprise certificates in containers" on or off.
/// - `NetworkTrustedCertificates` (array of SHA-256 fingerprints, hex): exactly which roots to trust.
/// - `NetworkHTTPProxy`, `NetworkHTTPSProxy` (string URLs), `NetworkNoProxy` (array or comma-separated string).
/// - `NetworkDiagnosticsURLs` (array): the URLs Network diagnostics fetches.
public enum ManagedNetworkPolicy {
    public static let trustKey = "NetworkTrustEnterpriseCertificates"
    public static let certificatesKey = "NetworkTrustedCertificates"
    public static let httpProxyKey = "NetworkHTTPProxy"
    public static let httpsProxyKey = "NetworkHTTPSProxy"
    public static let noProxyKey = "NetworkNoProxy"
    public static let diagnosticsKey = "NetworkDiagnosticsURLs"
    public static let keys = [trustKey, certificatesKey, httpProxyKey, httpsProxyKey, noProxyKey, diagnosticsKey]

    public struct Managed: Sendable, Equatable {
        public var trustEnterpriseCertificates: Bool?
        public var certificates: [String]?
        public var httpProxy: String?
        public var httpsProxy: String?
        public var noProxy: [String]?
        public var diagnosticsURLs: [String]?
        public var source: String

        public init(trustEnterpriseCertificates: Bool? = nil, certificates: [String]? = nil, httpProxy: String? = nil, httpsProxy: String? = nil,
                    noProxy: [String]? = nil, diagnosticsURLs: [String]? = nil, source: String) {
            self.trustEnterpriseCertificates = trustEnterpriseCertificates
            self.certificates = certificates
            self.httpProxy = httpProxy
            self.httpsProxy = httpsProxy
            self.noProxy = noProxy
            self.diagnosticsURLs = diagnosticsURLs
            self.source = source
        }

        public var setsProxy: Bool { httpProxy != nil || httpsProxy != nil || noProxy != nil }
    }

    public static func read(defaults: UserDefaults = .standard, systemPlist: String = ManagedImagePolicy.systemPlist) -> Managed? {
        let forced = keys.filter { defaults.objectIsForced(forKey: $0) }
        if !forced.isEmpty { return managed(from: { forced.contains($0) ? defaults.object(forKey: $0) : nil }, source: "configuration profile") }
        guard let values = ManagedImagePolicy.rootOwnedPlist(systemPlist), keys.contains(where: { values[$0] != nil }) else { return nil }
        return managed(from: { values[$0] }, source: systemPlist)
    }

    static func managed(from value: (String) -> Any?, source: String) -> Managed {
        func list(_ key: String) -> [String]? {
            if let array = value(key) as? [String] { return array }
            return (value(key) as? String).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        return Managed(
            trustEnterpriseCertificates: value(trustKey) as? Bool,
            certificates: list(certificatesKey)?.map(CertificateFingerprint.normalize),
            httpProxy: value(httpProxyKey) as? String, httpsProxy: value(httpsProxyKey) as? String, noProxy: list(noProxyKey),
            diagnosticsURLs: list(diagnosticsKey), source: source)
    }
}

/// SHA-256 fingerprints as administrators write them (`AB:CD:…`, `abcd…`, with spaces): lowercase hex.
public enum CertificateFingerprint {
    public static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isHexDigit }
    }
}

/// The Mac's proxy settings: the process environment wins (a terminal launch), then System Settings ▸ Network
/// (`CFNetworkCopySystemProxySettings`). A transparent proxy sets neither: nothing is passed then.
public struct SystemProxySettings: Sendable, Equatable {
    public var httpProxy: String?
    public var httpsProxy: String?
    public var noProxy: [String]
    /// "environment", "macOS network settings", or nil when none is set.
    public var source: String?

    public init(httpProxy: String? = nil, httpsProxy: String? = nil, noProxy: [String] = [], source: String? = nil) {
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.noProxy = noProxy
        self.source = source
    }

    public static func current() -> SystemProxySettings {
        let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return from(environment: ProcessInfo.processInfo.environment, system: system)
    }

    /// From the environment (`HTTP_PROXY`, `https_proxy`, `NO_PROXY` …) or the system dictionary (`HTTPEnable`,
    /// `HTTPProxy`, `HTTPPort`, `HTTPSEnable`, … `ExceptionsList`). Proxy auto-configuration (PAC) is not evaluated.
    public static func from(environment: [String: String], system: [String: Any]) -> SystemProxySettings {
        func env(_ name: String) -> String? {
            (environment[name] ?? environment[name.lowercased()]).flatMap { $0.isEmpty ? nil : $0 }
        }
        let noProxyEnv = env("NO_PROXY").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        if env("HTTP_PROXY") != nil || env("HTTPS_PROXY") != nil {
            return SystemProxySettings(httpProxy: env("HTTP_PROXY"), httpsProxy: env("HTTPS_PROXY"), noProxy: noProxyEnv, source: "environment")
        }
        func proxy(_ prefix: String) -> String? {
            guard (system["\(prefix)Enable"] as? NSNumber)?.boolValue == true, let host = system["\(prefix)Proxy"] as? String, !host.isEmpty
            else { return nil }
            let port = (system["\(prefix)Port"] as? NSNumber)?.intValue
            return "http://\(host)" + (port.map { ":\($0)" } ?? "")
        }
        let http = proxy("HTTP"), https = proxy("HTTPS")
        guard http != nil || https != nil else { return SystemProxySettings() }
        let exceptions = (system["ExceptionsList"] as? [String] ?? []).map { $0.hasPrefix("*.") ? String($0.dropFirst()) : $0 }
        return SystemProxySettings(httpProxy: http, httpsProxy: https, noProxy: exceptions, source: "macOS network settings")
    }
}
