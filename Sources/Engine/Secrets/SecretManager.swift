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
    /// Threads whose command environment on the server still has to be replaced (the request failed or could not be
    /// sent, typically while cleaning up after a revocation). Kept independently of their remaining grants, retried at
    /// every reconnect until the server acknowledges it, and shown in Settings ▸ Secrets meanwhile (AF26).
    public private(set) var pendingEnvironmentSessions: Set<String> = []
    /// Brokered or placeholder secrets whose stored value is shorter than the response scanner can find reliably (saved
    /// by a release that did not check, AF16). Unusable in their hidden mode (no placeholder substitution, no brokered
    /// request) until rotated to a longer value or made Visible; shown in Settings ▸ Secrets.
    public internal(set) var shortValueAccounts: Set<String> = []

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
    /// The folders each workspace scope serves (its spec's workspace roots), to rebuild it when code roots or raw
    /// allowlists change (N13).
    @ObservationIgnored var scopeRoots: [String: [String]] = [:]
    @ObservationIgnored private var gatewaySetups: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var pendingAudit: [SecretAuditEntry] = []
    @ObservationIgnored private var started = false
    /// Secrets whose value is being replaced right now (A02): a reload leaves their unfinished markers alone.
    @ObservationIgnored private var savingAccounts: Set<String> = []
    /// Labels being saved for the first time (lowercased), so two saves never make two secrets with one label.
    @ObservationIgnored private var savingLabels: Set<String> = []
    /// Accounts with a row write in progress, each with the writers waiting for it (AF03): one account's row writes run
    /// one at a time, each built from the state the previous one left, so the last durable row is the latest state
    /// (a use count never writes back a policy a concurrent revocation replaced).
    @ObservationIgnored private var rowWriters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Increases with every proxy snapshot built; an older one finishing late is never applied over a newer one.
    @ObservationIgnored private var snapshotGeneration = 0
    /// The newest generation published to the proxy (and drained), and the refreshes waiting for it: a refresh a newer
    /// one superseded returns only once that newer snapshot is in the proxy (AF15).
    @ObservationIgnored private var publishedGeneration = 0
    @ObservationIgnored private var snapshotWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Per thread: the newest environment replacement asked for, and the one running (AF26, GV04). Replacements of one
    /// thread are sent one at a time, each computed when its turn comes; one a newer request superseded is skipped.
    @ObservationIgnored private var environmentGeneration: [String: Int] = [:]
    @ObservationIgnored private var environmentWriters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// The newest answered replacement of each thread with replacements running, and the superseded callers waiting
    /// for one at least as new as theirs (AF26).
    @ObservationIgnored private var environmentSettled: [String: Int] = [:]
    @ObservationIgnored private var environmentSettlementWaiters: [String: [(generation: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
    @ObservationIgnored var codeRoots: () -> [String] = { [] }
    /// Tests: extra TLS roots for the brokered tool's loopback servers (added to the configuration's).
    @ObservationIgnored var extraBrokerAnchors: [Data] = []
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
        resumeAllSnapshotWaiters()
        egressStatus = .off
        started = false
        let keys = Array(scopes.keys)
        scopes = [:]
        scopeRoots = [:]
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
        var quarantined = Set(rows.unreadable)
        // A row of any kind (unfinished first saves included) means the label is never adopted as a legacy secret.
        let known = Set(rows.secrets.map(\.account)).union(quarantined)
        var discarded: [String] = []
        var loaded = await recoverInterruptedSaves(rows.secrets, quarantined: &quarantined, discarded: &discarded)
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
        if !discarded.isEmpty {
            lastError = "BelloCode stopped while saving \(discarded.sorted().map { "“\($0)”" }.joined(separator: ", ")); that save was discarded and nothing from it can be used. Save it again."
        }
        secrets = loaded.filter { $0.incomplete != true }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        useLedger.seed(secrets)
        // A hidden value saved before the length check (AF16) is never activated in its hidden mode.
        let hidden = secrets.filter { $0.mode != .visible }
        shortValueAccounts = await Self.shortValues(vault, accounts: hidden.map { ($0.account, $0.activeValueAccount) })
        // Grants that no longer fit their secret (a deletion that failed earlier: revoked, other mode, narrower scope or
        // code roots) are not brought back; their rows are removed again (N13).
        let stored = (try? await store.placeholderGrants()) ?? []
        let roots = codeRoots()
        let valid = stored.filter { grantFits($0, codeRoots: roots) }
        if valid.count != stored.count {
            let keep = Set(valid.map(\.placeholder))
            try? await store.deletePlaceholderGrants(placeholders: stored.map(\.placeholder).filter { !keep.contains($0) })
        }
        grants = Dictionary(valid.map { ($0.placeholder, $0) }, uniquingKeysWith: { a, _ in a })
        recentAudit = (try? await store.auditEntries(limit: 100)) ?? []
        await refreshProxySnapshot()
    }

    /// Finishes or undoes value saves that stopped part-way (A02), except those still running in this launch: a first
    /// save that never activated is removed (its value, label and row; quarantined if that fails), an inactive new value
    /// and retired old values are removed from the Keychain. Returns the rows to load.
    private func recoverInterruptedSaves(_ rows: [ManagedSecret], quarantined: inout Set<String>, discarded: inout [String]) async -> [ManagedSecret] {
        var out: [ManagedSecret] = []
        for row in rows {
            if savingAccounts.contains(row.account) {
                out.append(row)
                continue
            }
            if row.incomplete == true {
                do {
                    for valueAccount in row.allValueAccounts { try vault.delete(account: valueAccount) }
                    try await legacy.forgetLabel(account: row.account)
                    try await store.deleteManagedSecret(account: row.account)
                    discarded.append(row.label)
                } catch {
                    quarantined.insert(row.account)
                }
                continue
            }
            var next = row
            if let pending = row.pendingValueAccount, pending != row.activeValueAccount, (try? vault.delete(account: pending)) != nil {
                next.pendingValueAccount = nil
            }
            if let retired = row.retiredValueAccounts {
                let remaining = retired.filter { $0 == row.activeValueAccount || (try? vault.delete(account: $0)) == nil }
                next.retiredValueAccounts = remaining.filter { $0 != row.activeValueAccount }.nilIfEmpty
            }
            if next != row { try? await store.saveManagedSecret(next) }
            out.append(next)
        }
        return out
    }

    public func secret(_ account: String) -> ManagedSecret? { secrets.first { $0.account == account } }

    /// Whether a stored grant still matches its secret: live, the grant's kind matches the mode, in scope.
    func grantFits(_ grant: PlaceholderGrant, codeRoots roots: [String]) -> Bool {
        guard let secret = secret(grant.account), !secret.revoked,
              secret.scope.admits(projectDirectory: grant.projectDirectory, codeRoots: roots) else { return false }
        return Self.grantKindFits(grant, secret)
    }

    /// Whether the grant is of the kind the secret's mode delivers: a placeholder for placeholder mode, a visibility
    /// grant for visible mode, none for brokered. A thread given a placeholder never receives the value (AF04).
    nonisolated static func grantKindFits(_ grant: PlaceholderGrant, _ secret: ManagedSecret) -> Bool {
        switch secret.mode {
        case .placeholder: Placeholder.isPlaceholder(grant.placeholder)
        case .visible: grant.placeholder.hasPrefix("visible_")
        case .brokered: false
        }
    }

    /// The developer's code roots changed (Settings ▸ Containers ▸ Code roots), N13: grants for projects a secret's scope
    /// no longer admits go now (their threads' environments are replaced), the shared workspace's scope serves only its
    /// current roots, and the proxy gets the new roots.
    func codeRootsDidChange() {
        tasks.set("code-roots", Task { [weak self] in await self?.applyCodeRoots() })
    }

    func applyCodeRoots() async {
        let roots = codeRoots()
        for account in Set(grants.values.map(\.account)) {
            guard let secret = secret(account) else { continue }
            await dropGrants(account: account) { !secret.scope.admits(projectDirectory: $0.projectDirectory, codeRoots: roots) }
        }
        if let environments {
            let key = environments.sharedKey
            if let scope = scopes[key] {
                rebuildScope(key, token: scope.token, roots: environments.sharedSpec()?.workspaceRoots ?? [])
            }
        }
        // Kept-alive connections of the shared workspace are judged by the new scope from their next request; a write
        // the new scope no longer authorizes is cancelled and has ended before this returns (AV2-04).
        await proxy?.publishScopes(Array(scopes.values))
        await refreshProxySnapshot()
    }

    /// The Keychain account an approved command or reference may read for `account`: the value saved together with the
    /// policy revision it was approved or issued under (A02), or nil when that revision no longer holds. Revisions
    /// include the value's account, so a newer value is never read under an older approval.
    public func commandValueAccount(account: String, revision: String, projectDirectory: String?) -> String? {
        guard let current = commandRevision(account: account, projectDirectory: projectDirectory), current == revision else { return nil }
        return secret(account)?.activeValueAccount
    }

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
        let parts: [String] = [secret.account, secret.mode.rawValue, secret.revoked ? "revoked" : "live", secret.visibleConfirmed ? "confirmed" : "commands",
                     scope, String(secret.rotated?.timeIntervalSince1970 ?? 0), String(secret.created.timeIntervalSince1970)]
            + (secret.valueAccount.map { ["value:" + $0] } ?? [])
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
        guard !value.isEmpty else { throw ExtrasError("The value is empty.") }
        guard value.utf8.count <= SecretService.maxValueBytes else {
            throw ExtrasError("The value is longer than \(SecretService.maxValueBytes / 1024) KB, the most a one-read path can carry.")
        }
        let key = trimmed.lowercased()
        guard !savingLabels.contains(key) else { throw ExtrasError("“\(trimmed)” is already being saved.") }
        savingLabels.insert(key)
        defer { savingLabels.remove(key) }
        let now = clock.now()
        let apply: (inout ManagedSecret) -> Void = { secret in
            secret.name = handle
            secret.mode = mode
            secret.scope = scope
            secret.bindings = bindings
            secret.visibleConfirmed = mode == .visible && confirmVisible
            secret.revoked = false
            if mode == .brokered, secret.operation == nil { secret.operation = "http" }
        }
        let saved: ManagedSecret
        if let existing = legacy.account(forLabel: trimmed) {
            guard let previous = self.secret(existing) else { throw ExtrasError("“\(trimmed)” is still being set up. Try again in a moment.") }
            // A new value under an existing label is a rotation: outstanding command references and approvals end (R03).
            saved = try await replaceValue(of: existing, with: value, label: trimmed) { secret in
                apply(&secret)
                secret.rotated = Self.nextRotation(after: secret.rotated, now: now)
            }
            // A new mode, name, confirmation or scope retires the grants threads hold under the old policy (AF04);
            // threads keeping theirs get the new value, as after a rotation.
            if saved.mode == .visible || value.utf8.count >= Self.minimumHiddenValueBytes { shortValueAccounts.remove(saved.account) }
            await retireGrants(from: previous, to: saved)
            if saved.mode == .visible { await reapplyEnvironments(account: saved.account) }
        } else {
            saved = try await createFirstValue(account: Self.newAccount(), label: trimmed, value: value, apply: apply)
        }
        await record(SecretAuditEntry(account: saved.account, at: clock.now(), destination: "", outcome: .created, detail: mode.title))
        await refreshProxySnapshot()
        log.info("secret saved (value in Keychain only)")
        return saved
    }

    nonisolated static func equalInConstantTime(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    nonisolated static func newAccount() -> String { "bcs_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// A fresh Keychain account for one value of `account` (A02: values are never overwritten in place).
    nonisolated static func newValueAccount(for account: String) -> String {
        account + ".v" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    /// A first save (A02). Order: an unusable row (so a crash never leaves a label to adopt), the value under a fresh
    /// Keychain account, the label, then one row write that activates value and policy together. A failure removes what
    /// was written; a crash is cleaned up at the next launch.
    private func createFirstValue(account: String, label: String, value: SecretValue, apply: (inout ManagedSecret) -> Void) async throws -> ManagedSecret {
        let valueAccount = Self.newValueAccount(for: account)
        var draft = ManagedSecret(account: account, name: "", label: label, mode: .visible, created: clock.now())
        apply(&draft)
        draft.incomplete = true
        draft.pendingValueAccount = valueAccount
        savingAccounts.insert(account)
        defer { savingAccounts.remove(account) }
        try await store.saveManagedSecret(draft)
        do {
            try vault.store(account: valueAccount, label: label, value: value)
            try await legacy.recordLabel(account: account, label: label)
            var active = draft
            active.incomplete = nil
            active.pendingValueAccount = nil
            active.valueAccount = valueAccount
            try await persist(active)
            return active
        } catch {
            try? vault.delete(account: valueAccount)
            try? await legacy.forgetLabel(account: account)
            try? await store.deleteManagedSecret(account: account)
            throw error
        }
    }

    /// Replaces the value of an existing secret (A02). The new value goes to a fresh Keychain account recorded first
    /// as pending (never read); one row write then makes it active together with the policy `change` gives it; only
    /// then is the old value removed. Until that write, every reader keeps the old value under the old policy; after
    /// it, the new value under the new policy. A failure removes the unused new value.
    @discardableResult
    func replaceValue(of account: String, with value: SecretValue, label: String?, change: @escaping (inout ManagedSecret) -> Void) async throws -> ManagedSecret {
        guard let current = secret(account) else { throw ExtrasError("That secret no longer exists.") }
        guard !savingAccounts.contains(account) else { throw ExtrasError("“\(current.label)” is already being saved.") }
        let valueAccount = Self.newValueAccount(for: account)
        savingAccounts.insert(account)
        defer { savingAccounts.remove(account) }
        try await mutate(account) { $0.pendingValueAccount = valueAccount }
        do {
            try vault.store(account: valueAccount, label: label ?? current.label, value: value)
            if let label, label != current.label {
                try await legacy.recordLabel(account: account, label: label)
            }
            // The value is checked against the mode it is activated under, which a concurrent mode change may have set
            // after this save was validated (AF16).
            try await mutate(account, require: { latest in
                var after = latest
                change(&after)
                if after.mode != .visible, value.utf8.count < Self.minimumHiddenValueBytes { throw ExtrasError(Self.shortValueMessage) }
            }) { secret in
                change(&secret)
                if let label { secret.label = label }
                secret.retiredValueAccounts = ((secret.retiredValueAccounts ?? []) + [secret.activeValueAccount]).filter { $0 != valueAccount }
                secret.valueAccount = valueAccount
                secret.pendingValueAccount = nil
            }
        } catch {
            try? vault.delete(account: valueAccount)
            try? await mutate(account) { if $0.pendingValueAccount == valueAccount { $0.pendingValueAccount = nil } }
            throw error
        }
        await removeRetiredValues(account)
        guard let saved = secret(account) else { throw ExtrasError("That secret no longer exists.") }
        return saved
    }

    /// Removes old values from the Keychain once a newer one is active (kept in the row until removed, so a launch
    /// retries).
    private func removeRetiredValues(_ account: String) async {
        guard let secret = secret(account), let retired = secret.retiredValueAccounts, !retired.isEmpty else { return }
        let active = secret.activeValueAccount
        let removed = Set(retired.filter { $0 != active && (try? vault.delete(account: $0)) != nil })
        guard !removed.isEmpty else { return }
        try? await mutate(account) { $0.retiredValueAccounts = $0.retiredValueAccounts?.filter { !removed.contains($0) }.nilIfEmpty }
    }

    /// Applies `change` to the secret's row and writes it; the in-memory record becomes exactly the row written. Row
    /// writes of one account are serialized (AF03), so each starts from the state the previous one left and none writes
    /// back a policy, revocation or count another one replaced. `change` runs once, on that state: what it computes
    /// from anything live (a use count read from the ledger) is the same in the database and in memory (AV13). A change
    /// that leaves the row as it is writes nothing. `require` is checked on that state before anything is written (a
    /// change bound to what it was validated against).
    private func mutate(_ account: String, require: ((ManagedSecret) throws -> Void)? = nil, _ change: (inout ManagedSecret) -> Void) async throws {
        await acquireRow(account)
        defer { releaseRow(account) }
        guard let current = secret(account) else { throw ExtrasError("That secret no longer exists.") }
        try require?(current)
        var next = current
        change(&next)
        guard next != current else { return }
        try await store.saveManagedSecret(next)
        // Every other change of this row waits for its turn, so the committed row is the current one (a deletion
        // during the write removed it from memory: it is not brought back).
        if let index = secrets.firstIndex(where: { $0.account == account }) { secrets[index] = next }
    }

    /// Waits until no other row write of `account` runs, then holds it (released by `releaseRow`, first come first served).
    private func acquireRow(_ account: String) async {
        guard rowWriters[account] != nil else {
            rowWriters[account] = []
            return
        }
        await withCheckedContinuation { rowWriters[account, default: []].append($0) }
    }

    /// Tests: writers waiting for the account's row.
    func waitingRowWriters(_ account: String) -> Int { rowWriters[account]?.count ?? 0 }

    /// Hands the account's row to the next waiting writer, or frees it.
    private func releaseRow(_ account: String) {
        guard var waiters = rowWriters[account], !waiters.isEmpty else {
            rowWriters[account] = nil
            return
        }
        let next = waiters.removeFirst()
        rowWriters[account] = waiters
        next.resume()
    }

    /// Saves a value from the legacy card ("Approved command" without a managed choice): a new commands-only secret, or
    /// a new value for the secret already saved under this label (its policy kept).
    func saveForApprovedCommands(label: String, value: SecretValue) async throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = legacy.account(forLabel: trimmed), let secret = secret(existing) {
            // The same value again changes nothing (approvals stay); a different one is a rotation (R03).
            if let stored = await Self.read(vault, account: secret.activeValueAccount), Self.equalInConstantTime(stored.utf8, value.utf8) {
                return existing
            }
            try await rotate(account: existing, value: value)
            return existing
        }
        return try await create(label: trimmed, value: value, mode: .visible, commandsOnly: true).account
    }

    /// Changes mode, scope, bindings or name (never the value: `rotate`). Leaving placeholder mode drops its placeholders.
    public func update(_ changed: ManagedSecret, confirmVisible: Bool = false) async throws {
        guard let current = secret(changed.account) else { throw ExtrasError("That secret no longer exists.") }
        try validate(mode: changed.mode, bindings: changed.bindings, value: nil, confirmVisible: confirmVisible || current.visibleConfirmed && changed.mode == .visible)
        // Entering a hidden mode: the active value must be long enough for the response scanner to find it (AF16),
        // checked on the very value this edit commits with (a rotation meanwhile makes the edit fail, not slip through).
        var checkedValue: String?
        if changed.mode != current.mode, changed.mode != .visible {
            let valueAccount = current.activeValueAccount
            guard let value = await Self.read(vault, account: valueAccount) else {
                throw ExtrasError("BelloCode could not read “\(current.label)” from the Keychain, so its mode was not changed.")
            }
            try validate(mode: changed.mode, bindings: changed.bindings, value: value, confirmVisible: false)
            checkedValue = valueAccount
        }
        guard ManagedSecret.isValidHandle(changed.name) else { throw ExtrasError("“\(changed.name)” cannot be a name.") }
        if let other = secret(named: changed.name), other.account != changed.account { throw ExtrasError("Another secret is already named \(changed.name).") }
        // Only the editable settings come from `changed` (a Settings copy may be stale): use counts, rotation,
        // revocation and the value's Keychain account stay as they are now (N13).
        let visibleConfirmed = changed.mode == .visible && (confirmVisible || current.visibleConfirmed)
        let edit: (inout ManagedSecret) -> Void = { secret in
            secret.name = changed.name
            secret.mode = changed.mode
            secret.scope = changed.scope
            secret.bindings = changed.bindings
            secret.operation = changed.operation
            secret.visibleConfirmed = visibleConfirmed
        }
        try await mutate(changed.account, require: { latest in
            if let checkedValue, latest.activeValueAccount != checkedValue {
                throw ExtrasError("“\(latest.label)” got a new value while its mode was being changed. Change the mode again.")
            }
        }, edit)
        guard let next = secret(changed.account) else { return }
        if next.mode == .visible { shortValueAccounts.remove(next.account) }
        await retireGrants(from: current, to: next)
        await refreshProxySnapshot()
    }

    /// After a policy change: a new mode, name or withdrawn confirmation ends every grant of the old policy (AF04); a
    /// narrower scope (R13) ends those of projects it no longer admits. The affected threads' environments are replaced.
    private func retireGrants(from previous: ManagedSecret, to next: ManagedSecret) async {
        if previous.mode != next.mode || previous.name != next.name || (previous.visibleConfirmed && !next.visibleConfirmed) {
            await dropGrants(account: next.account)
        } else if previous.scope != next.scope {
            let roots = codeRoots()
            await dropGrants(account: next.account) { !next.scope.admits(projectDirectory: $0.projectDirectory, codeRoots: roots) }
        }
    }

    /// Replaces the value; placeholders stay the same (programs and files keep working).
    public func rotate(account: String, value: SecretValue) async throws {
        guard !value.isEmpty else { throw ExtrasError("The value is empty.") }
        guard var secret = secret(account) else { throw ExtrasError("That secret no longer exists.") }
        try validate(mode: secret.mode, bindings: secret.bindings, value: value, confirmVisible: true)
        guard value.utf8.count <= SecretService.maxValueBytes else {
            throw ExtrasError("The value is longer than \(SecretService.maxValueBytes / 1024) KB, the most a one-read path can carry.")
        }
        let now = clock.now()
        secret = try await replaceValue(of: account, with: value, label: nil) { $0.rotated = Self.nextRotation(after: $0.rotated, now: now) }
        // The new value passed the length check for the mode it was activated under.
        if secret.mode == .visible || value.utf8.count >= Self.minimumHiddenValueBytes { shortValueAccounts.remove(account) }
        await record(SecretAuditEntry(account: account, at: clock.now(), destination: "", outcome: .rotated, detail: "New value; placeholders unchanged"))
        await refreshProxySnapshot()
        if secret.mode == .visible { await reapplyEnvironments(account: account) }
    }

    /// Stops every use at once (placeholders refused, brokered calls refused); the value stays until deleted.
    public func revoke(account: String) async throws {
        guard secret(account) != nil else { return }
        try await mutate(account) { $0.revoked = true }
        await dropGrants(account: account)
        await record(SecretAuditEntry(account: account, at: clock.now(), destination: "", outcome: .revoked, detail: "Revoked in Settings"))
        await refreshProxySnapshot()
    }

    public func restore(account: String) async throws {
        guard secret(account) != nil else { return }
        try await mutate(account) { $0.revoked = false }
        await refreshProxySnapshot()
    }

    /// Deletes the value from the Keychain and every record of the secret (cannot be undone).
    public func delete(account: String) async {
        await dropGrants(account: account)
        // Every value this secret owns first (current, pending, retired), so nothing can be read even if a later step fails.
        do {
            for valueAccount in secret(account)?.allValueAccounts ?? [account] { try vault.delete(account: valueAccount) }
        } catch {
            lastError = ExtrasError.message(error)
            return
        }
        await legacy.delete(account: account)
        if let error = legacy.lastError {
            lastError = error
            return
        }
        do {
            try await store.deleteManagedSecret(account: account)
        } catch {
            // The row would bring the secret back (without a value) at the next launch: shown, so it can be retried.
            lastError = "“\(secret(account)?.label ?? "The secret")” was removed from the Keychain, but its settings could not be deleted (\(ExtrasError.message(error))). Delete it again."
            return
        }
        secrets.removeAll { $0.account == account }
        shortValueAccounts.remove(account)
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
        if mode != .visible, let value, value.utf8.count < Self.minimumHiddenValueBytes { throw ExtrasError(Self.shortValueMessage) }
    }

    /// The shortest value a hidden mode accepts: the response scanner's base64 patterns need this many bytes.
    nonisolated static let minimumHiddenValueBytes = 8
    nonisolated static let shortValueMessage = "Values shorter than 8 bytes cannot be detected reliably in responses; such a value can only be Visible."

    nonisolated public static func shortStoredValueMessage(_ label: String) -> String {
        "“\(label)” has a value shorter than 8 bytes, which BelloCode cannot find reliably in responses, so it is not used in its current mode. Rotate it to a longer value or make it Visible in Settings ▸ Secrets."
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
        if secret.mode != .visible, shortValueAccounts.contains(account) { throw ExtrasError(Self.shortStoredValueMessage(secret.label)) }
        guard secret.scope.admits(projectDirectory: projectDirectory, codeRoots: codeRoots()) else {
            throw ExtrasError("“\(secret.label)” is not available to this project (its scope is \(secret.scope.title)).")
        }
        // Only a grant of the kind the mode delivers is reused; one left from another mode goes (AF04).
        if let existing = grants.values.first(where: { $0.account == account && $0.sessionID == sessionID.rawValue && Self.grantKindFits($0, secret) }) {
            return existing
        }
        await dropGrants(account: account) { $0.sessionID == sessionID.rawValue }
        let marker = secret.mode == .placeholder ? Placeholder.make() : "visible_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let grant = PlaceholderGrant(placeholder: marker, account: account, sessionID: sessionID.rawValue, projectDirectory: projectDirectory, created: clock.now())
        try await store.savePlaceholderGrant(grant)
        // The policy may have changed while the grant was written (its old grants were dropped without this one): a
        // grant that no longer fits is withdrawn, never kept (AF04).
        guard let now = self.secret(account), !now.revoked, Self.grantKindFits(grant, now),
              now.scope.admits(projectDirectory: projectDirectory, codeRoots: codeRoots()) else {
            do { try await store.deletePlaceholderGrants(placeholders: [marker]) } catch { grantDeletionFailed(error) }
            throw ExtrasError("“\(secret.label)” changed while it was being given to this thread. Ask for it again.")
        }
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
        do { try await store.deletePlaceholderGrants(account: account) } catch { grantDeletionFailed(error) }
        for session in sessions { await applyEnvironment(session) }
    }

    /// Grants are already gone in memory (no use is possible now); the next launch drops rows that no longer fit their
    /// secret. Shown, never silent (N13).
    private func grantDeletionFailed(_ error: any Error) {
        lastError = "BelloCode stopped the secret's use by those threads, but could not update its database (\(ExtrasError.message(error))). It is retried at the next launch."
        log.error("placeholder grant deletion failed")
    }

    /// Drops the secret's grants matching `predicate` and replaces the affected threads' environments.
    private func dropGrants(account: String, where predicate: (PlaceholderGrant) -> Bool) async {
        let dropped = grants.values.filter { $0.account == account && predicate($0) }
        guard !dropped.isEmpty else { return }
        for grant in dropped { grants[grant.placeholder] = nil }
        do { try await store.deletePlaceholderGrants(placeholders: dropped.map(\.placeholder)) } catch { grantDeletionFailed(error) }
        for session in Set(dropped.map(\.sessionID)) { await applyEnvironment(session) }
    }

    /// Threads deleted: their placeholders go.
    func removed(sessions: [SessionID]) async {
        let ids = Set(sessions.map(\.rawValue))
        pendingEnvironmentSessions.subtract(ids)
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
            guard let secret = secret(grant.account), !secret.revoked, Self.grantKindFits(grant, secret),
                  secret.scope.admits(projectDirectory: grant.projectDirectory, codeRoots: roots) else { continue }
            switch secret.mode {
            case .placeholder: variables[secret.name] = grant.placeholder
            case .visible where secret.visibleConfirmed:
                // The value saved with this policy (A02), and only if the policy did not change while it was read.
                let revision = Self.policyRevision(secret)
                if let value = await Self.read(vault, account: secret.activeValueAccount),
                   let now = self.secret(grant.account), Self.policyRevision(now) == revision {
                    variables[secret.name] = String(decoding: value.utf8, as: UTF8.self)
                }
            default: break
            }
        }
        return variables
    }

    /// Replaces the thread's command environment on the server. Until the server acknowledges it the thread stays in
    /// `pendingEnvironmentSessions` (with or without grants left), retried at the next reconnect (AF26).
    ///
    /// Replacements of one thread are ordered (GV04): each waits until the previous one has been answered, then computes
    /// the variables from the state as it is then; a replacement a newer one superseded is not sent (the newer one sends
    /// the current state). So a request computed before a revocation can never reach the server after the revocation's
    /// own replacement, and the last replacement the server applies is always the newest state.
    ///
    /// Every caller returns only once a replacement covering its state has been answered (AF26): a superseded one waits
    /// for the newer replacement's answer instead of returning before anything was removed. A revocation therefore
    /// returns with the value gone from the server or the thread shown as pending, never with neither.
    func applyEnvironment(_ session: String) async {
        guard let engine, engine.configuration.containers != nil else { return }
        let generation = (environmentGeneration[session] ?? 0) + 1
        environmentGeneration[session] = generation
        await acquireEnvironment(session)
        let sent = await sendEnvironment(session, generation: generation, engine: engine)
        if sent { settleEnvironment(session, through: generation) }
        releaseEnvironment(session)
        // Superseded: the newer replacement (queued behind this one) carries this caller's state too.
        if !sent { await awaitEnvironment(session, covering: generation) }
    }

    /// Computes and sends one replacement (holding the thread's turn). False when a newer replacement superseded it
    /// before it was sent; true once it was answered, acknowledged or not.
    private func sendEnvironment(_ session: String, generation: Int, engine: Engine) async -> Bool {
        guard environmentGeneration[session] == generation else { return false }
        guard let client = try? await engine.core.currentClient() else {
            pendingEnvironmentSessions.insert(session)
            return true
        }
        let variables = await environmentVariables(for: session)
        // Superseded while the values were read: the newer replacement (waiting for this turn) sends the newer state.
        guard environmentGeneration[session] == generation else { return false }
        if let hold = environmentSendHook { await hold(session) }
        do {
            try await client.setSessionEnvironment(sessionID: session, variables: variables)
            if environmentGeneration[session] == generation { pendingEnvironmentSessions.remove(session) }
        } catch {
            pendingEnvironmentSessions.insert(session)
            log.error("session environment not applied: \(String(describing: type(of: error)), privacy: .public)")
        }
        return true
    }

    /// Waits until a replacement of `session` at least as new as `generation` has been answered.
    private func awaitEnvironment(_ session: String, covering generation: Int) async {
        guard (environmentSettled[session] ?? 0) < generation, environmentWriters[session] != nil else { return }
        await withCheckedContinuation { environmentSettlementWaiters[session, default: []].append((generation, $0)) }
    }

    /// A replacement of `session` at `generation` was answered: the callers it superseded may return.
    private func settleEnvironment(_ session: String, through generation: Int) {
        environmentSettled[session] = max(environmentSettled[session] ?? 0, generation)
        guard let waiters = environmentSettlementWaiters[session] else { return }
        let ready = waiters.filter { $0.generation <= generation }
        let rest = waiters.filter { $0.generation > generation }
        environmentSettlementWaiters[session] = rest.isEmpty ? nil : rest
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Tests: runs right before a thread's environment request is sent.
    @ObservationIgnored var environmentSendHook: (@MainActor (String) async -> Void)?

    /// Waits until no other environment replacement of `session` runs, then holds it (first come, first served).
    private func acquireEnvironment(_ session: String) async {
        guard environmentWriters[session] != nil else {
            environmentWriters[session] = []
            return
        }
        await withCheckedContinuation { environmentWriters[session, default: []].append($0) }
    }

    private func releaseEnvironment(_ session: String) {
        guard var waiters = environmentWriters[session], !waiters.isEmpty else {
            environmentWriters[session] = nil
            // Nothing queued: the newest replacement has been answered, so no superseded caller can still be waiting
            // (any left is released, never stranded). The counters are no longer needed (bounded by the threads with a
            // replacement running).
            let stranded = environmentSettlementWaiters.removeValue(forKey: session) ?? []
            environmentGeneration[session] = nil
            environmentSettled[session] = nil
            for waiter in stranded { waiter.continuation.resume() }
            return
        }
        let next = waiters.removeFirst()
        environmentWriters[session] = waiters
        next.resume()
    }

    /// Tests: environment replacements of `session` waiting for their turn.
    func waitingEnvironmentWriters(_ session: String) -> Int { environmentWriters[session]?.count ?? 0 }

    /// Tests: superseded callers of `session` waiting for a newer replacement's answer.
    func waitingEnvironmentSettlements(_ session: String) -> Int { environmentSettlementWaiters[session]?.count ?? 0 }

    private func reapplyEnvironments(account: String) async {
        for session in Set(grants.values.filter { $0.account == account }.map(\.sessionID)) { await applyEnvironment(session) }
    }

    /// After a reconnect (the server may have restarted, losing session environments): threads with grants, and first
    /// those whose replacement is still unacknowledged, even if they have no grant left (AF26).
    func reapplyAllEnvironments() async {
        let pending = pendingEnvironmentSessions
        let granted = Set(grants.values.map(\.sessionID)).subtracting(pending)
        for session in (pending.sorted() + granted.sorted()).prefix(500) { await applyEnvironment(session) }
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

    /// The accounts whose value (read from the Keychain account given for it) is shorter than a hidden mode accepts.
    nonisolated static func shortValues(_ vault: any SecretVault, accounts: [(account: String, valueAccount: String)]) async -> Set<String> {
        var out = Set<String>()
        for (account, valueAccount) in accounts {
            if let value = try? vault.read(account: valueAccount), !value.isEmpty, value.utf8.count < minimumHiddenValueBytes { out.insert(account) }
        }
        return out
    }

    /// Values by secret account, each read from the Keychain account given for it (the value of its current policy).
    nonisolated static func readAll(_ vault: any SecretVault, accounts: [(account: String, valueAccount: String)]) async -> [String: SecretValue] {
        var out: [String: SecretValue] = [:]
        for (account, valueAccount) in accounts {
            if let value = try? vault.read(account: valueAccount), !value.isEmpty { out[account] = value }
        }
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
    ///
    /// Counts go through the account's serialized row writes (AF03): applied to the row as it is when this write's turn
    /// comes, so a count never writes back the policy a concurrent revocation or edit replaced.
    func recordUses(_ uses: [SubstitutionUse]) async -> Bool {
        var stored = true
        let ledger = useLedger
        for account in Set(uses.map(\.account)) {
            guard secret(account) != nil else { stored = false; continue }
            let bindings = Set(uses.filter { $0.account == account }.map(\.bindingID))
            do {
                try await mutate(account) { secret in
                    for binding in bindings {
                        secret.uses[binding] = max(secret.uses[binding] ?? 0, ledger.count(account: account, bindingID: binding))
                    }
                }
            } catch {
                stored = false
            }
        }
        return stored
    }

    /// Lowers the persisted counts of these uses to the ledger's after they were released (refused before anything was
    /// sent, AV13): a relaunch, which seeds the ledger from the persisted counts, does not count them. A failed write
    /// leaves the higher count (fail-closed: a use may be over-counted, never under-counted).
    ///
    /// Through the same serialized row writes as `recordUses`: whether anything is lowered is decided on the row as it
    /// is when this write's turn comes (never on a count sampled before it), and the count written is the one kept in
    /// memory. So concurrent refunds and reservations leave the database, the record and the ledger in agreement.
    func releaseUses(_ uses: [SubstitutionUse]) async {
        let ledger = useLedger
        for account in Set(uses.map(\.account)) {
            guard secret(account) != nil else { continue }
            let bindings = Set(uses.filter { $0.account == account }.map(\.bindingID))
            do {
                try await mutate(account) { secret in
                    for binding in bindings {
                        guard let stored = secret.uses[binding] else { continue }
                        secret.uses[binding] = min(stored, ledger.count(account: account, bindingID: binding))
                    }
                }
            } catch {
                log.error("released secret use not lowered in the store")
            }
        }
    }

    public var lastUse: [String: SecretAuditEntry] {
        var out: [String: SecretAuditEntry] = [:]
        for entry in recentAudit where [.substituted, .brokered, .revealed].contains(entry.outcome) && out[entry.account] == nil { out[entry.account] = entry }
        return out
    }
}

// MARK: - Egress

extension SecretManager {
    /// The proxy persists reservations of limited bindings before sending, and lowers them again when a request is
    /// refused before anything was sent (R12, AV13).
    func connectUseAccounting(_ proxy: EgressProxy) {
        proxy.setUseRecorder { [weak self] uses in await self?.recordUses(uses) ?? false }
        proxy.setUseReleaser { [weak self] uses in await self?.releaseUses(uses) }
    }

    func startEgress(_ configuration: SecretManagerConfiguration) async {
        egressStatus = .starting
        do {
            let authority = try await loadAuthority(configuration)
            authorityFingerprint = authority.fingerprint
            var proxyConfiguration = configuration.proxy
            if let routerOverride { proxyConfiguration.router = routerOverride(proxyConfiguration.router) }
            let proxy = EgressProxy(authority: authority, configuration: proxyConfiguration, ledger: useLedger)
            connectUseAccounting(proxy)
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
        guard let (port, token, socket, drain) = prepareScope(spec) else {
            throw EgressGatewayError("BelloCode's egress proxy is not running, so this project's container has no network. Open Settings ▸ Secrets.")
        }
        // A narrower scope (a root removed) applies to requests already in flight on the old one (AV2-04).
        await proxy?.drain(drain)
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
    private func prepareScope(_ spec: WorkspaceSpec) -> (UInt16, String, String, EgressDrain)? {
        guard case .ready(let port) = egressStatus, let proxy, let egress = spec.egress, let socket = environments?.activeRuntime.socketPath else { return nil }
        // The token is kept for the launch; what the scope serves always follows the spec now (N13: code roots change).
        let token = scopes[egress.scopeKey]?.token ?? UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        let scope = rebuildScope(egress.scopeKey, token: token, roots: spec.workspaceRoots)
        let drain = proxy.setScopes(Array(scopes.values))
        return (port, scope.token, socket, drain)
    }

    /// (Re)makes a workspace scope serving exactly `roots`, with the raw allowlists of the projects inside them.
    @discardableResult
    func rebuildScope(_ key: String, token: String, roots: [String]) -> EgressScope {
        scopeRoots[key] = roots
        let scope = EgressScope(id: key, token: token, rawAllowlist: rawAllowlist(roots: roots)) { project in
            roots.contains { project == $0 || project.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        scopes[key] = scope
        return scope
    }

    /// The raw allowlists of every project a scope serving `roots` admits (the shared workspace serves many; one gateway
    /// cannot tell them apart, so its scope carries their union, as Settings says).
    func rawAllowlist(roots: [String]) -> Set<HostPort> {
        let inside = { (project: String) in roots.contains { project == $0 || project.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
        let prefix = "secrets.rawEgress."
        let configured = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let projects = Set(configured + roots).filter(inside)
        return projects.reduce(into: Set<HostPort>()) { $0.formUnion(rawAllowlist(projectDirectory: $1)) }
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
        // Every scope serving the project: its own container's and the shared workspace's (N13).
        var changed = false
        for (key, roots) in scopeRoots where scopes[key] != nil
            && roots.contains(where: { projectDirectory == $0 || projectDirectory.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
            scopes[key]?.rawAllowlist = rawAllowlist(roots: roots)
            changed = true
        }
        if changed { proxy?.setScopes(Array(scopes.values)) }
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
    ///
    /// Returns once the proxy has this snapshot or a newer one, and no request it withdrew is still being written
    /// upstream (AF15): after a revocation's refresh returns, nothing carrying the revoked value can leave.
    func refreshProxySnapshot() async {
        guard let proxy else { return }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let hidden = secrets.filter { $0.mode == .placeholder && !$0.revoked }
        var values = await Self.readAll(vault, accounts: hidden.map { ($0.account, $0.activeValueAccount) })
        guard self.proxy === proxy else {
            // This proxy is gone: nothing more will be published to it.
            resumeAllSnapshotWaiters()
            return
        }
        // A newer snapshot (a revocation, a narrower scope, a new value) was built while this one read the Keychain:
        // this refresh is done once that one is published.
        guard generation == snapshotGeneration else {
            if publishedGeneration < generation { await withCheckedContinuation { snapshotWaiters.append((generation, $0)) } }
            return
        }
        // A value too short to scan for is never substituted (AF16: one saved before the check).
        for (account, value) in values where value.utf8.count < Self.minimumHiddenValueBytes {
            values[account] = nil
            shortValueAccounts.insert(account)
        }
        for secret in hidden where values[secret.account] != nil { shortValueAccounts.remove(secret.account) }
        let placeholderGrants = grants.filter { Placeholder.isPlaceholder($0.key) }
        let drain = proxy.update(EgressSnapshot(grants: placeholderGrants, secrets: Dictionary(hidden.map { ($0.account, $0) }, uniquingKeysWith: { a, _ in a }),
                                                values: values, codeRoots: codeRoots()))
        await proxy.drain(drain)
        resumeSnapshotWaiters(upTo: generation)
    }

    private func resumeSnapshotWaiters(upTo generation: Int) {
        publishedGeneration = max(publishedGeneration, generation)
        let ready = snapshotWaiters.filter { $0.generation <= publishedGeneration }
        snapshotWaiters.removeAll { $0.generation <= publishedGeneration }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeAllSnapshotWaiters() {
        let all = snapshotWaiters
        snapshotWaiters = []
        all.forEach { $0.continuation.resume() }
    }

    /// Tests: refreshes waiting for a newer snapshot to be published.
    var waitingSnapshotRefreshes: Int { snapshotWaiters.count }

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

fileprivate extension Array {
    /// Nil for an empty array (optional list fields that are absent when empty).
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
