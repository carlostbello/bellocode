import Foundation
import Testing

@testable import Engine

/// Regression tests for docs/reviews/M2-M4-review.md (round two): M1 and M2.
@Suite struct RevertAtomicityTests {
    /// M1: an edit saved after the preflight check but before the replacement must win; the revert fails untouched.
    @Test func concurrentEditBetweenPreflightAndReplaceIsNotOverwritten() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "one\n", "g.txt": "two\n"])
        defer { repo.remove() }
        let root = repo.path
        let copy = WorkingCopy(root: root, beforeReplace: { path in
            guard path == "f.txt" else { return }
            try? "one\nuser edit\n".write(toFile: root + "/f.txt", atomically: false, encoding: .utf8)
        })
        let plans = [copy.planRestore(path: "f.txt", to: Data("reverted\n".utf8))]
        #expect(throws: WorkingCopyError.changedOnDisk("f.txt")) { try copy.apply(plans) }
        #expect(try repo.read("f.txt") == "one\nuser edit\n")
    }

    /// M1: an atomic save (rename over the path) between preflight and replacement is also detected.
    @Test func concurrentAtomicSaveIsDetected() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "one\n"])
        defer { repo.remove() }
        let root = repo.path
        let copy = WorkingCopy(root: root, beforeReplace: { _ in
            try? "saved by editor\n".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        })
        let plan = copy.planRestore(path: "f.txt", to: Data("reverted\n".utf8))
        #expect(throws: WorkingCopyError.changedOnDisk("f.txt")) { try copy.apply([plan]) }
        #expect(try repo.read("f.txt") == "saved by editor\n")
    }

    /// M1: a file created between preflight and a revert that would create it is left alone.
    @Test func concurrentCreateIsNotOverwritten() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "one\n"])
        defer { repo.remove() }
        let root = repo.path
        let copy = WorkingCopy(root: root, beforeReplace: { _ in
            try? "new by user\n".write(toFile: root + "/new.txt", atomically: false, encoding: .utf8)
        })
        let plan = copy.planRestore(path: "new.txt", to: Data("restored\n".utf8))
        #expect(throws: WorkingCopyError.changedOnDisk("new.txt")) { try copy.apply([plan]) }
        #expect(try repo.read("new.txt") == "new by user\n")
    }

    /// M1: a file edited between preflight and a revert that deletes it is kept.
    @Test func concurrentEditBeforeDeleteKeepsTheFile() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "one\n"])
        defer { repo.remove() }
        let root = repo.path
        let copy = WorkingCopy(root: root, beforeReplace: { _ in
            try? "edited\n".write(toFile: root + "/f.txt", atomically: false, encoding: .utf8)
        })
        let plan = copy.planRestore(path: "f.txt", to: nil)
        #expect(throws: WorkingCopyError.changedOnDisk("f.txt")) { try copy.apply([plan]) }
        #expect(try repo.read("f.txt") == "edited\n")
    }

    /// M1: when the second file changed, the first is rolled back, and a rollback never overwrites an edit made to
    /// the first file after it was written.
    @Test func rollbackIsConflictAware() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "a0\n", "b.txt": "b0\n"])
        defer { repo.remove() }
        let root = repo.path
        // Plain rollback: b changes before its replacement; a is restored to a0.
        let simple = WorkingCopy(root: root, beforeReplace: { path in
            if path == "b.txt" { try? "b-user\n".write(toFile: root + "/b.txt", atomically: false, encoding: .utf8) }
        })
        let plans = [simple.planRestore(path: "a.txt", to: Data("a1\n".utf8)), simple.planRestore(path: "b.txt", to: Data("b1\n".utf8))]
        #expect(throws: WorkingCopyError.changedOnDisk("b.txt")) { try simple.apply(plans) }
        #expect(try repo.read("a.txt") == "a0\n")
        #expect(try repo.read("b.txt") == "b-user\n")

        // Conflicting rollback: a is edited after we wrote it, then b fails; a keeps the user's edit.
        try repo.write("b.txt", "b0\n")
        let racing = WorkingCopy(root: root, beforeReplace: { path in
            if path == "b.txt" {
                try? "a-user\n".write(toFile: root + "/a.txt", atomically: false, encoding: .utf8)
                try? "b-user\n".write(toFile: root + "/b.txt", atomically: false, encoding: .utf8)
            }
        })
        let plans2 = [racing.planRestore(path: "a.txt", to: Data("a1\n".utf8)), racing.planRestore(path: "b.txt", to: Data("b1\n".utf8))]
        #expect(throws: WorkingCopyError.self) { try racing.apply(plans2) }
        #expect(try repo.read("a.txt") == "a-user\n")
        #expect(try repo.read("b.txt") == "b-user\n")
    }

    /// M1: Undo restores exact bytes and permissions, or refuses when the file changed since the revert.
    @Test func undoRestoresExactBytesOrRefuses() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "one\n"])
        defer { repo.remove() }
        let original = Data([0x6F, 0x6E, 0x65, 0x0D, 0x0A, 0xFF, 0x00])
        try original.write(to: repo.root.appending(path: "f.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path + "/f.txt")
        let copy = WorkingCopy(root: repo.path)
        let written = try copy.apply([copy.planRestore(path: "f.txt", to: Data("x\n".utf8))])
        let perms = try FileManager.default.attributesOfItem(atPath: repo.path + "/f.txt")[.posixPermissions] as? Int
        #expect(perms == 0o755)
        try copy.undo(written)
        #expect(try Data(contentsOf: repo.root.appending(path: "f.txt")) == original)

        let again = try copy.apply([copy.planRestore(path: "f.txt", to: Data("x\n".utf8))])
        try repo.write("f.txt", "user\n")
        #expect(throws: WorkingCopyError.changedOnDisk("f.txt")) { try copy.undo(again) }
        #expect(try repo.read("f.txt") == "user\n")
    }
}

extension WorktreeService {
    /// A service whose removed worktree files go to a holding folder next to the test repository, never the real Trash.
    static func holding(in repo: TempRepo) -> WorktreeService {
        let held = repo.base.appending(path: "held", directoryHint: .isDirectory)
        return WorktreeService(runner: repo.runner) { url in
            try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
            let destination = held.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }
}

@Suite(.timeLimit(.minutes(3))) struct WorktreeRemovalSafetyTests {
    /// M2: a worktree whose only own files are ignored (.env, build/) is not "clean": removal asks first, then keeps
    /// the files recoverable, and Undo brings them back byte for byte.
    @Test func ignoredFilesAreReportedHeldAndRestored() async throws {
        let repo = try await TempRepo.make(files: ["README.md": "hello\n", ".gitignore": ".env\nbuild/\n"])
        defer { repo.remove() }
        let service = WorktreeService.holding(in: repo)
        let created = try await service.create(
            WorktreeCreation(projectDirectory: repo.path, branch: "wt", base: "main", parentDirectory: repo.base.appending(path: "wt").path, copyOnWrite: false))
        let secret = Data("API_KEY=local\n".utf8)
        try secret.write(to: URL(filePath: created.directory + "/.env"))
        try FileManager.default.createDirectory(atPath: created.directory + "/build/cache", withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(filePath: created.directory + "/build/cache/db.sqlite"))
        #expect(try await GitRepository(directory: created.directory, runner: repo.runner).status().files.isEmpty, "git status alone calls it clean")

        let contents = try await service.contents(of: created.directory)
        #expect(contents.uncommitted == 0 && contents.ignored == 2)
        #expect(Set(contents.examples) == [".env", "build/"])
        await #expect(throws: WorktreeError.filesAtRisk(contents)) {
            try await service.remove(directory: created.directory, projectDirectory: repo.path, deleteBranch: false, force: false)
        }
        #expect(FileManager.default.contents(atPath: created.directory + "/.env") == secret, "refusal touches nothing")

        let removed = try await service.remove(directory: created.directory, projectDirectory: repo.path, deleteBranch: false, force: true)
        #expect(!FileManager.default.fileExists(atPath: created.directory))
        let held = try #require(removed.heldContents)
        #expect(FileManager.default.contents(atPath: held + "/.env") == secret, "held, not deleted")
        #expect(try await repo.repository.worktrees().count == 1)

        try await service.restore(removed)
        #expect(FileManager.default.contents(atPath: created.directory + "/.env") == secret)
        #expect(FileManager.default.contents(atPath: created.directory + "/build/cache/db.sqlite") == Data([1, 2, 3]))
        #expect(FileManager.default.contents(atPath: created.directory + "/README.md") == Data("hello\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: held), "the holding folder is consumed")
        #expect(try await GitRepository(directory: created.directory, runner: repo.runner).status().branch == "wt")
    }

    /// M2: uncommitted edits and untracked files also come back exactly; a clean worktree holds nothing.
    @Test func uncommittedFilesRoundTripAndCleanRemovalHoldsNothing() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "a\n"])
        defer { repo.remove() }
        let service = WorktreeService.holding(in: repo)
        let parent = repo.base.appending(path: "wt").path
        let dirty = try await service.create(WorktreeCreation(projectDirectory: repo.path, branch: "dirty", base: "main", parentDirectory: parent, copyOnWrite: false))
        try "edited\n".write(toFile: dirty.directory + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dirty.directory + "/new.txt", atomically: true, encoding: .utf8)
        let removed = try await service.remove(directory: dirty.directory, projectDirectory: repo.path, deleteBranch: true, force: true)
        try await service.restore(removed)
        #expect(try String(contentsOfFile: dirty.directory + "/a.txt", encoding: .utf8) == "edited\n")
        #expect(try String(contentsOfFile: dirty.directory + "/new.txt", encoding: .utf8) == "new\n")

        let clean = try await service.create(WorktreeCreation(projectDirectory: repo.path, branch: "clean", base: "main", parentDirectory: parent, copyOnWrite: false))
        let cleanRemoval = try await service.remove(directory: clean.directory, projectDirectory: repo.path, deleteBranch: false, force: false)
        #expect(cleanRemoval.heldContents == nil)
    }

    /// M2: when the held files were deleted (Trash emptied), Undo restores the checkout and says what is missing.
    @Test func restoreReportsMissingHeldFiles() async throws {
        let repo = try await TempRepo.make(files: ["README.md": "x\n", ".gitignore": ".env\n"])
        defer { repo.remove() }
        let service = WorktreeService.holding(in: repo)
        let created = try await service.create(
            WorktreeCreation(projectDirectory: repo.path, branch: "gone", base: "main", parentDirectory: repo.base.appending(path: "wt").path, copyOnWrite: false))
        try "k\n".write(toFile: created.directory + "/.env", atomically: true, encoding: .utf8)
        let removed = try await service.remove(directory: created.directory, projectDirectory: repo.path, deleteBranch: false, force: true)
        let held = try #require(removed.heldContents)
        try FileManager.default.removeItem(atPath: held)
        await #expect(throws: WorktreeError.heldContentsMissing(held)) { try await service.restore(removed) }
        #expect(FileManager.default.fileExists(atPath: created.directory + "/README.md"))
    }
}
