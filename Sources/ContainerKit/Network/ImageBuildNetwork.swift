import Foundation

/// The corporate network for **image builds** (docs/features/containers.md, "Corporate network"): what a build of a
/// project's Dockerfile needs so `RUN npm install`, `pip install`, `apt-get`, `git clone` and `curl` work behind the
/// TLS-intercepting proxy. For the image-build feature; it does not build anything itself.
///
/// Two halves, because a build has two clients:
/// - **The daemon** pulls `FROM` images and fetches `ADD https://…` itself, inside Rancher Desktop's VM. That uses the
///   VM's trust store and proxy, which BelloCode does not change (Rancher Desktop imports the Mac's trusted roots
///   into its VM); verify on the corporate network.
/// - **`RUN` steps** are containers like any other: they get the proxy as Docker's predefined build arguments
///   (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and lowercase; never written to the image's history) and the certificates
///   through `instrument(dockerfile:)`, which copies the bundle into every stage and points the usual variables at it.
///
/// Usage with the Engine API (`EngineClient.buildImage`): add `contextEntries()` to the tar context, send
/// `instrument(dockerfile:source: .context)` as the Dockerfile and `buildArgs()` as `buildargs`. With `docker buildx`:
/// pass `cliArguments()` (named context `bellocode-ca` plus `--build-arg`s) and `instrument(dockerfile:source:
/// .namedContext)`, which leaves the project's own build context untouched.
public struct ImageBuildNetwork: Sendable, Equatable {
    public var corporate: CorporateNetwork

    public init(_ corporate: CorporateNetwork) { self.corporate = corporate }

    /// The folder (in the tar context) or the named build context the certificates come from.
    public static let contextName = "bellocode-ca"

    public enum Source: Sendable, Equatable {
        /// `COPY bellocode-ca/ …` from the build context (Engine API builds: add `contextEntries()` to the tar).
        case context
        /// `COPY --from=bellocode-ca / …` from a named context (BuildKit: `--build-context bellocode-ca=<folder>`).
        case namedContext
    }

    public var hasCertificates: Bool { corporate.certificateDirectory != nil }
    public var isEmpty: Bool { corporate.isEmpty }

    /// Docker's predefined proxy build arguments (usable in `RUN` without an `ARG` line, kept out of the history). Empty
    /// when no proxy is set (a transparent proxy). Proxies on the Mac's loopback are given as `host.docker.internal`.
    public func buildArgs(noProxyExtra: [String] = []) -> [String: String] {
        guard corporate.hasProxy else { return [:] }
        let env = corporate.environment(noProxyExtra: noProxyExtra)
        var args: [String: String] = [:]
        for name in ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy"] {
            if let value = env[name] { args[name] = value }
        }
        return args
    }

    /// The certificate files for an Engine API build context, at `bellocode-ca/<name>` (read from the exported bundle).
    public func contextEntries() throws -> [TarArchive.Entry] {
        guard let directory = corporate.certificateDirectory else { return [] }
        var entries = [TarArchive.Entry(path: Self.contextName, mode: 0o755, isDirectory: true)]
        for name in [CorporateNetwork.bundleName, CorporateNetwork.enterpriseName] {
            let data = try Data(contentsOf: URL(filePath: directory).appending(path: name))
            entries.append(TarArchive.Entry(path: "\(Self.contextName)/\(name)", contents: data, mode: 0o644))
        }
        return entries
    }

    /// `docker buildx build` arguments: the named context with the certificates and the proxy build arguments.
    public func cliArguments(noProxyExtra: [String] = []) -> [String] {
        var arguments: [String] = []
        if let directory = corporate.certificateDirectory { arguments += ["--build-context", "\(Self.contextName)=\(directory)"] }
        for (name, value) in buildArgs(noProxyExtra: noProxyExtra).sorted(by: { $0.key < $1.key }) {
            arguments += ["--build-arg", "\(name)=\(value)"]
        }
        return arguments
    }

    /// The lines added after each `FROM`: the bundle at `/etc/bellocode/certs`, the enterprise roots in the
    /// distributions' trust-store source folders (picked up by any `update-ca-certificates`/`update-ca-trust` the
    /// Dockerfile runs), and the variables tools read. No `RUN` (a stage may have no shell). Empty without certificates.
    public func stageLines(source: Source) -> [String] {
        guard hasCertificates else { return [] }
        let from = source == .context ? "\(Self.contextName)/" : "--from=\(Self.contextName) /"
        let enterprise = source == .context ? "\(Self.contextName)/\(CorporateNetwork.enterpriseName)"
            : "--from=\(Self.contextName) /\(CorporateNetwork.enterpriseName)"
        let bundle = CorporateNetwork.containerBundle
        return [
            "# BelloCode: enterprise root certificates for builds behind the TLS-inspecting proxy",
            "COPY \(from) \(CorporateNetwork.containerDirectory)/",
            "COPY \(enterprise) \(CorporateNetwork.debianAnchor)",
            "COPY \(enterprise) \(CorporateNetwork.redHatAnchor)",
            "ENV SSL_CERT_FILE=\(bundle) REQUESTS_CA_BUNDLE=\(bundle) PIP_CERT=\(bundle) GIT_SSL_CAINFO=\(bundle) CURL_CA_BUNDLE=\(bundle) NODE_EXTRA_CA_CERTS=\(CorporateNetwork.containerEnterprise)",
        ]
    }

    /// The Dockerfile with `stageLines` after every `FROM` instruction (each build stage, including `FROM scratch`), so
    /// every stage's `RUN` trusts the roots. Comments, parser directives, `ARG`s before `FROM`, line continuations and
    /// heredocs are left as they are. Unchanged without certificates.
    public func instrument(dockerfile: String, source: Source = .context) -> String {
        let lines = stageLines(source: source)
        guard !lines.isEmpty else { return dockerfile }
        var output: [String] = []
        var continuing = false
        var heredoc: String?
        for line in dockerfile.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            output.append(line)
            if let end = heredoc {
                if line.trimmingCharacters(in: .whitespaces) == end { heredoc = nil }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let wasContinuing = continuing
            continuing = trimmed.hasSuffix("\\")
            if let marker = Self.heredocMarker(trimmed) { heredoc = marker }
            // The end of a FROM instruction (possibly continued over several lines).
            if !continuing, Self.instructionStartsFrom(output, wasContinuing: wasContinuing) {
                output += lines
            }
        }
        return output.joined(separator: "\n")
    }

    /// Whether the instruction that just ended (the last line, plus continued lines before it) is a `FROM`.
    static func instructionStartsFrom(_ lines: [String], wasContinuing: Bool) -> Bool {
        var index = lines.count - 1
        if wasContinuing {
            while index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).hasSuffix("\\") { index -= 1 }
        }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard !first.hasPrefix("#") else { return false }
        return first.uppercased().hasPrefix("FROM ") || first.uppercased() == "FROM"
    }

    /// `RUN <<EOF` / `COPY <<-'EOT' …`: the word ending the heredoc.
    static func heredocMarker(_ line: String) -> String? {
        guard let range = line.range(of: "<<") else { return nil }
        var rest = line[range.upperBound...]
        if rest.hasPrefix("-") { rest = rest.dropFirst() }
        let word = rest.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return word.isEmpty || !word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) ? nil : word
    }
}
