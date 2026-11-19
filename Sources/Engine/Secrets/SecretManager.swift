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

    /// The administrator's `EgressEnforced` (forced in domain `com.bellocode.app`) wins; otherwise the person's
    /// `secrets.enforceEgress` (default on).
    public static func egressEnforced(userDefaults: UserDefaults) -> Bool {
        let key = "EgressEnforced" as CFString
        let domain = "com.bellocode.app" as CFString
        if CFPreferencesAppValueIsForced(key, domain), let forced = CFPreferencesCopyAppValue(key, domain) as? Bool { return forced }
        return userDefaults.object(forKey: "secrets.enforceEgress") as? Bool ?? true
    }

    public static var egressForcedByAdministrator: Bool {
        CFPreferencesAppValueIsForced("EgressEnforced" as CFString, "com.bellocode.app" as CFString)
    }

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
    /// Secret settings that could not be read (R09): shown in Settings ▸ Secrets. Nil when all were read.
    public private(set) var metadataProblem: String?
    /// Accounts whose metadata row exists but cannot be read: quarantined (no use of any kind) until deleted.
    public private(set) var quarantinedAccounts: Set<String> = []

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
    @ObservationIgnored var scopes: [String: EgressScope] = [:]
    @ObservationIgnored private var gatewaySetups: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var pendingAudit: [SecretAuditEntry] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored var codeRoots: () -> [String] = { [] }
    /// Per-binding use counts shared by the proxy and the brokered tool (R12).
    @ObservationIgnored let useLedger = SecretUseLedger()
    /// The shared browser's routing (docs/features/shared-browser.md): wraps the configured router before the proxy
    /// starts, so `*.bc` names reach project containers. Nil: the configured router alone.
    @ObservationIgnored public var routerOverride: (@Sendable (any EgressRouter) -> any EgressRouter)?
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

    /// Stops the proxy and removes this launch's gateways (their tokens die with the proxy; the next launch makes new
    /// ones). Internal networks still used by a (stopped) workspace stay; unattached ones go.
    func stop() async {
        tasks.cancelAll()
        proxy?.stop()
        proxy = nil
        egressStatus = .off
        started = false
        let keys = Array(scopes.keys)
        scopes = [:]
        gatewaySetups.values.forEach { $0.cancel() }
        gatewaySetups = [:]
        guard !keys.isEmpty, let socket = environments?.activeRuntime.socketPath else { return }
        let gateway = EgressGateway(client: EngineClient(socketPath: socket))
        for key in keys { await gateway.remove(scopeKey: key, network: true) }
    }

    /// The smoke test's check that a workspace really sits behind the egress boundary: only the internal network, the
    /// proxy variables set, external names unresolvable. Nil when it holds, else what does not.
    public func verifyEgress(projectDirectory: String) async -> String? {
        guard case .ready = egressStatus, let socket = environments?.activeRuntime.socketPath else { return "the egress proxy is not running" }
        let client = EngineClient(socketPath: socket)
        let name = WorkspaceSpec.containerName(for: projectDirectory)
        do {
            guard let inspect = try await client.inspectContainer(name) else { return "no workspace container" }
            let network = EgressGateway.networkName(WorkspaceSpec.projectKey(for: projectDirectory))
            guard inspect.hostConfig?.networkMode == network else { return "the workspace is on \(inspect.hostConfig?.networkMode ?? "?"), not \(network)" }
            guard try await client.inspectNetwork(network)?.isInternal == true else { return "\(network) is not internal" }
            let probe = try await ExecSession.run(client: client, container: inspect.id, argv: ["/bin/sh", "-c", "echo \"$HTTPS_PROXY\"; getent hosts example.com >/dev/null 2>&1 && echo resolved || echo unresolved"], timeout: .seconds(20))
            let text = String(decoding: probe.stdout, as: UTF8.self)
            guard text.contains(EgressAttachment.proxyURL) else { return "HTTPS_PROXY is not BelloCode's proxy" }
            guard text.contains("unresolved") else { return "external names resolve inside the workspace" }
            return nil
        } catch {
            return "egress check failed (\(error))"
        }
    }

    /// Loads secrets, placeholders and the recent audit; secrets saved before modes become visible-mode secrets that
    /// work only through approved commands until the person chooses a mode.
    ///
    /// Fails closed (R09): if the metadata cannot be queried, nothing is adopted or rewritten and no secret is usable
    /// (the error is shown); a row that cannot be decoded quarantines its account (kept, never replaced, unusable)
    /// instead of letting a surviving legacy label re-adopt it as a commands-only secret without its revocation,
    /// scope or bindings. Only accounts with no metadata row at all are adopted, by an insert that never replaces.
    public func reload() async {
        let rows: ProjectionStore.ManagedSecretRows
        do {
            rows = try await store.managedSecretRows()
        } catch {
            secrets = []
            metadataProblem = "BelloCode could not read its secret settings, so no secret can be used until they can be read. Nothing was changed. Restart BelloCode; if this continues, the local database may be damaged."
            log.error("secret metadata unreadable; all managed secrets unavailable")
            await refreshProxySnapshot()
            return
        }
        var loaded = rows.secrets
        var quarantined = Set(rows.unreadable)
        let known = Set(loaded.map(\.account)).union(quarantined)
        for label in legacy.labels where !known.contains(label.account) {
            let adopted = ManagedSecret(account: label.account, name: uniqueHandle(ManagedSecret.handle(from: label.label), in: loaded),
                                        label: label.label, mode: .visible, created: label.created)
            do {
                if try await store.adoptLegacySecret(adopted) { loaded.append(adopted) } else { quarantined.insert(label.account) }
            } catch {
                // Not recorded: not usable either (adopted on a later reload).
                quarantined.insert(label.account)
            }
        }
        quarantinedAccounts = quarantined
        if quarantined.isEmpty {
            metadataProblem = nil
        } else {
            let names = legacy.labels.filter { quarantined.contains($0.account) }.map { "“\($0.label)”" }
            let what = names.isEmpty ? "\(quarantined.count) secret\(quarantined.count == 1 ? "" : "s")" : names.sorted().joined(separator: ", ")
            metadataProblem = "The settings of \(what) could not be read, so \(quarantined.count == 1 ? "it is" : "they are") unavailable to agents and commands. Delete \(quarantined.count == 1 ? "it" : "them") and save again."
        }
        secrets = loaded.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        useLedger.seed(secrets)
        grants = Dictionary(((try? await store.placeholderGrants()) ?? []).map { ($0.placeholder, $0) }, uniquingKeysWith: { a, _ in a })
        recentAudit = (try? await store.auditEntries(limit: 100)) ?? []
        await refreshProxySnapshot()
    }

    public func secret(_ account: String) -> ManagedSecret? { secrets.first { $0.account == account } }

    /// The approved-command path's authorization (R03): the secret's current policy revision when commands may receive
    /// it now (a commands-only or visible secret, not revoked, in scope for `projectDirectory`), else nil. References
    /// and approvals carry the revision they were issued under; any change of mode, scope, confirmation, revocation or
    /// value changes it, so they stop working.
    public func commandRevision(account: String, projectDirectory: String?) -> String? {
        guard let secret = secret(account), secret.mode == .visible, !secret.revoked else { return nil }
        if let projectDirectory, !projectDirectory.isEmpty,
           !secret.scope.admits(projectDirectory: projectDirectory, codeRoots: codeRoots()) { return nil }
        return Self.policyRevision(secret)
    }

    /// Strictly later than the previous rotation, so every rotation changes the policy revision (even within one clock tick).
    nonisolated static func nextRotation(after previous: Date?, now: Date) -> Date {
        guard let previous, previous >= now else { return now }
        return previous.addingTimeInterval(0.001)
    }

    nonisolated static func policyRevision(_ secret: ManagedSecret) -> String {
        let scope: String = switch secret.scope {
        case .global: "global"
        case .codeRoots: "code-roots"
        case .project(let root): "project:" + root
        }
        let parts = [secret.account, secret.mode.rawValue, secret.revoked ? "revoked" : "live", secret.visibleConfirmed ? "confirmed" : "commands",
                     scope, String(secret.rotated?.timeIntervalSince1970 ?? 0), String(secret.created.timeIntervalSince1970)]
        return SHA256Hex.of(parts.joined(separator: "\u{1F}"))
    }
    /// The label a quarantined account was saved under (Settings shows it; never the value).
    public func legacyLabel(account: String) -> String? { legacy.labels.first { $0.account == account }?.label }

    public func secret(named name: String) -> ManagedSecret? { secrets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Placeholder mode needs the proxy: unavailable (never silently downgraded) when egress is not enforced.
    public var placeholdersAvailable: Bool {
        if case .ready = egressStatus { return true }
        return false
    }

    // MARK: Create, change, rotate, revoke, delete

    /// Saves a new secret (value to the Keychain, the rest to the store). Visible mode requires `confirmVisible`, unless
    /// `commandsOnly`: the "Approved command" choice (R25), stored as an unconfirmed visible secret that only commands
    /// the person approves receive (never the thread's environment).
    @discardableResult
    public func create(label: String, name: String? = nil, value: SecretValue, mode: SecretUseMode, scope: SecretScope = .global,
                       bindings: [SecretBinding] = [], confirmVisible: Bool = false, commandsOnly: Bool = false) async throws -> ManagedSecret {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtrasError("Give the secret a label.") }
        guard secrets.count < Self.maxSecrets else { throw ExtrasError("BelloCode keeps at most \(Self.maxSecrets) secrets.") }
        guard !commandsOnly || (mode == .visible && !confirmVisible) else { throw ExtrasError("A commands-only secret is never visible to the agent.") }
        try validate(mode: mode, bindings: bindings, value: value, confirmVisible: confirmVisible || commandsOnly)
        let handle = name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? ManagedSecret.handle(from: trimmed)
        guard ManagedSecret.isValidHandle(handle) else { throw ExtrasError("“\(handle)” cannot be a name (letters, digits and _; not PATH, HOME or a proxy variable).") }
        if let other = secret(named: handle), other.label.caseInsensitiveCompare(trimmed) != .orderedSame {
            throw ExtrasError("Another secret is already named \(handle).")
        }
        // A quarantined secret's settings (perhaps a revocation) are never overwritten by a new save (R09).
        if let existing = legacy.account(forLabel: trimmed), quarantinedAccounts.contains(existing) {
            throw ExtrasError("“\(trimmed)” has settings BelloCode cannot read. Delete it in Settings ▸ Secrets first.")
        }
        let account = try await legacy.save(label: trimmed, value: value)
        let replaced = self.secret(account) != nil
        var secret = self.secret(account) ?? ManagedSecret(account: account, name: handle, label: trimmed, mode: mode, created: clock.now())
        // A new value under an existing label is a rotation: outstanding command references and approvals end (R03).
        if replaced { secret.rotated = Self.nextRotation(after: secret.rotated, now: clock.now()) }
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
        } else if current.scope != next.scope {
            // Narrowed scope (R13): threads of projects it no longer admits lose their placeholder or visible value now.
            let roots = codeRoots()
            await dropGrants(account: next.account) { !next.scope.admits(projectDirectory: $0.projectDirectory, codeRoots: roots) }
        }
        await refreshProxySnapshot()
    }

    /// Replaces the value; placeholders stay the same (programs and files keep working).
    public func rotate(account: String, value: SecretValue) async throws {
        guard var secret = secret(account) else { throw ExtrasError("That secret no longer exists.") }
        try validate(mode: secret.mode, bindings: secret.bindings, value: value, confirmVisible: true)
        _ = try await legacy.save(label: secret.label, value: value)
        secret.rotated = Self.nextRotation(after: secret.rotated, now: clock.now())
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
        if quarantinedAccounts.remove(account) != nil, quarantinedAccounts.isEmpty { metadataProblem = nil }
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

    public func placeholder(account: String, sessionID: SessionID) -> String? {
        grants.values.first { $0.account == account && $0.sessionID == sessionID.rawValue && Placeholder.isPlaceholder($0.placeholder) }?.placeholder
    }

    private func dropGrants(account: String) async {
        let sessions = Set(grants.values.filter { $0.account == account }.map(\.sessionID))
        grants = grants.filter { $0.value.account != account }
        try? await store.deletePlaceholderGrants(account: account)
        for session in sessions { await applyEnvironment(session) }
    }

    /// Drops the secret's grants matching `predicate` and replaces the affected threads' environments.
    private func dropGrants(account: String, where predicate: (PlaceholderGrant) -> Bool) async {
        let dropped = grants.values.filter { $0.account == account && predicate($0) }
        guard !dropped.isEmpty else { return }
        for grant in dropped { grants[grant.placeholder] = nil }
        try? await store.deletePlaceholderGrants(placeholders: dropped.map(\.placeholder))
        for session in Set(dropped.map(\.sessionID)) { await applyEnvironment(session) }
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
        variables.merge(await secretVariables(for: session)) { _, secret in secret }
        return variables
    }

    /// The thread's secret variables: each grant's secret only while it is live, in its current mode and its current
    /// scope admits the grant's project (R13: checked at every delivery, not only when granted).
    func secretVariables(for session: String) async -> [String: String] {
        var variables: [String: String] = [:]
        let roots = codeRoots()
        for grant in grants.values where grant.sessionID == session {
            guard let secret = secret(grant.account), !secret.revoked,
                  secret.scope.admits(projectDirectory: grant.projectDirectory, codeRoots: roots) else { continue }
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

    /// Snapshot harness only: shows the proxy as running (mock mode has no containers) so the UI's placeholder states
    /// render. Never called by the app.
    public func showEgressRunningForSnapshots(port: UInt16, fingerprint: String) {
        egressStatus = .ready(port: port)
        authorityFingerprint = fingerprint
    }

    /// Snapshot harness only: an audit entry as the proxy would record it.
    public func recordForSnapshots(_ entry: SecretAuditEntry) async { await record(entry) }

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

    /// A proxy substitution happened: its count (already reserved in the ledger) is persisted.
    func noteUse(account: String, bindingID: String) async {
        _ = await recordUses([SubstitutionUse(account: account, bindingID: bindingID, sessionID: "", placeholder: "")])
    }

    /// Persists the ledger's counts for these uses (idempotent: counts only rise to the ledger's). False when a count
    /// could not be stored, which refuses a request on a limited binding (R12).
    func recordUses(_ uses: [SubstitutionUse]) async -> Bool {
        var stored = true
        for account in Set(uses.map(\.account)) {
            guard let index = secrets.firstIndex(where: { $0.account == account }) else { stored = false; continue }
            for use in uses where use.account == account {
                secrets[index].uses[use.bindingID] = max(secrets[index].uses[use.bindingID] ?? 0, useLedger.count(account: account, bindingID: use.bindingID))
            }
            do { try await store.saveManagedSecret(secrets[index]) } catch { stored = false }
        }
        return stored
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
            var proxyConfiguration = configuration.proxy
            if let routerOverride { proxyConfiguration.router = routerOverride(proxyConfiguration.router) }
            let proxy = EgressProxy(authority: authority, configuration: proxyConfiguration, ledger: useLedger)
            proxy.setUseRecorder { [weak self] uses in await self?.recordUses(uses) ?? false }
            let port = try await proxy.start()
            self.proxy = proxy
            try await writeCertificates(configuration, authority: authority)
            egressStatus = .ready(port: port)
            proxy.setScopes(Array(scopes.values))
            proxy.setDockerEndpointPort(environments?.dockerEndpointPort.map { UInt16($0) })
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
            attachment: { [weak self] scopeKey, services in
                guard let self else { return nil }
                return self.attachment(scopeKey: scopeKey, services: services, certificates: directory)
            },
            preflight: { [weak self] spec in try await self?.preflight(spec) },
            servicesStarted: { [weak self] model in self?.attachServices(model) },
            dockerEndpointStarted: { [weak self] in self?.refreshGateways() })
        environments.scheduleConfigWrite()
    }

    func attachment(scopeKey: String, services: [String], certificates: URL) -> (EgressAttachment, CorporateNetwork?) {
        let fingerprint = authorityFingerprint ?? "unavailable"
        let attachment = EgressAttachment(network: EgressGateway.networkName(scopeKey), caFingerprint: fingerprint, noProxy: services)
        var corporate = environments?.network.corporate ?? CorporateNetwork()
        corporate.certificateDirectory = certificates.path
        corporate.certificateFingerprint = SHA256Hex.of((corporate.certificateFingerprint ?? "") + fingerprint)
        return (attachment, corporate)
    }

    /// Before a workspace container starts: its gateway runs and its scope is registered with the proxy.
    nonisolated func preflight(_ spec: WorkspaceSpec) async throws {
        guard spec.egress != nil else { return }
        try await ensureGateway(spec)
    }

    /// One gateway setup per scope at a time: workspaces sharing a scope (the shared workspace serves several
    /// repositories) wait for the same setup instead of racing to recreate the gateway.
    func ensureGateway(_ spec: WorkspaceSpec) async throws {
        guard let egress = spec.egress else { return }
        if let running = gatewaySetups[egress.scopeKey] { return try await running.value }
        guard let (port, token, socket) = prepareScope(spec) else {
            throw EgressGatewayError("BelloCode's egress proxy is not running, so this project's container has no network. Open Settings ▸ Secrets.")
        }
        let gatewaySpec = Self.gatewaySpec(for: spec, proxyPort: port, token: token)
        let setup = Task { try await EgressGateway(client: EngineClient(socketPath: socket)).ensure(gatewaySpec) }
        gatewaySetups[egress.scopeKey] = setup
        defer { gatewaySetups[egress.scopeKey] = nil }
        try await setup.value
    }

    /// A workspace's gateway: BelloCode's own image whatever the workspace runs (R08: the token and the outbound bridge
    /// never reach project-controlled code), in every execution mode that has a workspace.
    nonisolated static func gatewaySpec(for spec: WorkspaceSpec, proxyPort: UInt16, token: String) -> EgressGatewaySpec {
        EgressGatewaySpec(scopeKey: spec.egress?.scopeKey ?? spec.projectKey, image: nil, proxyPort: Int(proxyPort), token: token,
                          extraLabels: spec.extraLabels)
    }

    /// The filtered Docker endpoint (execution modes) started: gateways relay workspace `docker` through the proxy to it.
    func refreshGateways() {
        proxy?.setDockerEndpointPort(environments?.dockerEndpointPort.map { UInt16($0) })
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

    /// Projects with a container environment (for the raw-egress allowlist editor).
    public var egressProjects: [String] { environments.map { Array($0.models.keys).sorted() } ?? [] }

    /// The person's switch (takes effect at the next launch; an administrator's `EgressEnforced` wins).
    public var enforceEgressSetting: Bool {
        get { SecretManagerConfiguration.egressEnforced(userDefaults: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: "secrets.enforceEgress") }
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
        proxy.update(EgressSnapshot(grants: placeholderGrants, secrets: Dictionary(hidden.map { ($0.account, $0) }, uniquingKeysWith: { a, _ in a }),
                                    values: values, codeRoots: codeRoots()))
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
