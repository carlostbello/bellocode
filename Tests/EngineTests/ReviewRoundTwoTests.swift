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
