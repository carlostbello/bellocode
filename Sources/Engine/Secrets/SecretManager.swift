import BelloCore
import ContainerKit
import CryptoKit
import Foundation
import Observation
import OpenCodeKit
import SecretKit
import os

/// What the app gives the secret manager (docs/features/secrets.md). Nil in `EngineConfiguration`: no enforced egress
/// (tests, mock mode); brokered and visible secrets still work.
public struct SecretManagerConfiguration: Sendable {
    /// Where the proxy CA's certificate and the container certificate bundles are written (public material only).
    public var directory: URL
    /// The CA's private key (Keychain service `app.bellocode.egress-ca`).
    public var authorityVault: any SecretVault
    /// Route workspace containers through BelloCode's egress proxy (administrators can force it, `EgressEnforced`).
    public var enforceEgress: Bool
    /// Proxy settings (tests inject loopback test servers).
    public var proxy: EgressProxyConfiguration
    /// The Mac's built-in roots (DER) for the containers' full bundle when the enterprise bundle is off.
    public var systemAnchors: @Sendable () -> [Data]

    public init(directory: URL, authorityVault: any SecretVault = KeychainSecretVault(service: SecretManager.authorityService),
                enforceEgress: Bool = true, proxy: EgressProxyConfiguration = .init(),
                systemAnchors: @escaping @Sendable () -> [Data] = { KeychainCertificateSource().systemAnchors() }) {
        self.directory = directory
        self.authorityVault = authorityVault
        self.enforceEgress = enforceEgress
        self.proxy = proxy
        self.systemAnchors = systemAnchors
    }
}

/// A secret BelloCode already uses only through a built-in broker (shown read-only in Settings ▸ Secrets).
public struct BuiltInBrokeredSecret: Sendable, Hashable, Identifiable {
    public var id: String { label + destination }
    public var label: String
    public var destination: String
    public var operations: String
    public var problem: String?
}

/// Where the egress proxy stands.
public enum EgressStatus: Sendable, Equatable {
    case off
    case starting
    case ready(port: UInt16)
    case failed(String)

    public var title: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .ready: "Running"
        case .failed: "Failed"
        }
    }
}

/// The secret manager (docs/features/secrets.md): one store of secrets by label (values only in the Keychain), each with
/// a scope and a use mode: **brokered** (BelloCode performs the operation), **placeholder** (the agent's programs get
/// a `bcsec_…` placeholder; BelloCode's egress proxy swaps the value in only for bound destinations and scans what
/// comes back) or **visible** (the agent receives the value; labelled and confirmed). Owns the egress proxy, its CA,
/// the per-thread placeholders, the gateways' scopes, the brokered HTTP tool and the audit.
///
/// Threading: `@MainActor`, owned by `Engine`; Keychain reads run off the main actor; the proxy's work runs on its own
/// queue and reports through its event stream, consumed by one owned task.
@MainActor
@Observable
public final class SecretManager {
    public private(set) var secrets: [ManagedSecret] = []
    public private(set) var recentAudit: [SecretAuditEntry] = []
    public private(set) var egressStatus: EgressStatus = .off
    public private(set) var lastError: String?
    /// The CA containers trust for the proxy (SHA-256), for Settings.
    public private(set) var authorityFingerprint: String?
    /// The audit had to drop events (the consumer fell behind): shown as a gap.
    public private(set) var auditGap = 0

    nonisolated public static let authorityService = "app.bellocode.egress-ca"
    nonisolated static let authorityAccount = "authority-key"
    nonisolated public static let maxSecrets = 200

    @ObservationIgnored let store: ProjectionStore
    @ObservationIgnored let vault: any SecretVault
    @ObservationIgnored let legacy: SecretService
    @ObservationIgnored let clock: any WallClock
    @ObservationIgnored let configuration: SecretManagerConfiguration?
    @ObservationIgnored weak var engine: Engine?
    @ObservationIgnored var environments: EnvironmentService?
    @ObservationIgnored private(set) var grants: [String: PlaceholderGrant] = [:]
    @ObservationIgnored var proxy: EgressProxy?
    @ObservationIgnored private var scopes: [String: EgressScope] = [:]
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var pendingAudit: [SecretAuditEntry] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored var codeRoots: () -> [String] = { [] }
    /// GitLab instances and the like, for the read-only "built-in brokered" rows.
    @ObservationIgnored public var builtInBrokered: () -> [BuiltInBrokeredSecret] = { [] }
    @ObservationIgnored let log = Logger(subsystem: "app.bellocode", category: "secret-manager")
    @ObservationIgnored let signposts = OSSignposter(subsystem: "app.bellocode", category: "secret-manager")

    init(store: ProjectionStore, vault: any SecretVault, legacy: SecretService, clock: any WallClock, configuration: SecretManagerConfiguration?) {
        self.store = store
        self.vault = vault
        self.legacy = legacy
        self.clock = clock
        self.configuration = configuration
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await reload()
        if let configuration, configuration.enforceEgress, environments?.isEnabled == true {
            await startEgress(configuration)
        }
        let connection = store.observe(.connection)
        tasks.set("reapply-environment", Task { [weak self] in
            for await change in connection {
                guard let self, change.connection == .live else { continue }
                await self.reapplyAllEnvironments()
            }
        })
    }

    func stop() {
        tasks.cancelAll()
        proxy?.stop()
        proxy = nil
        egressStatus = .off
        started = false
    }

    /// Loads secrets, placeholders and the recent audit; secrets saved before modes become visible-mode secrets that
    /// work only through approved commands until the person chooses a mode.
    public func reload() async {
        var loaded = (try? await store.managedSecrets()) ?? []
        let known = Set(loaded.map(\.account))
        for label in legacy.labels where !known.contains(label.account) {
            let adopted = ManagedSecret(account: label.account, name: uniqueHandle(ManagedSecret.handle(from: label.label), in: loaded),
                                        label: label.label, mode: .visible, created: label.created)
            loaded.append(adopted)
            try? await store.saveManagedSecret(adopted)
        }
        secrets = loaded.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        grants = Dictionary(((try? await store.placeholderGrants()) ?? []).map { ($0.placeholder, $0) }, uniquingKeysWith: { a, _ in a })
        recentAudit = (try? await store.auditEntries(limit: 100)) ?? []
        await refreshProxySnapshot()
    }

    public func secret(_ account: String) -> ManagedSecret? { secrets.first { $0.account == account } }
    public func secret(named name: String) -> ManagedSecret? { secrets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Placeholder mode needs the proxy: unavailable (never silently downgraded) when egress is not enforced.
    public var placeholdersAvailable: Bool {
        if case .ready = egressStatus { return true }
        return false
    }

    // MARK: Create, change, rotate, revoke, delete

    /// Saves a new secret (value to the Keychain, the rest to the store). Visible mode requires `confirmVisible`.
    @discardableResult
    public func create(label: String, name: String? = nil, value: SecretValue, mode: SecretUseMode, scope: SecretScope = .global,
                       bindings: [SecretBinding] = [], confirmVisible: Bool = false) async throws -> ManagedSecret {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtrasError("Give the secret a label.") }
        guard secrets.count < Self.maxSecrets else { throw ExtrasError("BelloCode keeps at most \(Self.maxSecrets) secrets.") }
        try validate(mode: mode, bindings: bindings, value: value, confirmVisible: confirmVisible)
        let handle = name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? ManagedSecret.handle(from: trimmed)
        guard ManagedSecret.isValidHandle(handle) else { throw ExtrasError("“\(handle)” cannot be a name (letters, digits and _; not PATH, HOME or a proxy variable).") }
        if let other = secret(named: handle), other.label.caseInsensitiveCompare(trimmed) != .orderedSame {
            throw ExtrasError("Another secret is already named \(handle).")
        }
        let account = try await legacy.save(label: trimmed, value: value)
        var secret = self.secret(account) ?? ManagedSecret(account: account, name: handle, label: trimmed, mode: mode, created: clock.now())
        secret.name = handle
        secret.mode = mode
        secret.scope = scope
        secret.bindings = bindings
        secret.visibleConfirmed = mode == .visible && confirmVisible
        secret.revoked = false
        if mode == .brokered, secret.operation == nil { secret.operation = "http" }
        try await persist(secret)
        await record(SecretAuditEntry(account: account, at: clock.now(), destination: "", outcome: .created, detail: mode.title))
        await refreshProxySnapshot()
        log.info("secret saved (value in Keychain only)")
        return secret
    }

    /// Changes mode, scope, bindings or name (never the value: `rotate`). Leaving placeholder mode drops its placeholders.
    public func update(_ changed: ManagedSecret, confirmVisible: Bool = false) async throws {
        guard let current = secret(changed.account) else { throw ExtrasError("That secret no longer exists.") }
        try validate(mode: changed.mode, bindings: changed.bindings, value: nil, confirmVisible: confirmVisible || current.visibleConfirmed && changed.mode == .visible)
        guard ManagedSecret.isValidHandle(changed.name) else { throw ExtrasError("“\(changed.name)” cannot be a name.") }
        if let other = secret(named: changed.name), other.account != changed.account { throw ExtrasError("Another secret is already named \(changed.name).") }
        var next = changed
        next.visibleConfirmed = changed.mode == .visible && (confirmVisible || current.visibleConfirmed)
        try await persist(next)
        if current.mode != next.mode || current.name != next.name {
            await dropGrants(account: next.account)
        }
        await refreshProxySnapshot()
    }

    /// Replaces the value; placeholders stay the same (programs and files keep working).
    public func rotate(account: String, value: SecretValue) async throws {
        guard var secret = secret(account) else { throw ExtrasError("That secret no longer exists.") }
        try validate(mode: secret.mode, bindings: secret.bindings, value: value, confirmVisible: true)
        _ = try await legacy.save(label: secret.label, value: value)
        secret.rotated = clock.now()
        try await persist(secret)
        await record(SecretAuditEntry(account: account, at: clock.now(), destination: "", outcome: .rotated, detail: "New value; placeholders unchanged"))
        await refreshProxySnapshot()
        if secret.mode == .visible { await reapplyEnvironments(account: account) }
    }

    /// Stops every use at once (placeholders refused, brokered calls refused); the value stays until deleted.
    public func revoke(account: String) async throws {
        guard var secret = secret(account) else { return }
        secret.revoked = true
        try await persist(secret)
        await dropGrants(account: account)
        await record(SecretAuditEntry(account: account, at: clock.now(), destination: "", outcome: .revoked, detail: "Revoked in Settings"))
        await refreshProxySnapshot()
    }

    public func restore(account: String) async throws {
        guard var secret = secret(account) else { return }
        secret.revoked = false
        try await persist(secret)
        await refreshProxySnapshot()
    }

    /// Deletes the value from the Keychain and every record of the secret (cannot be undone).
    public func delete(account: String) async {
        await dropGrants(account: account)
        await legacy.delete(account: account)
        if let error = legacy.lastError {
            lastError = error
            return
        }
        try? await store.deleteManagedSecret(account: account)
        secrets.removeAll { $0.account == account }
        await refreshProxySnapshot()
    }

    public func audit(account: String, limit: Int = 50) async -> [SecretAuditEntry] {
        (try? await store.auditEntries(account: account, limit: limit)) ?? []
    }

    func validate(mode: SecretUseMode, bindings: [SecretBinding], value: SecretValue?, confirmVisible: Bool) throws {
        if mode == .visible, !confirmVisible { throw ExtrasError("Confirm that the agent may see this value.") }
        if mode == .placeholder, bindings.isEmpty { throw ExtrasError("A placeholder secret needs at least one bound destination.") }
        for binding in bindings {
            if let problem = binding.validationProblems().first { throw ExtrasError("\(binding.origin): \(problem)") }
        }
        if mode != .visible, let value, value.utf8.count < 8 {
            throw ExtrasError("Values shorter than 8 bytes cannot be detected reliably in responses; such a value can only be Visible.")
        }
    }

    private func persist(_ secret: ManagedSecret) async throws {
        try await store.saveManagedSecret(secret)
        if let index = secrets.firstIndex(where: { $0.account == secret.account }) { secrets[index] = secret } else {
            secrets.append(secret)
            secrets.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    private func uniqueHandle(_ base: String, in list: [ManagedSecret]) -> String {
        var candidate = base
        var counter = 2
        while list.contains(where: { $0.name == candidate }) {
            candidate = "\(base)_\(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: Grants (per thread)

    /// The thread's placeholder for a placeholder secret (stable: the same thread always gets the same one), or the
    /// visible secret's grant. Applies the thread's command environment.
    @discardableResult
    func grant(account: String, sessionID: SessionID, projectDirectory: String) async throws -> PlaceholderGrant {
        guard let secret = secret(account), !secret.revoked else { throw ExtrasError("That secret is revoked or gone.") }
        guard secret.scope.admits(projectDirectory: projectDirectory, codeRoots: codeRoots()) else {
            throw ExtrasError("“\(secret.label)” is not available to this project (its scope is \(secret.scope.title)).")
        }
        if let existing = grants.values.first(where: { $0.account == account && $0.sessionID == sessionID.rawValue }) { return existing }
        let marker = secret.mode == .placeholder ? Placeholder.make() : "visible_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let grant = PlaceholderGrant(placeholder: marker, account: account, sessionID: sessionID.rawValue, projectDirectory: projectDirectory, created: clock.now())
        try await store.savePlaceholderGrant(grant)
        grants[marker] = grant
        await refreshProxySnapshot()
        await applyEnvironment(sessionID.rawValue)
        return grant
    }

    func placeholder(account: String, sessionID: SessionID) -> String? {
        grants.values.first { $0.account == account && $0.sessionID == sessionID.rawValue && Placeholder.isPlaceholder($0.placeholder) }?.placeholder
    }

    private func dropGrants(account: String) async {
        let sessions = Set(grants.values.filter { $0.account == account }.map(\.sessionID))
        grants = grants.filter { $0.value.account != account }
        try? await store.deletePlaceholderGrants(account: account)
        for session in sessions { await applyEnvironment(session) }
    }

    /// Threads deleted: their placeholders go.
    func removed(sessions: [SessionID]) async {
        let ids = Set(sessions.map(\.rawValue))
        guard grants.values.contains(where: { ids.contains($0.sessionID) }) else { return }
        grants = grants.filter { !ids.contains($0.value.sessionID) }
        try? await store.deletePlaceholderGrants(sessionIDs: Array(ids))
        await refreshProxySnapshot()
    }

    // MARK: The thread's command environment

    /// Variables a thread's commands get: `NAME=bcsec_…` for its placeholder secrets, `NAME=value` for its visible
    /// ones. Applied with `PUT /api/session/{id}/environment` (which replaces the server's environment for that
    /// session's commands, so the variables the helper needs are included).
    func environmentVariables(for session: String) async -> [String: String] {
        guard let containers = engine?.configuration.containers else { return [:] }
        var variables = [
            "SHELL": containers.helperURL.path, "BELLOCODE_EXEC_PATH": containers.helperURL.path,
            "BELLOCODE_EXEC_CONFIG": containers.execConfigURL.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for grant in grants.values where grant.sessionID == session {
            guard let secret = secret(grant.account), !secret.revoked else { continue }
            switch secret.mode {
            case .placeholder: variables[secret.name] = grant.placeholder
            case .visible where secret.visibleConfirmed:
                if let value = await Self.read(vault, account: secret.account) { variables[secret.name] = String(decoding: value.utf8, as: UTF8.self) }
            default: break
            }
        }
        return variables
    }

    func applyEnvironment(_ session: String) async {
        guard engine?.configuration.containers != nil, let client = try? await engine?.core.currentClient() else { return }
        let variables = await environmentVariables(for: session)
        do {
            try await client.setSessionEnvironment(sessionID: session, variables: variables)
        } catch {
            log.error("session environment not applied: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func reapplyEnvironments(account: String) async {
        for session in Set(grants.values.filter { $0.account == account }.map(\.sessionID)) { await applyEnvironment(session) }
    }

    /// After a reconnect (the server may have restarted, losing session environments).
    func reapplyAllEnvironments() async {
        for session in Set(grants.values.map(\.sessionID)).sorted().prefix(500) { await applyEnvironment(session) }
    }

    // MARK: Values (off the main actor)

    nonisolated static func read(_ vault: any SecretVault, account: String) async -> SecretValue? {
        try? vault.read(account: account)
    }

    nonisolated static func readAll(_ vault: any SecretVault, accounts: [String]) async -> [String: SecretValue] {
        var out: [String: SecretValue] = [:]
        for account in accounts { if let value = try? vault.read(account: account), !value.isEmpty { out[account] = value } }
        return out
    }

    // MARK: Audit

    func record(_ entry: SecretAuditEntry) async {
        pendingAudit.append(entry)
        recentAudit.insert(entry, at: 0)
        if recentAudit.count > 100 { recentAudit.removeLast(recentAudit.count - 100) }
        let batch = pendingAudit
        pendingAudit = []
        try? await store.appendAudit(batch)
    }

    func noteUse(account: String, bindingID: String?) async {
        guard var secret = secret(account) else { return }
        if let bindingID { secret.uses[bindingID, default: 0] += 1 } else { secret.uses["brokered", default: 0] += 1 }
        try? await persist(secret)
    }

    public var lastUse: [String: SecretAuditEntry] {
        var out: [String: SecretAuditEntry] = [:]
        for entry in recentAudit where [.substituted, .brokered, .revealed].contains(entry.outcome) && out[entry.account] == nil { out[entry.account] = entry }
        return out
    }
}

// MARK: - Egress

extension SecretManager {
    func startEgress(_ configuration: SecretManagerConfiguration) async {
        egressStatus = .starting
        do {
            let authority = try await loadAuthority(configuration)
            authorityFingerprint = authority.fingerprint
            let proxy = EgressProxy(authority: authority, configuration: configuration.proxy)
            let port = try await proxy.start()
            self.proxy = proxy
            try await writeCertificates(configuration, authority: authority)
            egressStatus = .ready(port: port)
            proxy.setScopes(Array(scopes.values))
            await refreshProxySnapshot()
            let events = proxy.events
            tasks.set("egress-events", Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.consume(event)
                }
            })
            installHooks()
        } catch {
            egressStatus = .failed(ExtrasError.message(error))
            // Fail closed: containers still get the internal network (no way out) rather than silent direct egress.
            installHooks()
            log.error("egress proxy failed to start")
        }
    }

    /// The CA: its key in the Keychain, its certificate in the data folder; made once.
    func loadAuthority(_ configuration: SecretManagerConfiguration) async throws -> CertificateAuthority {
        let vault = configuration.authorityVault
        let certificateURL = configuration.directory.appending(path: "egress-ca.der")
        let key = await Self.read(vault, account: Self.authorityAccount)
        if let key, let der = try? Data(contentsOf: certificateURL),
           let restored = try? CertificateAuthority(privateKeyData: key.utf8, certificateDER: der) {
            return restored
        }
        let authority = try CertificateAuthority(commonName: "BelloCode Egress CA (\(Host.current().localizedName ?? "this Mac"))")
        try vault.store(account: Self.authorityAccount, label: "BelloCode egress proxy CA key", value: SecretValue(data: try authority.privateKeyData()))
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try authority.certificateDER.write(to: certificateURL, options: .atomic)
        return authority
    }

    nonisolated static func certificateDirectory(_ configuration: SecretManagerConfiguration) -> URL {
        configuration.directory.appending(path: "certs", directoryHint: .isDirectory)
    }

    /// Writes the containers' bundles: the enterprise roots in use (if any) plus the proxy CA, and the full bundle.
    func writeCertificates(_ configuration: SecretManagerConfiguration, authority: CertificateAuthority) async throws {
        let corporate = environments?.network.corporate.certificateDirectory
        let directory = Self.certificateDirectory(configuration)
        let anchors = configuration.systemAnchors
        try await Self.writeBundles(directory: directory, corporate: corporate, caPEM: authority.pem, anchors: anchors)
    }

    nonisolated static func writeBundles(directory: URL, corporate: String?, caPEM: String, anchors: @Sendable () -> [Data]) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var enterprise = ""
        var bundle = ""
        if let corporate {
            enterprise = (try? String(contentsOfFile: corporate + "/" + CorporateNetwork.enterpriseName, encoding: .utf8)) ?? ""
            bundle = (try? String(contentsOfFile: corporate + "/" + CorporateNetwork.bundleName, encoding: .utf8)) ?? ""
        }
        if bundle.isEmpty { bundle = anchors().map(CertificateAuthority.pem).joined() + enterprise }
        if !enterprise.isEmpty, !enterprise.hasSuffix("\n") { enterprise += "\n" }
        if !bundle.isEmpty, !bundle.hasSuffix("\n") { bundle += "\n" }
        for (name, text) in [(CorporateNetwork.enterpriseName, enterprise + caPEM), (CorporateNetwork.bundleName, bundle + caPEM)] {
            let url = directory.appending(path: name)
            try Data(text.utf8).write(to: url, options: .atomic)
            chmod(url.path, 0o644)
        }
    }

    /// Plugs enforced egress into the workspace containers (every project's spec gets the attachment).
    func installHooks() {
        guard let environments, let configuration else { return }
        let directory = Self.certificateDirectory(configuration)
        environments.egress = EgressHooks(
            attachment: { [weak self] model in
                guard let self else { return nil }
                return self.attachment(for: model, certificates: directory)
            },
            preflight: { [weak self] spec in try await self?.preflight(spec) },
            servicesStarted: { [weak self] model in self?.attachServices(model) })
        environments.scheduleConfigWrite()
    }

    func attachment(for model: ProjectEnvironment, certificates: URL) -> (EgressAttachment, CorporateNetwork?) {
        let fingerprint = authorityFingerprint ?? "unavailable"
        let services = model.services.map(\.name).sorted()
        let attachment = EgressAttachment(network: EgressGateway.networkName(model.projectKey), caFingerprint: fingerprint, noProxy: services)
        var corporate = environments?.network.corporate ?? CorporateNetwork()
        corporate.certificateDirectory = certificates.path
        corporate.certificateFingerprint = SHA256Hex.of((corporate.certificateFingerprint ?? "") + fingerprint)
        return (attachment, corporate)
    }

    /// Before a workspace container starts: its gateway runs and its scope is registered with the proxy.
    nonisolated func preflight(_ spec: WorkspaceSpec) async throws {
        guard let egress = spec.egress else { return }
        guard let (port, token, socket) = await prepareScope(spec) else {
            throw EgressGatewayError("BelloCode's egress proxy is not running, so this project's container has no network. Open Settings ▸ Secrets.")
        }
        try await EgressGateway(client: EngineClient(socketPath: socket)).ensure(
            EgressGatewaySpec(scopeKey: egress.scopeKey, image: spec.image, proxyPort: Int(port), token: token, extraLabels: spec.extraLabels))
    }

    /// Registers (or reuses) the scope's token; nil when the proxy is not running.
    private func prepareScope(_ spec: WorkspaceSpec) -> (UInt16, String, String)? {
        guard case .ready(let port) = egressStatus, let proxy, let egress = spec.egress, let socket = environments?.activeRuntime.socketPath else { return nil }
        let roots = spec.workspaceRoots
        let scope = scopes[egress.scopeKey] ?? EgressScope(
            id: egress.scopeKey, token: UUID().uuidString.lowercased() + UUID().uuidString.lowercased(),
            rawAllowlist: rawAllowlist(projectDirectory: spec.projectRoot)) { project in
                roots.contains { project == $0 || project.hasPrefix($0 + "/") } || roots.contains { $0 == project }
            }
        scopes[egress.scopeKey] = scope
        proxy.setScopes(Array(scopes.values))
        return (port, scope.token, socket)
    }

    /// Per-project `host:port` pairs reached without inspection ("no secret protection"), from the project's settings.
    func rawAllowlist(projectDirectory: String) -> Set<HostPort> {
        let entries = (UserDefaults.standard.array(forKey: "secrets.rawEgress.\(projectDirectory)") as? [String]) ?? []
        return Set(entries.compactMap(HostPort.init(authority:)))
    }

    public func rawEgressAllowlist(projectDirectory: String) -> [String] {
        (UserDefaults.standard.array(forKey: "secrets.rawEgress.\(projectDirectory)") as? [String]) ?? []
    }

    public func setRawEgressAllowlist(_ entries: [String], projectDirectory: String) {
        let valid = entries.compactMap(HostPort.init(authority:)).map(\.description)
        UserDefaults.standard.set(valid, forKey: "secrets.rawEgress.\(projectDirectory)")
        if let key = scopes.keys.first(where: { $0 == WorkspaceSpec.projectKey(for: projectDirectory) }), var scope = scopes[key] {
            scope.rawAllowlist = Set(valid.compactMap(HostPort.init(authority:)))
            scopes[key] = scope
            proxy?.setScopes(Array(scopes.values))
        }
    }

    /// Services join the internal network under their names (the workspace reaches them; they keep their own network).
    func attachServices(_ model: ProjectEnvironment) {
        guard let socket = environments?.activeRuntime.socketPath, environments?.egress != nil else { return }
        let network = EgressGateway.networkName(model.projectKey)
        let services = model.services.compactMap { service in service.containerID.map { ($0, service.name) } }
        guard !services.isEmpty else { return }
        tasks.set("egress-services-\(model.projectKey)", Task {
            let client = EngineClient(socketPath: socket)
            for (id, name) in services { try? await client.connectNetwork(network, container: id, aliases: [name]) }
        })
    }

    /// Gives the proxy the current secrets, grants and (in memory) values of placeholder secrets.
    func refreshProxySnapshot() async {
        guard let proxy else { return }
        let hidden = secrets.filter { $0.mode == .placeholder && !$0.revoked }
        let values = await Self.readAll(vault, accounts: hidden.map(\.account))
        let placeholderGrants = grants.filter { Placeholder.isPlaceholder($0.key) }
        proxy.update(EgressSnapshot(grants: placeholderGrants, secrets: Dictionary(hidden.map { ($0.account, $0) }, uniquingKeysWith: { a, _ in a }), values: values))
    }

    /// One proxy event → the audit (and use counts).
    func consume(_ event: EgressEvent) async {
        let now = clock.now()
        switch event {
        case .substituted(let use, let destination, let method, let status):
            await noteUse(account: use.account, bindingID: use.bindingID)
            await record(SecretAuditEntry(account: use.account, at: now, destination: destination, method: method, sessionID: use.sessionID,
                                          outcome: .substituted, detail: "Placeholder replaced by the proxy", status: status))
        case .refused(let reason, let account, let session, let destination, let method):
            guard let account else { return }
            await record(SecretAuditEntry(account: account, at: now, destination: destination, method: method, sessionID: session,
                                          outcome: .refused, detail: reason.code))
        case .responseRedacted(let accounts, let destination, let method, let session):
            for account in accounts {
                await record(SecretAuditEntry(account: account, at: now, destination: destination, method: method, sessionID: session,
                                              outcome: .responseRedacted, detail: "The value in the response was replaced by the placeholder"))
            }
        case .responseBlocked(let accounts, let destination, let method, let reason, let session):
            for account in accounts {
                await record(SecretAuditEntry(account: account, at: now, destination: destination, method: method, sessionID: session,
                                              outcome: .responseBlocked, detail: reason))
            }
        case .rawTunnel, .connectionRefused:
            break
        case .dropped(let count):
            auditGap += count
        }
    }
}
