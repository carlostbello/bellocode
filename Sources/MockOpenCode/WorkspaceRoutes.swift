import Foundation

/// Slash commands, skills, file search, locations and command runs (`GET /api/command`, `GET /api/skill`,
/// `GET /api/fs/find`, `GET /api/location`, `POST /api/session/{id}/command`), shaped as in opencode 2.3.0's contract.
extension MockOpenCodeServer {
    /// Commands the mock lists (`Command.Info`).
    static let mockCommands: [JSONValue] = [
        ["name": "init", "description": "Create or update AGENTS.md for this project"],
        ["name": "review", "description": "Review the current changes"],
        ["name": "compact", "description": "Summarise the session to free context"],
    ]

    /// Skills the mock lists (`Skill.Info`, with a short `content`).
    static let mockSkills: [JSONValue] = [
        [
            "id": "skill_swift", "name": "swift-testing", "description": "Write tests with Swift Testing",
            "path": "/tmp/mock-skills/swift-testing/SKILL.md", "content": "Use #expect.",
        ],
    ]

    /// Paths `fs/find` searches when the location is not a real folder on disk.
    static let mockFiles = [
        "README.md", "Package.swift", "Sources/App/main.swift", "Sources/App/AppDelegate.swift",
        "Sources/Core/Parser.swift", "Tests/AppTests/MainTests.swift", "docs/PLAN.md",
    ]

    func routeWorkspace(_ method: String, _ parts: [String], _ request: HTTPRequest) -> HTTPResponse? {
        guard parts.first == "api" else { return nil }
        switch (method, Array(parts.dropFirst())) {
        case ("GET", ["command"]): return located(request, .array(Self.mockCommands))
        case ("GET", ["skill"]): return located(request, .array(Self.mockSkills))
        case ("GET", ["fs", "find"]): return findFiles(request)
        case ("GET", ["location"]): return locationInfo(request)
        case ("POST", let p) where p.count == 3 && p[0] == "session" && p[2] == "command": return runCommand(p[1], request)
        default: return nil
        }
    }

    private func findFiles(_ request: HTTPRequest) -> HTTPResponse {
        guard let query = request.queryValue("query") else { return Self.invalid("Missing key\n  at [\"query\"]") }
        let limit = Int(request.queryValue("limit") ?? "") ?? 50
        let directory = location(request)
        let candidates = Self.diskFiles(directory) ?? Self.mockFiles
        let needle = query.lowercased()
        let matches = candidates.filter { needle.isEmpty || $0.lowercased().contains(needle) }
            .sorted { ($0.count, $0) < ($1.count, $1) }
            .prefix(limit)
        return located(request, .array(matches.map { ["path": .string($0), "type": "file"] }))
    }

    /// Files under a real folder (bounded), relative to it; nil when it is not a folder.
    private static func diskFiles(_ directory: String) -> [String]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: URL(filePath: directory), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        let prefix = URL(filePath: directory).standardizedFileURL.path + "/"
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL, paths.count < 5_000 {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
        }
        return paths
    }

    private func locationInfo(_ request: HTTPRequest) -> HTTPResponse {
        let directory = location(request)
        guard let project = state.project(containing: directory) else {
            return .error(
                404, tag: "LocationNotFoundError", message: "Location not found: \(directory)",
                extra: [("location", ["directory": .string(directory)])])
        }
        return .json([
            "directory": .string(directory),
            "project": [
                "id": .string(project.id), "directory": .string(project.directory), "canonical": .string(project.directory),
            ],
        ])
    }

    /// Runs a command as a prompt whose text is `/name arguments` (the mock has no command callbacks).
    private func runCommand(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let name = body["name"]?.stringValue, let text = body["text"]?.stringValue else {
            return Self.invalid("Missing key\n  at [\"name\"]")
        }
        guard Self.mockCommands.contains(where: { $0["name"]?.stringValue == name }) else {
            return .error(404, tag: "CommandNotFoundError", message: "Command not found: \(name)", extra: [("command", .string(name))])
        }
        let prompt = "/\(name)" + (text.isEmpty ? "" : " \(text)")
        recordedCommands.append((sessionID, name, text))
        _ = admit(
            sessionID: sessionID, id: nil, text: prompt, delivery: body["delivery"]?.stringValue ?? "steer",
            script: selectScript(sessionID: sessionID, text: prompt), attachments: Self.echoedAttachments(body))
        return .noContent()
    }

    /// `files`, `agents`, `skills` of a prompt body as the server echoes them on the user message: each file as a
    /// `Prompt.FileAttachment` (`data` empty in the mock, `source` = the URI, MIME from the extension).
    static func echoedAttachments(_ body: JSONValue) -> JSONValue? {
        var result: [(String, JSONValue?)] = []
        if let files = body["files"]?.arrayValue, !files.isEmpty {
            result.append(("files", .array(files.compactMap { file in
                guard let uri = file["uri"]?.stringValue else { return nil }
                let ext = URL(string: uri)?.pathExtension.lowercased() ?? ""
                let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "txt": "text/plain", "md": "text/markdown"][ext]
                    ?? "text/plain"
                return .compact([
                    ("data", ""), ("mime", .string(mime)), ("source", ["type": "uri", "uri": .string(uri)]),
                    ("name", file["name"]), ("mention", file["mention"]),
                ])
            })))
        }
        if let agents = body["agents"]?.arrayValue, !agents.isEmpty { result.append(("agents", .array(agents))) }
        if let skills = body["skills"]?.arrayValue, !skills.isEmpty {
            result.append(("skills", .array(skills.map { skill in
                .compact([("id", skill["id"]), ("name", skill["id"]), ("mention", skill["mention"])])
            })))
        }
        return result.isEmpty ? nil : .compact(result)
    }
}
