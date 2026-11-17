import DiffKit
import Engine
import Foundation

/// Sample diffs for snapshots and benchmarks (realistic code, several hunks, an addition, a deletion, a binary).
enum Samples {
    static let loginOld = """
        import Foundation
        import Security

        /// Signs a user in with a password.
        struct LoginService {
            let store: CredentialStore
            let clock: Clock

            /// Returns true when the user may sign in.
            func login(user: String, password: String) -> Bool {
                guard !user.isEmpty else { return false }
                let stored = store.password(for: user)
                return stored == password
            }

            func logout(user: String) {
                store.clear(user)
            }

            // MARK: - Throttling

            private var attempts: [String: Int] = [:]

            mutating func recordFailure(for user: String) {
                attempts[user, default: 0] += 1
            }

            func isLocked(_ user: String) -> Bool {
                (attempts[user] ?? 0) > 5
            }

            func describe() -> String {
                "LoginService(store: \\(store))"
            }
        }

        """

    static let loginNew = """
        import Foundation
        import Security
        import CryptoKit

        /// Signs a user in with a password, with throttling after repeated failures.
        struct LoginService {
            let store: CredentialStore
            let clock: any Clock<Duration>

            /// Returns true when the user may sign in.
            func login(user: String, password: String) async throws -> Bool {
                guard !user.isEmpty, !isLocked(user) else { return false }
                let stored = try await store.passwordHash(for: user)
                return stored == SHA256.hash(data: Data(password.utf8)).description
            }

            func logout(user: String) {
                store.clear(user)
            }

            // MARK: - Throttling

            private var attempts: [String: Int] = [:]

            mutating func recordFailure(for user: String) {
                attempts[user, default: 0] += 1
            }

            func isLocked(_ user: String) -> Bool {
                (attempts[user] ?? 0) >= maximumAttempts
            }

            /* Five failures lock the account until
               an administrator resets it. */
            let maximumAttempts = 5

            func describe() -> String {
                "LoginService(store: \\(store))"
            }
        }

        """

    static let configOld = """
        export const config = {
          retries: 3,
          timeoutMs: 5000,
          endpoint: "https://api.example.com/v1",
          verbose: false,
        };

        export function withRetries<T>(task: () => Promise<T>): Promise<T> {
          return task().catch(() => task());
        }

        """

    static let configNew = """
        export const config = {
          retries: 5,
          timeoutMs: 10_000,
          endpoint: "https://api.example.com/v2",
          verbose: false,
        };

        export async function withRetries<T>(task: () => Promise<T>, attempts = config.retries): Promise<T> {
          for (let attempt = 1; ; attempt++) {
            try {
              return await task();
            } catch (error) {
              if (attempt >= attempts) throw error;
            }
          }
        }

        """

    static var files: [DiffFile] {
        let login = DiffFile.compute(path: "Sources/Auth/LoginService.swift", old: loginOld, new: loginNew)
        let config = DiffFile.compute(path: "web/src/config.ts", old: configOld, new: configNew)
        let readme = DiffFile.compute(path: "docs/LOGIN.md", old: nil, new: "# Login\n\nPasswords are hashed with SHA-256 before comparison.\nFive failures lock the account.\n")
        let removed = DiffFile.compute(path: "Sources/Auth/LegacyLogin.swift", old: "// Deprecated.\nstruct LegacyLogin {}\n", new: nil)
        let icon = DiffFile.from(PatchFile(oldPath: "Assets/icon.png", newPath: "Assets/icon.png", isBinary: true))
        return [login, config, readme, removed, icon]
    }

    /// A file with `changed` changed lines among `total` (every other line edited, plus long lines).
    static func large(total: Int, changed: Int) -> DiffFile {
        var old: [String] = []
        var new: [String] = []
        let stride = max(1, total / max(1, changed))
        for index in 0..<total {
            let line = index % 97 == 0
                ? "    let longLine\(index) = \"" + String(repeating: "abcdefghij", count: 30) + "\""
                : "    let value\(index) = compute(\(index), scale: \(index % 13)) // note \(index % 7)"
            old.append(line)
            new.append(index % stride == 0 ? line.replacingOccurrences(of: "compute(", with: "computeFast(") : line)
        }
        return DiffFile.compute(path: "Sources/Generated/Large\(total).swift", old: old.joined(separator: "\n") + "\n", new: new.joined(separator: "\n") + "\n")
    }

    /// A 100,000-line added file (every line changed; plain mode).
    static func hugeFile(lines: Int) -> DiffFile {
        let text = (0..<lines).map { "line \($0): " + String(repeating: "x", count: $0 % 80) }.joined(separator: "\n") + "\n"
        return DiffFile.compute(path: "data/huge.txt", old: nil, new: text)
    }
}
