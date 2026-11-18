import ContainerKit
import CryptoKit
import Foundation
import Security
import Synchronization

/// A root certificate the Mac trusts, as Settings lists it. Only certificate data: private keys and identities are never
/// read (the source asks the trust-settings store for certificates, nothing else).
public struct TrustedCertificate: Sendable, Equatable, Hashable, Identifiable {
    public enum Domain: String, Sendable, Codable, Hashable {
        /// Trusted for every user of the Mac: a configuration profile (MDM) or an administrator installed it.
        case admin
        /// Trusted only in this user's login keychain.
        case user
    }

    public var der: Data
    public var subject: String
    public var fingerprint: String
    public var domain: Domain
    public var isSelfSigned: Bool
    public var isCertificateAuthority: Bool
    public var notAfter: Date?
    public var id: String { fingerprint }

    public init(der: Data, subject: String, domain: Domain, isSelfSigned: Bool, isCertificateAuthority: Bool, notAfter: Date? = nil) {
        self.der = der
        self.subject = subject
        self.fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        self.domain = domain
        self.isSelfSigned = isSelfSigned
        self.isCertificateAuthority = isCertificateAuthority
        self.notAfter = notAfter
    }

    /// `AB:CD:…` (first 8 bytes) for the pane.
    public var shortFingerprint: String {
        stride(from: 0, to: min(16, fingerprint.count), by: 2).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            return fingerprint[start..<fingerprint.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }

    public var pem: String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }
}

/// Where trusted certificates come from (the Keychain in the app, fixtures in tests).
public protocol TrustedCertificateSource: Sendable {
    /// Certificates with trust settings in the admin (profile or administrator) and user domains.
    func trustedCertificates() -> [TrustedCertificate]
    /// The Mac's built-in public roots (DER), for the full bundle.
    func systemAnchors() -> [Data]
}

/// The macOS trust-settings store (Security framework): `SecTrustSettingsCopyCertificates` for the admin and user
/// domains, `SecTrustCopyAnchorCertificates` for the built-in roots. Certificates only; no key or identity is queried.
public struct KeychainCertificateSource: TrustedCertificateSource {
    public init() {}

    public func trustedCertificates() -> [TrustedCertificate] {
        var result: [TrustedCertificate] = []
        for (domain, secDomain) in [(TrustedCertificate.Domain.admin, SecTrustSettingsDomain.admin), (.user, .user)] {
            var array: CFArray?
            guard SecTrustSettingsCopyCertificates(secDomain, &array) == errSecSuccess, let certificates = array as? [SecCertificate] else { continue }
            for certificate in certificates where Self.trustedAsRoot(certificate, domain: secDomain) {
                let der = SecCertificateCopyData(certificate) as Data
                let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed certificate"
                let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
                let subjectSequence = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?
                let selfSigned = issuer != nil && issuer == subjectSequence
                result.append(TrustedCertificate(der: der, subject: subject, domain: domain, isSelfSigned: selfSigned,
                                                 isCertificateAuthority: Self.isCA(certificate) ?? selfSigned, notAfter: Self.notAfter(certificate)))
            }
        }
        return result
    }

    public func systemAnchors() -> [Data] {
        var array: CFArray?
        guard SecTrustCopyAnchorCertificates(&array) == errSecSuccess, let certificates = array as? [SecCertificate] else { return [] }
        return certificates.map { SecCertificateCopyData($0) as Data }
    }

    /// Trust settings that make it a root (empty settings mean "always trust"; any "deny" excludes it).
    static func trustedAsRoot(_ certificate: SecCertificate, domain: SecTrustSettingsDomain) -> Bool {
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(certificate, domain, &settings) == errSecSuccess else { return false }
        let entries = settings as? [[String: Any]] ?? []
        if entries.isEmpty { return true }
        let results = entries.map { ($0[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value ?? SecTrustSettingsResult.trustRoot.rawValue }
        if results.contains(SecTrustSettingsResult.deny.rawValue) { return false }
        return results.contains(SecTrustSettingsResult.trustRoot.rawValue) || results.contains(SecTrustSettingsResult.trustAsRoot.rawValue)
    }

    static func isCA(_ certificate: SecCertificate) -> Bool? {
        let keys = [kSecOIDBasicConstraints] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let constraints = values[kSecOIDBasicConstraints as String] as? [String: Any],
              let entries = constraints[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        for entry in entries where (entry[kSecPropertyKeyLabel as String] as? String) == "Certificate Authority" {
            return (entry[kSecPropertyKeyValue as String] as? String) == "Yes"
        }
        return nil
    }

    static func notAfter(_ certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}

/// Settings ▸ Containers ▸ Corporate network (an app preference; an administrator's keys win).
public struct NetworkSettings: Codable, Sendable, Equatable {
    /// nil: automatic (on when the Mac trusts roots installed for all users, by a profile or an administrator).
    public var trustEnterpriseCertificates: Bool?
    /// Fingerprints chosen; nil: the default (every admin-domain root CA).
    public var selectedCertificates: [String]?
    /// nil: the defaults.
    public var diagnosticsURLs: [String]?

    public init(trustEnterpriseCertificates: Bool? = nil, selectedCertificates: [String]? = nil, diagnosticsURLs: [String]? = nil) {
        self.trustEnterpriseCertificates = trustEnterpriseCertificates
        self.selectedCertificates = selectedCertificates
        self.diagnosticsURLs = diagnosticsURLs
    }

    public static let preferenceKey = "network.settings"
    public static let defaultDiagnosticsURLs = ["https://gitlab.novacoast.com", "https://registry.npmjs.org", "https://pypi.org/simple/"]
}

/// One diagnostics run: each URL fetched from inside the workspace container and from the Mac.
public struct NetworkDiagnostics: Sendable, Equatable {
    public var date: Date
    /// The project whose container ran the probe (nil: none was ready).
    public var project: String?
    public var container: [NetworkProbeResult]
    public var containerProblem: String?
    public var mac: [NetworkProbeResult]
    /// Issuers of an enterprise root seen in the results: TLS interception is happening.
    public var interceptedBy: [String]

    public init(date: Date = Date(), project: String? = nil, container: [NetworkProbeResult] = [], containerProblem: String? = nil,
                mac: [NetworkProbeResult] = [], interceptedBy: [String] = []) {
        self.date = date
        self.project = project
        self.container = container
        self.containerProblem = containerProblem
        self.mac = mac
        self.interceptedBy = interceptedBy
    }
}

/// The corporate network as applied (observable through `EnvironmentService.network`).
public struct NetworkState: Sendable, Equatable {
    /// What containers get (certificates folder, proxies).
    public var corporate = CorporateNetwork()
    /// Roots the person or administrator can pick from (admin- and user-trusted root CAs; never leaf certificates).
    public var candidates: [TrustedCertificate] = []
    public var selected: Set<String> = []
    public var trustEnabled = false
    /// The setting is automatic (no choice saved, no administrator key).
    public var trustAutomatic = true
    /// Where an administrator's keys came from, when they set any.
    public var managedSource: String?
    public var managedTrust: Bool { managedTrustValue != nil }
    public var managedTrustValue: Bool?
    public var managedCertificates: Bool = false
    public var managedProxy: Bool = false
    /// Where the proxy variables came from ("administrator", "environment", "macOS network settings"), nil: none.
    public var proxySource: String?
    public var exportProblem: String?
    /// The enterprise bundle opencode gets (`NODE_EXTRA_CA_CERTS`), when written.
    public var enterpriseBundlePath: String?
    public var diagnosticsURLs: [String] = NetworkSettings.defaultDiagnosticsURLs
    public var diagnostics: NetworkDiagnostics?
    public var isDiagnosing = false

    public init() {}

    /// The default selection: every admin-domain (profile or administrator) self-signed root CA. Never a user-domain
    /// certificate and never a non-CA (personal) certificate.
    public static func defaultSelection(_ candidates: [TrustedCertificate]) -> Set<String> {
        Set(candidates.filter { $0.domain == .admin && $0.isSelfSigned && $0.isCertificateAuthority }.map(\.fingerprint))
    }

    /// The roots that may be offered at all: certificate authorities only (a personal or server certificate never is).
    public static func eligible(_ certificates: [TrustedCertificate]) -> [TrustedCertificate] {
        var seen = Set<String>()
        return certificates.filter { $0.isCertificateAuthority && seen.insert($0.fingerprint).inserted }
            .sorted { ($0.domain == .admin ? 0 : 1, $0.subject) < ($1.domain == .admin ? 0 : 1, $1.subject) }
    }
}

extension EnvironmentService {
    /// Re-reads the setting, the administrator's keys, the Mac's proxies and trusted roots; writes the bundles; applies
    /// the result to containers (a change recreates them on next use) and the helper configuration.
    public func refreshCorporateNetwork() async {
        guard let configuration else { return }
        let settings = (try? await store.preference(NetworkSettings.preferenceKey, as: NetworkSettings.self)) ?? NetworkSettings()
        let managed = configuration.managedNetwork()
        let source = configuration.certificateSource
        let proxy = configuration.systemProxy()
        let directory = configuration.certificateDirectory
        let computed = await Self.computeNetwork(settings: settings, managed: managed, proxy: proxy, source: source, directory: directory)
        var state = computed
        state.diagnostics = network.diagnostics
        state.isDiagnosing = network.isDiagnosing
        let changed = state.corporate != network.corporate
        network = state
        if changed {
            for model in models.values { refreshImageAndPhase(model) }
            scheduleConfigWrite()
            reconcileStacks(force: true)
        }
    }

    /// Pure apart from the Keychain read and the bundle write (both off the main actor).
    @concurrent
    nonisolated static func computeNetwork(settings: NetworkSettings, managed: ManagedNetworkPolicy.Managed?, proxy: SystemProxySettings,
                                           source: any TrustedCertificateSource, directory: URL?) async -> NetworkState {
        var state = NetworkState()
        state.managedSource = managed?.source
        state.candidates = NetworkState.eligible(source.trustedCertificates())
        let defaultSelection = NetworkState.defaultSelection(state.candidates)
        state.managedTrustValue = managed?.trustEnterpriseCertificates
        state.managedCertificates = managed?.certificates != nil
        if let forced = managed?.certificates {
            state.selected = Set(forced).intersection(state.candidates.map(\.fingerprint))
        } else if let chosen = settings.selectedCertificates {
            state.selected = Set(chosen).intersection(state.candidates.map(\.fingerprint))
        } else {
            state.selected = defaultSelection
        }
        state.trustAutomatic = managed?.trustEnterpriseCertificates == nil && settings.trustEnterpriseCertificates == nil
        state.trustEnabled = managed?.trustEnterpriseCertificates ?? settings.trustEnterpriseCertificates ?? !defaultSelection.isEmpty
        state.diagnosticsURLs = managed?.diagnosticsURLs ?? settings.diagnosticsURLs ?? NetworkSettings.defaultDiagnosticsURLs

        // Proxies: an administrator's win, else the Mac's (environment, then System Settings). A transparent proxy needs none.
        if let managed, managed.setsProxy {
            state.managedProxy = true
            state.proxySource = "administrator"
            state.corporate.httpProxy = managed.httpProxy
            state.corporate.httpsProxy = managed.httpsProxy
            state.corporate.noProxy = managed.noProxy ?? []
        } else if proxy.source != nil {
            state.proxySource = proxy.source
            state.corporate.httpProxy = proxy.httpProxy
            state.corporate.httpsProxy = proxy.httpsProxy
            state.corporate.noProxy = proxy.noProxy
        }

        let chosen = state.candidates.filter { state.selected.contains($0.fingerprint) }
        if state.trustEnabled, !chosen.isEmpty, let directory {
            do {
                let fingerprint = try writeBundles(chosen, anchors: source.systemAnchors(), to: directory)
                state.corporate.certificateDirectory = directory.path
                state.corporate.certificateFingerprint = fingerprint
                state.enterpriseBundlePath = directory.appending(path: CorporateNetwork.enterpriseName).path
            } catch {
                state.exportProblem = "The certificate bundle could not be written (\(error.localizedDescription)). Containers get no enterprise certificates until it is."
            }
        } else if !state.trustEnabled, let directory {
            // Off: nothing is mounted, and opencode's next launch gets no bundle.
            for name in [CorporateNetwork.enterpriseName, CorporateNetwork.bundleName] {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
        if state.trustEnabled, chosen.isEmpty {
            state.exportProblem = state.candidates.isEmpty
                ? "This Mac trusts no enterprise root certificates, so there is nothing to add to containers."
                : "No certificate is selected."
        }
        return state
    }

    /// Writes `enterprise-roots.pem` (the chosen roots) and `ca-bundle.pem` (the Mac's built-in roots plus the chosen
    /// ones) atomically, readable by container users (certificates are public). Returns the enterprise bundle's SHA-256.
    nonisolated static func writeBundles(_ chosen: [TrustedCertificate], anchors: [Data], to directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let enterprise = chosen.sorted { $0.fingerprint < $1.fingerprint }.map(\.pem).joined()
        let chosenSet = Set(chosen.map(\.der))
        let builtIn = anchors.filter { !chosenSet.contains($0) }.map {
            TrustedCertificate(der: $0, subject: "", domain: .admin, isSelfSigned: true, isCertificateAuthority: true).pem
        }.joined()
        for (name, text) in [(CorporateNetwork.enterpriseName, enterprise), (CorporateNetwork.bundleName, builtIn + enterprise)] {
            let url = directory.appending(path: name)
            if FileManager.default.contents(atPath: url.path) == Data(text.utf8) { continue }
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return SHA256.hash(data: Data(enterprise.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The corporate network for image builds of `directory`'s project (the image-build feature calls this): the
    /// exported certificates and proxies, with the project's service names added to `NO_PROXY`. See `ImageBuildNetwork`.
    public func imageBuildNetwork(for directory: String? = nil) -> (network: ImageBuildNetwork, noProxyExtra: [String]) {
        let services = directory.flatMap { project(containing: $0) }?.services.map(\.name).sorted() ?? []
        return (ImageBuildNetwork(network.corporate), services)
    }

    /// Saves the person's choice (ignored where an administrator's key applies) and applies it.
    public func setNetworkSettings(_ settings: NetworkSettings) async {
        try? await store.setPreference(NetworkSettings.preferenceKey, settings)
        await refreshCorporateNetwork()
    }

    public func networkSettings() async -> NetworkSettings {
        (try? await store.preference(NetworkSettings.preferenceKey, as: NetworkSettings.self)) ?? NetworkSettings()
    }

    /// Fetches the diagnostics URLs from inside a ready workspace container (the given project's, else any) and from the
    /// Mac, and reports what each saw.
    public func runNetworkDiagnostics(directory: String? = nil) async {
        guard !network.isDiagnosing else { return }
        network.isDiagnosing = true
        defer { network.isDiagnosing = false }
        let urls = network.diagnosticsURLs
        var run = NetworkDiagnostics()
        let model = directory.flatMap { project(containing: $0) }.flatMap { $0.phase == .ready ? $0 : nil }
            ?? models.values.sorted { $0.directory < $1.directory }.first { $0.phase == .ready }
        if let model, let container = model.record.containerID, let spec = workspaceSpec(model) {
            run.project = (model.directory as NSString).lastPathComponent
            do {
                run.container = try await activeRuntime.diagnose(container: container, user: spec.user, urls: urls)
            } catch {
                run.containerProblem = "The probe could not run in \(run.project ?? "the container"): \(Self.describe(error))"
            }
        } else {
            run.containerProblem = "No project's container is running. Open a project's thread (or Project Settings ▸ Environment ▸ Start) and run the diagnostics again."
        }
        let enterprise = network.candidates.filter { network.selected.contains($0.fingerprint) }
        run.mac = await NetworkHostProbe.fetch(urls, opencodeAnchors: configuration?.certificateSource.systemAnchors() ?? [],
                                               enterprise: enterprise.map(\.der))
        let names = enterprise.map(\.subject)
        run.interceptedBy = Array(Set((run.container + run.mac).compactMap(\.issuer).filter { issuer in
            names.contains { !$0.isEmpty && issuer.contains($0) }
        })).sorted()
        network.diagnostics = run
    }

    /// Environment for the supervised opencode process: the enterprise roots for its Bun runtime and the proxies (Bun
    /// does not read macOS proxy settings). Computed at each server launch.
    public nonisolated static func serverEnvironment(enterpriseBundle: URL?, proxy: SystemProxySettings, managed: ManagedNetworkPolicy.Managed?)
        -> [String: String] {
        var environment: [String: String] = [:]
        if let enterpriseBundle, let data = FileManager.default.contents(atPath: enterpriseBundle.path), !data.isEmpty {
            environment["NODE_EXTRA_CA_CERTS"] = enterpriseBundle.path
        }
        let http = managed?.setsProxy == true ? managed?.httpProxy : proxy.httpProxy
        let https = managed?.setsProxy == true ? managed?.httpsProxy : proxy.httpsProxy
        let noProxy = managed?.setsProxy == true ? (managed?.noProxy ?? []) : proxy.noProxy
        if let http { environment["HTTP_PROXY"] = http }
        if let https { environment["HTTPS_PROXY"] = https }
        if http != nil || https != nil { environment["NO_PROXY"] = CorporateNetwork.composeNoProxy(noProxy, extra: []) }
        return environment
    }
}

/// The diagnostics fetch from the Mac: the server's certificate chain is captured, and evaluated against what opencode
/// trusts (the built-in roots plus the enterprise bundle it is given), not against the Mac's full trust settings.
enum NetworkHostProbe {
    final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        let anchors: [SecCertificate]
        let captured = Captured()

        /// Written by the delegate callback before the task completes, read after.
        final class Captured: Sendable {
            private let state = Mutex<(issuer: String?, trusted: Bool?)>((nil, nil))
            var issuer: String? { state.withLock { $0.issuer } }
            var trusted: Bool? { state.withLock { $0.trusted } }
            func set(issuer: String?, trusted: Bool) { state.withLock { $0 = (issuer, trusted) } }
        }

        init(anchors: [SecCertificate]) { self.anchors = anchors }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            // The issuer of the presented certificate: the subject of the next certificate in the chain.
            let issuer = chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : chain.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            var copy: SecTrust?
            var opencodeTrusts = false
            if SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString), &copy) == errSecSuccess,
               let copy {
                SecTrustSetAnchorCertificates(copy, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(copy, true)
                opencodeTrusts = SecTrustEvaluateWithError(copy, nil)
            }
            captured.set(issuer: issuer, trusted: opencodeTrusts)
            return (.performDefaultHandling, nil)
        }
    }

    @concurrent
    static func fetch(_ urls: [String], opencodeAnchors: [Data], enterprise: [Data]) async -> [NetworkProbeResult] {
        let anchors = (opencodeAnchors + enterprise).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var results: [NetworkProbeResult] = []
        for text in urls {
            guard let url = URL(string: text) else {
                results.append(NetworkProbeResult(url: text, ok: false, error: "not a URL", tool: "URLSession"))
                continue
            }
            let delegate = Delegate(anchors: anchors)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            var result = NetworkProbeResult(url: text, ok: false, tool: "URLSession")
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    result.status = http.statusCode
                    result.proxyHeaders = http.allHeaderFields.compactMap { key, value in
                        guard let name = key as? String, NetworkProbeResult.isProxyHeader(name) else { return nil }
                        return "\(name): \(value)"
                    }.sorted()
                }
                result.ok = true
            } catch {
                result.error = error.localizedDescription
            }
            result.issuer = delegate.captured.issuer
            if url.scheme == "https", delegate.captured.trusted == false {
                result.ok = false
                result.error = (result.error.map { $0 + "; " } ?? "") + "opencode would not trust this certificate (its issuer is not in the Mac's built-in roots or the selected enterprise roots)"
            }
            results.append(result)
        }
        return results
    }
}
