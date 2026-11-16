import Foundation

/// Branch and workspace kind for a directory, read from the repository's files (no `git` process): the nearest
/// `.git` above the directory, `HEAD` for the branch, and whether `.git` is a file (a linked worktree).
///
/// Threading: `read(directory:)` runs off the main actor and returns a `Sendable` value.
struct GitContext: Hashable, Sendable {
    enum Workspace: Hashable, Sendable {
        /// The repository's main checkout.
        case local
        /// A linked worktree (`.git` is a file pointing into the main repository).
        case worktree
        /// Not inside a git repository.
        case plainFolder
    }

    /// Branch name, or a short commit for a detached HEAD; nil outside a repository.
    var branch: String?
    var isDetached = false
    var workspace: Workspace

    var workspaceLabel: String {
        switch workspace {
        case .local: "Local checkout"
        case .worktree: "Worktree"
        case .plainFolder: "Not a git repository"
        }
    }

    @concurrent
    static func read(directory: String) async -> GitContext { readSync(directory: directory) }

    static func readSync(directory: String) -> GitContext {
        let manager = FileManager.default
        var url = URL(filePath: directory, directoryHint: .isDirectory).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = url.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return head(in: dotGit, workspace: .local) }
                // A worktree: ".git" holds "gitdir: <path>".
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:")
                else { return GitContext(branch: nil, workspace: .worktree) }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = path.hasPrefix("/") ? URL(filePath: path) : url.appending(path: path)
                return head(in: gitDir, workspace: .worktree)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return GitContext(branch: nil, workspace: .plainFolder)
    }

    private static func head(in gitDir: URL, workspace: Workspace) -> GitContext {
        guard let text = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else {
            return GitContext(branch: nil, workspace: workspace)
        }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return GitContext(branch: branch, workspace: workspace)
        }
        return GitContext(branch: String(head.prefix(8)), isDetached: true, workspace: workspace)
    }
}
