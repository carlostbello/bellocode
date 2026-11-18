import BelloCore
import Foundation

/// Prompts for text the session's model proposes through opencode's `session.generate` (transient: nothing is added
/// to the thread's history), and the checks applied to what comes back. Repository content is quoted as untrusted data.
/// T3 Code: "Repository conventions" (recent subjects) for commit messages; generated worktree branch names.
public enum GitTextGeneration {
    // MARK: Commit messages

    public static func commitPrompt(stat: String, patch: String, recentSubjects: [String]) -> String {
        let subjects = recentSubjects.prefix(12).map { "- " + String($0.prefix(120)) }.joined(separator: "\n")
        return """
            Write a git commit message for the changes below. Follow the style of the repository's recent commit subjects. \
            Reply with the message only: a subject line of at most 72 characters in the imperative mood, then optionally a \
            blank line and a short body wrapped at 72 characters. No code fences, no quotes, no preamble.

            Recent subjects:
            \(subjects.isEmpty ? "(none)" : subjects)

            \(UntrustedText.block("diff summary", UntrustedText.sanitise(stat, limit: 4_000)))

            \(UntrustedText.block("diff excerpt", UntrustedText.sanitise(patch, limit: 12_000)))
            """
    }

    /// The model's reply as a commit message, or nil when unusable (empty, or a refusal-like reply).
    public static func commitMessage(from reply: String) -> String? {
        var lines = cleaned(reply).components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard var subject = lines.first?.trimmingCharacters(in: .whitespaces), !subject.isEmpty else { return nil }
        for prefix in ["Commit message:", "Subject:", "commit message:"] where subject.hasPrefix(prefix) {
            subject = subject.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        if subject.count > 72 { subject = String(subject.prefix(71)) + "…" }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = body.isEmpty ? subject : subject + "\n\n" + String(body.prefix(2_000))
        return message.isEmpty ? nil : message
    }

    // MARK: Branch names

    public static func branchPrompt(firstPrompt: String, prefix: String) -> String {
        """
        Propose a short git branch name for the task below. Reply with the name only: lowercase words joined by hyphens, \
        at most 5 words, no prefix, no quotes, no explanation.

        \(UntrustedText.block("task", UntrustedText.sanitise(firstPrompt, limit: 2_000)))
        """
    }

    /// `prefix` + a valid slug from the reply, or nil when the reply has no usable words.
    public static func branchName(from reply: String, prefix: String) -> String? {
        let line = cleaned(reply).split(separator: "\n").first.map(String.init) ?? ""
        let words = line.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "/" && $0 != " " }.joined(separator: " ")
        let name = WorktreeService.slug(words.replacingOccurrences(of: "/", with: " "), prefix: "")
        guard name != "work", !name.isEmpty else { return nil }
        let full = prefix + name
        return isValidBranchName(full) ? full : nil
    }

    /// git's ref-format rules for a branch, conservatively.
    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 120, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"), !name.contains("@{"), name != "@"
        else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\\u{7f}").union(.controlCharacters)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// Strips code fences, surrounding quotes and backticks.
    static func cleaned(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n")
        }
        for quote in ["\"", "'", "`"] where text.hasPrefix(quote) && text.hasSuffix(quote) && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
