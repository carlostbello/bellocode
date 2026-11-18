import Foundation

/// A GitLab project as listed for cloning or returned by publish.
public struct GitLabProjectSummary: Sendable, Hashable, Identifiable {
    public var id: Int
    /// `group/subgroup/project`.
    public var path: String
    public var name: String
    public var description: String?
    public var httpURL: String
    public var webURL: String
    public var defaultBranch: String?
    public var lastActivity: Date?

    public init(
        id: Int, path: String, name: String, description: String?, httpURL: String, webURL: String, defaultBranch: String?, lastActivity: Date?
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.description = description
        self.httpURL = httpURL
        self.webURL = webURL
        self.defaultBranch = defaultBranch
        self.lastActivity = lastActivity
    }
}

/// A namespace a project can be created in (the person's own, or a group they can create projects in).
public struct GitLabNamespace: Sendable, Hashable, Identifiable {
    public var id: Int
    public var fullPath: String
    public var kind: String
}

// Git parity (docs/features/git-parity.md rows 19, 20, 28): clone picker, publish, protected-branch check. Endpoints:
// `GET /projects?membership=true&search=…&order_by=last_activity_at&simple=true`, `GET /namespaces?search=…`,
// `POST /projects` (private by default), `GET /projects/:P/repository/branches/:name` (`protected`, `can_push`).
extension GitLabProvider {
    @concurrent
    public func searchProjects(_ instance: GitLabInstance, search: String, limit: Int = 50) async throws -> [GitLabProjectSummary] {
        var path = "projects?membership=true&simple=true&order_by=last_activity_at&per_page=\(min(100, limit))"
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { path += "&search=" + Self.encode(trimmed) }
        return try Self.array(try await get(path, instance, cached: false)).prefix(limit).compactMap(Self.project)
    }

    @concurrent
    public func namespaces(_ instance: GitLabInstance, search: String = "") async throws -> [GitLabNamespace] {
        let path = "namespaces?per_page=50" + (search.isEmpty ? "" : "&search=" + Self.encode(search))
        return try Self.array(try await get(path, instance, cached: false)).compactMap { item in
            guard let id = item["id"] as? Int, let fullPath = item["full_path"] as? String else { return nil }
            return GitLabNamespace(id: id, fullPath: fullPath, kind: item["kind"] as? String ?? "user")
        }
    }

    /// Creates a project (private unless `visibility` says otherwise). Sent once, never retried.
    @concurrent
    public func createProject(_ instance: GitLabInstance, name: String, path: String, namespaceID: Int?, visibility: String = "private")
        async throws -> GitLabProjectSummary
    {
        var body: [String: JSONLike] = ["name": .string(name), "path": .string(path), "visibility": .string(visibility)]
        if let namespaceID { body["namespace_id"] = .int(namespaceID) }
        let object = try await write("POST", "projects", instance, body: .object(body))
        guard let project = Self.project(object) else { throw ForgeError.unexpected("GitLab did not return the new project.") }
        return project
    }

    /// Whether `branch` of `project` is protected, and whether the token's user may push to it (nil: unknown).
    @concurrent
    public func branchProtection(_ instance: GitLabInstance, project: String, branch: String) async throws -> (protected: Bool, canPush: Bool?)? {
        do {
            let object = try Self.object(try await get("projects/\(Self.encode(project))/repository/branches/\(Self.encode(branch))", instance, cached: false))
            return (object["protected"] as? Bool ?? false, object["can_push"] as? Bool)
        } catch ForgeError.notFound {
            return nil
        }
    }

    static func project(_ item: [String: Any]) -> GitLabProjectSummary? {
        guard let id = item["id"] as? Int, let path = item["path_with_namespace"] as? String, let http = item["http_url_to_repo"] as? String
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let activity = (item["last_activity_at"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return GitLabProjectSummary(
            id: id, path: path, name: item["name"] as? String ?? path, description: item["description"] as? String, httpURL: http,
            webURL: item["web_url"] as? String ?? http, defaultBranch: item["default_branch"] as? String, lastActivity: activity)
    }
}
