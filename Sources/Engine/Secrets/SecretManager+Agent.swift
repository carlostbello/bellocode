import BelloCore
import Foundation
import OpenCodeKit
import SecretKit

/// The agent's side of the secret manager: answering a secret card, the wake message per mode, and the
/// `http_request` and `list_secrets` tools (docs/features/secrets.md).
extension SecretManager {
    /// Binding from the card's fields (one destination, one location).
    public static func binding(from choice: SecretChoice) throws -> SecretBinding {
        let raw = choice.destination.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: raw.contains("://") ? raw : "https://" + raw), let host = components.host, !host.isEmpty else {
            throw ExtrasError("Give the destination as https://host.")
        }
        var locations: [SecretLocation] = []
        let header = choice.headerName.trimmingCharacters(in: .whitespaces)
        if !header.isEmpty {
            if header.caseInsensitiveCompare("Authorization") == .orderedSame, choice.headerPrefix.lowercased().hasPrefix("basic") {
                locations.append(.basicAuthPassword)
            } else {
                locations.append(.header(header, prefix: choice.headerPrefix))
            }
        }
        let query = choice.queryName.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { locations.append(.query(query)) }
        if locations.isEmpty { locations.append(.header("Authorization", prefix: "Bearer ")) }
        let path = choice.pathPrefix.trimmingCharacters(in: .whitespaces)
        let methods = choice.methods.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.uppercased() }
        return SecretBinding(scheme: components.scheme ?? "https", host: host, port: components.port, methods: methods,
                             pathPrefixes: path.isEmpty || path == "/" ? [] : [path.hasPrefix("/") ? path : "/" + path], locations: locations)
    }

    /// The card's Save: stores the value with the chosen mode, grants this thread and returns the wake text.
    func saveFromCard(_ prompt: SecretPrompt, value: SecretValue, choice: SecretChoice, sessionID: SessionID) async throws -> String {
        let project = prompt.projectDirectory ?? engine?.orchestration?.node(sessionID)?.node.directory ?? ""
        let scope: SecretScope = choice.projectOnly && !project.isEmpty ? .project(project) : .global
        let mode: SecretUseMode
        var bindings: [SecretBinding] = []
        switch choice.mode {
        case .brokered:
            mode = .brokered
            bindings = [try Self.binding(from: choice)]
        case .placeholder:
            guard placeholdersAvailable else {
                throw ExtrasError("Placeholder secrets need BelloCode's egress proxy, which is not running (Settings ▸ Secrets). Choose Brokered, or try again once it runs.")
            }
            mode = .placeholder
            bindings = [try Self.binding(from: choice)]
        case .visible, .command:
            mode = .visible
        }
        let name = choice.name.isEmpty ? ManagedSecret.handle(from: prompt.label) : choice.name
        // "Approved command" is its own delivery (R25): saved without any visibility grant, given only to commands the
        // person approves.
        let secret = try await create(label: prompt.label, name: name, value: value, mode: mode, scope: scope, bindings: bindings,
                                      confirmVisible: choice.mode == .visible && choice.confirmVisible, commandsOnly: choice.mode == .command)
        if choice.mode == .command { return "" }
        return try await grantAndDescribe(secret, sessionID: sessionID, projectDirectory: project)
    }

    /// "Use Saved Value" for a managed secret: the same wake as a new save. Nil: the legacy command path applies.
    func useSaved(label: String, sessionID: SessionID, projectDirectory: String?) async throws -> String? {
        guard let secret = secrets.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else { return nil }
        if secret.mode == .visible && !secret.visibleConfirmed { return nil }
        let project = projectDirectory ?? engine?.orchestration?.node(sessionID)?.node.directory ?? ""
        return try await grantAndDescribe(secret, sessionID: sessionID, projectDirectory: project)
    }

    public func grantAndDescribe(_ secret: ManagedSecret, sessionID: SessionID, projectDirectory: String) async throws -> String {
        let bindings = secret.bindings.map(Self.describe).joined(separator: "; ")
        switch secret.mode {
        case .brokered:
            await record(SecretAuditEntry(account: secret.account, at: clock.now(), destination: "", sessionID: sessionID.rawValue,
                                          outcome: .created, detail: "Handle given to the thread"))
            return "[BelloCode secret] The user saved “\(secret.label)” as a brokered secret: you cannot see its value. Use it only with bellocode_app_http_request, writing {{secret:\(secret.name)}} where the value belongs (\(bindings)). BelloCode performs the request and returns status, a few headers and the body, unless the response contains the value. Do not try to recover the value."
        case .placeholder:
            let grant = try await grant(account: secret.account, sessionID: sessionID, projectDirectory: projectDirectory)
            return "[BelloCode secret] The user saved “\(secret.label)” as a placeholder secret: you cannot see its value. In this thread's commands $\(secret.name) holds the placeholder \(grant.placeholder) (not the value; you may also write it into config files). BelloCode's network proxy replaces it with the real value only in \(bindings); a request that sends it anywhere else is refused (HTTP 403 from BelloCode), and responses that echo the value come back with the placeholder instead. Use https through the configured proxy (HTTPS_PROXY is set); shells started before this message need `export \(secret.name)=\(grant.placeholder)`. Do not try to recover the value."
        case .visible:
            _ = try await grant(account: secret.account, sessionID: sessionID, projectDirectory: projectDirectory)
            await record(SecretAuditEntry(account: secret.account, at: clock.now(), destination: "", sessionID: sessionID.rawValue,
                                          outcome: .revealed, detail: "Given to the thread as $\(secret.name)"))
            return "[BelloCode secret] The user saved “\(secret.label)” as a visible secret and allowed you to see it: $\(secret.name) holds the value in this thread's commands (new shells). Do not print it or write it to files unless the task needs it."
        }
    }

    public static func describe(_ binding: SecretBinding) -> String {
        let locations = binding.locations.map(\.description).joined(separator: " or ")
        let paths = binding.pathPrefixes.isEmpty ? "" : " under " + binding.pathPrefixes.joined(separator: ", ")
        let methods = binding.methods.isEmpty ? "" : " (\(binding.methods.joined(separator: ", ")))"
        return "\(locations) of requests to \(binding.origin)\(paths)\(methods)"
    }

    // MARK: Tools

    func httpRequest(_ arguments: JSONValue, caller: ExtrasCaller) async -> ClientMCPResult {
        guard let url = arguments["url"]?.stringValue else { return ClientMCPResult(text: "Give url.", isError: true) }
        var headers: [String: String] = [:]
        if case .object(let fields)? = arguments["headers"] { for (key, value) in fields { headers[key] = value.stringValue ?? "" } }
        let request = SecretBroker.Request(method: arguments["method"]?.stringValue ?? "GET", url: url, headers: headers, body: arguments["body"]?.stringValue)
        var resolved: [String: (ManagedSecret, SecretValue)] = [:]
        for name in SecretBroker.handles(in: request) {
            guard let secret = secret(named: name) else { return ClientMCPResult(text: "No secret is named \(name). Call bellocode_app_list_secrets, or ask with request_secret.", isError: true) }
            guard !secret.revoked else { return ClientMCPResult(text: "“\(secret.label)” was revoked.", isError: true) }
            guard secret.mode == .brokered || secret.mode == .placeholder else {
                return ClientMCPResult(text: "“\(secret.label)” is not a brokered secret.", isError: true)
            }
            guard secret.scope.admits(projectDirectory: caller.projectDirectory, codeRoots: codeRoots()) else {
                return ClientMCPResult(text: "“\(secret.label)” is not available to this project.", isError: true)
            }
            guard let value = await Self.read(vault, account: secret.activeValueAccount) else {
                return ClientMCPResult(text: "“\(secret.label)” is not in the Keychain any more.", isError: true)
            }
            // A value too short to find in the response is never sent (AF16: one saved before the length check).
            guard value.utf8.count >= Self.minimumHiddenValueBytes else {
                shortValueAccounts.insert(secret.account)
                return ClientMCPResult(text: Self.shortStoredValueMessage(secret.label), isError: true)
            }
            resolved[name] = (secret, value)
        }
        // Uses count against the binding in the ledger the proxy shares, reserved before each hop is sent (R12). Every
        // hop is re-authorized against the secrets as they are then (A12).
        let resolvedState = resolved.mapValues { (secret, _) in BrokerAuthorization(secret) }
        let project = caller.projectDirectory
        var broker = SecretBroker(extraAnchors: (engine?.configuration.brokerAnchors ?? []) + extraBrokerAnchors, ledger: useLedger) { [weak self] uses in
            await self?.recordUses(uses) ?? false
        }
        broker.releaseUses = { [weak self] uses in await self?.releaseUses(uses) }
        broker.stillAuthorized = { [weak self] in await self?.brokerStillAuthorized(resolvedState, projectDirectory: project) ?? false }
        let outcome = await broker.perform(request, secrets: resolved, sessionID: caller.sessionID.rawValue, projectDirectory: caller.projectDirectory)
        for entry in outcome.audit { await record(entry) }
        _ = await recordUses(outcome.reserved)
        return ClientMCPResult(text: outcome.text, isError: outcome.text.hasPrefix("BelloCode refused"))
    }

    /// What a brokered request was authorized with, per handle: the secret's policy revision (mode, scope, revocation,
    /// value) and its bindings.
    struct BrokerAuthorization: Sendable {
        var account: String
        var revision: String
        var bindings: [SecretBinding]

        init(_ secret: ManagedSecret) {
            account = secret.account
            revision = SecretManager.policyRevision(secret)
            bindings = secret.bindings
        }
    }

    /// True while every handle still names the same secret with the same policy and bindings, usable by the brokered
    /// tool in `projectDirectory`.
    func brokerStillAuthorized(_ authorized: [String: BrokerAuthorization], projectDirectory: String) -> Bool {
        let roots = codeRoots()
        for (name, before) in authorized {
            guard let now = secret(named: name), now.account == before.account, !now.revoked,
                  now.mode == .brokered || now.mode == .placeholder,
                  Self.policyRevision(now) == before.revision, now.bindings == before.bindings,
                  now.scope.admits(projectDirectory: projectDirectory, codeRoots: roots) else { return false }
        }
        return true
    }

    func listSecrets(caller: ExtrasCaller) -> ClientMCPResult {
        let visible = secrets.filter { !$0.revoked && $0.scope.admits(projectDirectory: caller.projectDirectory, codeRoots: codeRoots()) }
        guard !visible.isEmpty else { return ClientMCPResult(text: "No secrets are available to this project. Ask with bellocode_app_request_secret.") }
        let lines = visible.map { secret -> String in
            let bindings = secret.bindings.map(Self.describe).joined(separator: "; ")
            switch secret.mode {
            case .brokered:
                return "- \(secret.name) (“\(secret.label)”): brokered; use {{secret:\(secret.name)}} with bellocode_app_http_request for \(bindings). You cannot see the value."
            case .placeholder:
                let placeholder = self.placeholder(account: secret.account, sessionID: caller.sessionID)
                return "- \(secret.name) (“\(secret.label)”): placeholder" + (placeholder.map { " \($0) ($\(secret.name) in this thread's commands)" } ?? " (not given to this thread yet: ask with request_secret)") + "; replaced only in \(bindings). Also usable as {{secret:\(secret.name)}} with bellocode_app_http_request. You cannot see the value."
            case .visible:
                return secret.visibleConfirmed
                    ? "- \(secret.name) (“\(secret.label)”): visible; $\(secret.name) once given to this thread."
                    : "- \(secret.name) (“\(secret.label)”): only through commands the user approves (bellocode_app_secret_exec after request_secret)."
            }
        }
        return ClientMCPResult(text: "Secrets for this project (values are never shown):\n" + lines.joined(separator: "\n"))
    }
}
